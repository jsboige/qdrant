# Qdrant cleanup pipeline — orchestrates intra-task dedup of CC tasks
# Pipeline: facets generation -> dedup -> optimizer trigger -> smoke test -> capture state
#
# Usage:
#   .\cleanup_pipeline.ps1                   # default run, top 30 tasks (1K-100K points each)
#   .\cleanup_pipeline.ps1 -DryRun           # generate facets only, no deletion
#   .\cleanup_pipeline.ps1 -MaxTasks 100     # process more tasks
#   .\cleanup_pipeline.ps1 -SkipFacets       # reuse existing cc_task_facets.json
#   .\cleanup_pipeline.ps1 -SkipOptimizer    # don't trigger optimizer (let background run)
#
# Background:
# - Built after Phase A 2026-05-06 cleanup that deleted ~2.16M points (10.3 min)
# - Pattern: same JSONL re-indexed → 15-400x intra-task multiplication on Claude Code tasks
# - Scope: only `claude-code` source tasks, point-level dedup grouped by (seq, ci, tc)
# - Sources `.jsonl` are NOT touched (sanctuary policy)
#
# Tracking: jsboige/roo-extensions#1987 (triage), #1985 (root cause / MCP fix)

param(
    [int]$MaxTasks = 30,
    [int]$MinSize = 1000,
    [int]$MaxSize = 100000,
    [int]$MaxMinutes = 25,
    [switch]$DryRun,
    [switch]$SkipFacets,
    [switch]$SkipOptimizer,
    [switch]$SkipSmoke,
    [string]$ReportsDir = "D:\qdrant\myia_qdrant\reports"
)

$ErrorActionPreference = "Stop"
$pipelineStart = Get-Date
$scriptsDir = $PSScriptRoot
$facetsFile = Join-Path $ReportsDir "cc_task_facets.json"

if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }

Write-Host "==========================================="
Write-Host " Qdrant cleanup pipeline (Phase A continuation)"
Write-Host " Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host " ReportsDir: $ReportsDir"
Write-Host " Mode: $(if ($DryRun) {'DRY RUN (facets only)'} else {'LIVE (deletions enabled)'})"
Write-Host "==========================================="

# Step 1: Pre-state capture
Write-Host ""
Write-Host "[1/5] Capturing pre-state..."
$apiKey = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "QDRANT__SERVICE__API_KEY=").Line -replace "QDRANT__SERVICE__API_KEY=","").Trim()
$headers = @{"api-key" = $apiKey; "Content-Type" = "application/json"}
$preState = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers -TimeoutSec 30
$preStatus = $preState.result
Write-Host "  pts=$($preStatus.points_count) seg=$($preStatus.segments_count) status=$($preStatus.status)"
$preState | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ReportsDir "pipeline_pre_state.json")

# Step 2: Facets generation (CC task distribution)
if ($SkipFacets -and (Test-Path $facetsFile)) {
    Write-Host ""
    Write-Host "[2/5] Reusing existing facets file: $facetsFile"
} else {
    Write-Host ""
    Write-Host "[2/5] Generating CC task facets (this can take 1-5 min)..."
    $facetBody = @{
        key = "task_id"
        limit = 5000
        filter = @{ must = @(@{ key = "source"; match = @{ value = "claude-code" } }) }
    } | ConvertTo-Json -Depth 4 -Compress
    $facets = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/facet" -Method Post -Headers $headers -Body $facetBody -TimeoutSec 300
    $facets.result.hits | ConvertTo-Json -Depth 4 | Set-Content $facetsFile
    Write-Host "  Wrote $($facets.result.hits.Count) task_ids to $facetsFile"
}

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN — exiting without deletion. Inspect $facetsFile to plan next step."
    exit 0
}

# Step 3: Dedup execution
Write-Host ""
Write-Host "[3/5] Running dedup_cc_tasks.ps1 (max $MaxTasks tasks, $MaxMinutes min budget)..."
$dedupScript = Join-Path $scriptsDir "dedup_cc_tasks.ps1"
if (-not (Test-Path $dedupScript)) {
    Write-Error "dedup_cc_tasks.ps1 not found at $dedupScript"
    exit 1
}
& $dedupScript -MaxTasks $MaxTasks -MinSize $MinSize -MaxSize $MaxSize -MaxMinutes $MaxMinutes -FacetsPath $facetsFile -ReportPath (Join-Path $ReportsDir "dedup_progress.jsonl")

# Step 4: Optimizer trigger (force physical reclaim)
if (-not $SkipOptimizer) {
    Write-Host ""
    Write-Host "[4/5] Triggering optimizer rebuild..."
    $optimizerScript = Join-Path $scriptsDir "trigger_optimizer.ps1"
    if (Test-Path $optimizerScript) {
        & $optimizerScript
    } else {
        # Inline fallback: PATCH default_segment_number to force merge
        $patchBody = @{ optimizers_config = @{ default_segment_number = 8 } } | ConvertTo-Json -Depth 4 -Compress
        $resp = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Method Patch -Headers $headers -Body $patchBody -TimeoutSec 30
        Write-Host "  PATCH optimizers_config: default_segment_number=8 (response: $($resp.status))"
        Write-Host "  Optimizer rebuild may take 30-90 min on large collections — physical disk reclaim happens during this window"
    }
}

# Step 5: Smoke test + post-state
Write-Host ""
Write-Host "[5/5] Running smoke tests + capturing post-state..."
if (-not $SkipSmoke) {
    $smokeScript = Join-Path $scriptsDir "smoke_test_search.ps1"
    if (Test-Path $smokeScript) { & $smokeScript } else { Write-Host "  smoke_test_search.ps1 not found, skipping" }
}
$postState = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers -TimeoutSec 30
$postStatus = $postState.result
$postState | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ReportsDir "pipeline_post_state.json")

# Final summary
$elapsed = ((Get-Date) - $pipelineStart).TotalMinutes
$pointsDelta = $preStatus.points_count - $postStatus.points_count

Write-Host ""
Write-Host "==========================================="
Write-Host " Pipeline complete in $([math]::Round($elapsed,1)) min"
Write-Host "  Points: $($preStatus.points_count) -> $($postStatus.points_count) (Δ=$pointsDelta)"
Write-Host "  Segments: $($preStatus.segments_count) -> $($postStatus.segments_count)"
Write-Host "  Status: $($preStatus.status) -> $($postStatus.status)"
Write-Host "  Reports: $ReportsDir"
Write-Host "==========================================="
Write-Host ""
Write-Host "NOTE: physical disk reclaim happens during optimizer rebuild (30-90 min)."
Write-Host "      Re-check disk usage with: wsl.exe -d Ubuntu --exec df -h /mnt/qdrant-e"
