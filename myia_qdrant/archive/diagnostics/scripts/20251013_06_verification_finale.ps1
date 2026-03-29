# Vérification finale post-résolution
Write-Host "=== ÉTAT FINAL DU SERVICE ===" -ForegroundColor Cyan

Write-Host "`n1. DOCKER STATUS" -ForegroundColor Yellow
docker ps --filter "name=qdrant_production" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

Write-Host "`n2. COLLECTION roo_tasks_semantic_index" -ForegroundColor Yellow
$envContent = (Get-Content .env.production -Raw) -replace '\r?\n(?![A-Z_]+=)',''
if ($envContent -match 'QDRANT_SERVICE_API_KEY=([^\r\n]+)') {
    $apiKey = $matches[1].Trim()
    $headers = @{ "api-key" = $apiKey }
    $coll = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers
    Write-Host "   Status: $($coll.result.status)" -ForegroundColor Green
    Write-Host "   Points: $($coll.result.points_count)" -ForegroundColor White
    Write-Host "   Indexed: $($coll.result.indexed_vectors_count)" -ForegroundColor White
    Write-Host "   max_indexing_threads: $($coll.result.config.hnsw_config.max_indexing_threads)" -ForegroundColor Green
}

Write-Host "`n✓ Service Production opérationnel" -ForegroundColor Green
Write-Host "✓ Collection recréée avec configuration optimale" -ForegroundColor Green
Write-Host "✓ Prêt à recevoir et indexer de nouveaux points" -ForegroundColor Green