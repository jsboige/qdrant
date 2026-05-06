# Phase A intra-task CC dedup
# Per-task: scroll all points, group by (sequence_order, chunk_index, total_chunks), keep one per group, delete the rest.

param(
    [int]$MaxTasks = 30,
    [int]$MinSize = 1000,
    [int]$MaxSize = 100000,
    [int]$MaxTotalDeletions = 28000000,
    [int]$DeleteBatchSize = 200,
    [int]$ScrollBatch = 5000,
    [int]$MaxMinutes = 25,
    [string]$ReportPath = "D:\qdrant\myia_qdrant\reports\dedup_progress.jsonl",
    [string]$FacetsPath = "D:\qdrant\myia_qdrant\reports\cc_task_facets.json"
)

$ErrorActionPreference = "Continue"
$apiKey = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "QDRANT__SERVICE__API_KEY=").Line -replace "QDRANT__SERVICE__API_KEY=","").Trim()
$baseUrl = "http://localhost:6333"
$collection = "roo_tasks_semantic_index"
$headers = @{"api-key" = $apiKey; "Content-Type" = "application/json"}

$facets = Get-Content $FacetsPath -Raw | ConvertFrom-Json
$tasks = $facets | Sort-Object count -Descending | Where-Object { $_.count -ge $MinSize -and $_.count -le $MaxSize } | Select-Object -First $MaxTasks
$totalExpected = ($tasks | Measure-Object count -Sum).Sum
Write-Host "TASKS=$($tasks.Count) TOTAL_EXPECTED=$totalExpected MIN=$MinSize MAX=$MaxSize TIME=${MaxMinutes}min"

$totalDeleted = 0
$totalKept = 0
$tasksProcessed = 0
$startTime = Get-Date
if (Test-Path $ReportPath) { Remove-Item $ReportPath }

foreach ($t in $tasks) {
    $elapsed = ((Get-Date) - $startTime).TotalMinutes
    if ($elapsed -gt $MaxMinutes) { Write-Host "TIME_STOP elapsed=$([math]::Round($elapsed,1))min"; break }
    if ($totalDeleted -ge $MaxTotalDeletions) { Write-Host "SANITY_STOP total=$totalDeleted"; break }

    $taskId = $t.value
    $expectedCount = $t.count
    $tShort = if ($taskId.Length -gt 50) { $taskId.Substring(0, 50) + "..." } else { $taskId }
    $taskStart = Get-Date
    Write-Host "[$($tasksProcessed+1)/$($tasks.Count)] $tShort exp=$expectedCount"

    # Step 1: scroll all points
    $allPoints = New-Object System.Collections.ArrayList
    $offset = $null
    $iter = 0
    do {
        $iter++
        $body = @{
            limit = $ScrollBatch
            with_payload = @("sequence_order","chunk_index","total_chunks")
            with_vector = $false
            filter = @{ must = @(@{ key = "task_id"; match = @{ value = $taskId } }) }
        }
        if ($offset) { $body.offset = $offset }
        $bodyJson = $body | ConvertTo-Json -Depth 6 -Compress
        $scrollStart = Get-Date
        try {
            $resp = Invoke-RestMethod -Uri "$baseUrl/collections/$collection/points/scroll" -Method Post -Headers $headers -Body $bodyJson -TimeoutSec 60
        } catch {
            Write-Host "  SCROLL_FAIL iter=$iter dur=$(([math]::Round(((Get-Date)-$scrollStart).TotalSeconds,1)))s err=$($_.Exception.Message.Substring(0,[math]::Min(60,$_.Exception.Message.Length)))"
            break
        }
        $scrollDur = ((Get-Date) - $scrollStart).TotalSeconds
        foreach ($p in $resp.result.points) { [void]$allPoints.Add($p) }
        Write-Host "  scroll iter=$iter got=$($resp.result.points.Count) total=$($allPoints.Count) dur=$([math]::Round($scrollDur,1))s"
        $offset = $resp.result.next_page_offset
    } while ($offset -and $iter -lt 1500)

    if ($allPoints.Count -eq 0) { $tasksProcessed++; continue }

    # Step 2: group and pick keepers
    $groups = $allPoints | Group-Object -Property { "$($_.payload.sequence_order)|$($_.payload.chunk_index)|$($_.payload.total_chunks)" }
    $deleteIds = New-Object System.Collections.ArrayList
    $kept = 0
    foreach ($g in $groups) {
        $sorted = $g.Group | Sort-Object id
        $kept++
        for ($i = 1; $i -lt $sorted.Count; $i++) { [void]$deleteIds.Add($sorted[$i].id) }
    }

    Write-Host "  groups=$($groups.Count) kept=$kept to_del=$($deleteIds.Count)"

    if ($deleteIds.Count -eq 0) { $tasksProcessed++; continue }

    # Step 3: delete in batches
    $deleted = 0
    $failedBatches = 0
    $delStart = Get-Date
    for ($i = 0; $i -lt $deleteIds.Count; $i += $DeleteBatchSize) {
        $endIdx = [math]::Min($i + $DeleteBatchSize - 1, $deleteIds.Count - 1)
        $batch = @($deleteIds[$i..$endIdx])
        $delBody = @{ points = $batch } | ConvertTo-Json -Depth 4 -Compress
        try {
            [void](Invoke-RestMethod -Uri "$baseUrl/collections/$collection/points/delete?wait=false" -Method Post -Headers $headers -Body $delBody -TimeoutSec 30)
            $deleted += $batch.Count
        } catch {
            $failedBatches++
            if ($failedBatches -ge 3) { Write-Host "  TOO_MANY_FAILS"; break }
            Start-Sleep -Seconds 5
        }
    }
    $delDur = ((Get-Date) - $delStart).TotalSeconds

    $totalDeleted += $deleted
    $totalKept += $kept
    $tasksProcessed++
    $taskDur = ((Get-Date) - $taskStart).TotalSeconds

    $entry = @{
        task_id = $taskId
        expected = $expectedCount
        scrolled = $allPoints.Count
        groups = $groups.Count
        kept = $kept
        deleted = $deleted
        failed_batches = $failedBatches
        task_dur_s = [math]::Round($taskDur, 1)
        del_dur_s = [math]::Round($delDur, 1)
    } | ConvertTo-Json -Compress
    Add-Content -Path $ReportPath -Value $entry

    Write-Host "  DONE deleted=$deleted task_dur=$([math]::Round($taskDur,1))s total_del=$totalDeleted elapsed=$([math]::Round(((Get-Date)-$startTime).TotalMinutes,1))min"
}

$elapsed = ((Get-Date) - $startTime).TotalMinutes
Write-Host ""
Write-Host "DEDUP_COMPLETE tasks=$tasksProcessed deleted=$totalDeleted kept=$totalKept elapsed=$([math]::Round($elapsed,1))min"
