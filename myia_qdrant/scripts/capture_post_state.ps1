$apiKey = ((Get-Content "D:\qdrant\myia_qdrant\.env.production" | Select-String "QDRANT__SERVICE__API_KEY=").Line -replace "QDRANT__SERVICE__API_KEY=","").Trim()
$headers = @{"api-key" = $apiKey}
$col = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers
$state = @{
  ts = (Get-Date).ToString("o")
  status = $col.result.status
  points_count = $col.result.points_count
  indexed_vectors_count = $col.result.indexed_vectors_count
  segments_count = $col.result.segments_count
  optimizer_status = $col.result.optimizer_status
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText("D:\qdrant\myia_qdrant\reports\state_after.json", $state, [System.Text.UTF8Encoding]::new($false))
Write-Output "AFTER_STATE: $state"
$df = wsl.exe -d Ubuntu --exec df -h /mnt/qdrant-e
[System.IO.File]::WriteAllText("D:\qdrant\myia_qdrant\reports\disk_after.txt", ($df -join "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Output "DISK_AFTER:"
$df

# Also check CC count after dedup
$ccBody = '{"exact": true, "filter": {"must": [{"key": "source", "match": {"value": "claude-code"}}]}}'
try {
  $cc = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/points/count" -Method Post -Headers @{"api-key" = $apiKey; "Content-Type" = "application/json"} -Body $ccBody -TimeoutSec 60
  Write-Output "CC_COUNT_AFTER=$($cc.result.count)"
} catch {
  Write-Output "CC_COUNT_TIMEOUT"
}
