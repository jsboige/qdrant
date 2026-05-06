# Smoke test post-cleanup: 3 search queries against roo_tasks_semantic_index
# Uses embedding service (qwen3-4b-awq-embedding, 2560 dims)
$ErrorActionPreference = "Continue"
$apiKey = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "QDRANT__SERVICE__API_KEY=").Line -replace "QDRANT__SERVICE__API_KEY=","").Trim()
$embApiKey = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "EMBEDDING_API_KEY=").Line -replace "EMBEDDING_API_KEY=","").Trim()
$embEndpoint = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "^EMBEDDING_API_BASE_URL=").Line -replace "EMBEDDING_API_BASE_URL=","").Trim()
$embModel = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "^EMBEDDING_MODEL=").Line -replace "EMBEDDING_MODEL=","").Trim()
if (-not $embEndpoint) { $embEndpoint = "https://embeddings.myia.io/v1" }
if (-not $embModel) { $embModel = "qwen3-4b-awq-embedding" }

$queries = @(
    "Phase A Qdrant cleanup duplicate task_ids",
    "Lean theorem proof Pareto efficiency",
    "Docker container restart healthcheck"
)

$qdrantHeaders = @{"api-key" = $apiKey; "Content-Type" = "application/json"}
$embHeaders = @{"Content-Type" = "application/json"}
if ($embApiKey) { $embHeaders["Authorization"] = "Bearer $embApiKey" }

Write-Output "EMBEDDING_ENDPOINT=$embEndpoint MODEL=$embModel"

$results = @()
foreach ($q in $queries) {
    Write-Output "QUERY: $q"
    # Get embedding
    $embBody = @{ input = $q; model = $embModel } | ConvertTo-Json -Compress
    try {
        # If endpoint already ends with /v1, just append /embeddings; otherwise add /v1/embeddings
        $embUri = if ($embEndpoint -match "/v1/?$") { "$($embEndpoint.TrimEnd('/'))/embeddings" } else { "$($embEndpoint.TrimEnd('/'))/v1/embeddings" }
        $embResp = Invoke-RestMethod -Uri $embUri -Method Post -Headers $embHeaders -Body $embBody -TimeoutSec 30
        $vec = $embResp.data[0].embedding
        Write-Output "  embed_dims=$($vec.Count)"
    } catch {
        Write-Output "  EMBED_FAIL: $_"
        $results += @{query=$q; error="embed_failed"}
        continue
    }
    # Qdrant search
    $searchBody = @{ vector = $vec; limit = 3; with_payload = @("task_id","timestamp","content_summary"); score_threshold = 0.4 } | ConvertTo-Json -Compress -Depth 4
    try {
        $start = Get-Date
        $sResp = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/points/search" -Method Post -Headers $qdrantHeaders -Body $searchBody -TimeoutSec 30
        $dur = ((Get-Date) - $start).TotalSeconds
        Write-Output "  search_dur=${dur}s hits=$($sResp.result.Count)"
        foreach ($h in $sResp.result) {
            $cs = if ($h.payload.content_summary) { $h.payload.content_summary.Substring(0, [math]::Min(80, $h.payload.content_summary.Length)) } else { "" }
            Write-Output "    score=$([math]::Round($h.score, 3)) task=$($h.payload.task_id.Substring(0, [math]::Min(40, $h.payload.task_id.Length))) | $cs"
        }
        $results += @{query=$q; hits=$sResp.result.Count; dur_s=$dur; ok=$true}
    } catch {
        Write-Output "  SEARCH_FAIL: $_"
        $results += @{query=$q; error="search_failed"}
    }
}
$json = $results | ConvertTo-Json -Depth 4 -Compress
[System.IO.File]::WriteAllText("D:\qdrant\myia_qdrant\reports\smoke_test_results.json", $json, [System.Text.UTF8Encoding]::new($false))
Write-Output "RESULTS_SAVED"
