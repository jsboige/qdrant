# Trigger optimizer to reclaim disk after Phase A dedup
# Strategy: PATCH default_segment_number to force segment merging.
# Per CLAUDE.md feedback_qdrant_ops: this is the lever to force quant rebuild & disk reclaim.
$ErrorActionPreference = "Stop"
$apiKey = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "QDRANT__SERVICE__API_KEY=").Line -replace "QDRANT__SERVICE__API_KEY=","").Trim()
$baseUrl = "http://localhost:6333"
$collection = "roo_tasks_semantic_index"
$headers = @{"api-key" = $apiKey; "Content-Type" = "application/json"}

# Get current optimizer config
$col = Invoke-RestMethod -Uri "$baseUrl/collections/$collection" -Headers $headers
$cur = $col.result.config.optimizer_config
Write-Output "CURRENT_OPTIMIZER:"
$cur | ConvertTo-Json | Write-Output
Write-Output "CURRENT segments=$($col.result.segments_count) points=$($col.result.points_count)"

# Patch: set default_segment_number to force consolidation
# Lower = more consolidation pressure. Use 8 (per CLAUDE.md MEMORY note)
$patch = @{
    optimizers_config = @{
        default_segment_number = 8
    }
} | ConvertTo-Json -Depth 4 -Compress
Write-Output "PATCHING with: $patch"
$resp = Invoke-RestMethod -Uri "$baseUrl/collections/$collection" -Method Patch -Headers $headers -Body $patch -TimeoutSec 60
Write-Output "PATCH_RESULT: $($resp.result) (status=$($resp.status))"

Write-Output ""
Write-Output "Optimizer will now consolidate segments in background."
Write-Output "Monitor with: curl /collections/$collection (check segments_count and optimizer_status)"
