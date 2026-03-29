#!/usr/bin/env pwsh
# Vérification finale rapide post-corrections critiques

$ErrorActionPreference = "Stop"
$QdrantUrl = "http://localhost:6333"
$CollectionName = "roo_tasks_semantic_index"

# Récupérer API Key
$ApiKey = (Get-Content ".env" | Select-String "QDRANT[_]{1,2}SERVICE[_]{1,2}API[_]{1,2}KEY=(.+)" | ForEach-Object { $_.Matches.Groups[1].Value })

$headers = @{
    "api-key" = $ApiKey
    "Content-Type" = "application/json"
}

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " VÉRIFICATION FINALE SANTÉ SYSTÈME" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# 1. API globale
Write-Host "1. API Qdrant:" -ForegroundColor Yellow
try {
    $apiInfo = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get
    Write-Host "   ✓ Version: $($apiInfo.version)" -ForegroundColor Green
} catch {
    Write-Host "   ✗ Erreur: $_" -ForegroundColor Red
}

# 2. Collection
Write-Host "`n2. Collection '$CollectionName':" -ForegroundColor Yellow
try {
    $collInfo = Invoke-RestMethod -Uri "$QdrantUrl/collections/$CollectionName" -Headers $headers -Method Get
    Write-Host "   ✓ Status: $($collInfo.result.status)" -ForegroundColor Green
    Write-Host "   ✓ Points: $($collInfo.result.points_count)" -ForegroundColor Cyan
    
    # HNSW Config
    $hnsw = $collInfo.result.config.hnsw_config
    Write-Host "`n   HNSW Configuration:" -ForegroundColor Cyan
    Write-Host "     - m: $($hnsw.m)" -ForegroundColor White
    Write-Host "     - ef_construct: $($hnsw.ef_construct)" -ForegroundColor White
    Write-Host "     - max_indexing_threads: $($hnsw.max_indexing_threads)" -ForegroundColor $(if ($hnsw.max_indexing_threads -eq 0) { "Green" } else { "Red" })
    
    # Quantization
    $quant = $collInfo.result.config.params.quantization_config
    Write-Host "`n   Quantization:" -ForegroundColor Cyan
    if ($quant) {
        Write-Host "     ✓ Active - Type: $($quant.scalar.type)" -ForegroundColor Green
        Write-Host "     - Quantile: $($quant.scalar.quantile)" -ForegroundColor White
        Write-Host "     - Always RAM: $($quant.scalar.always_ram)" -ForegroundColor White
    } else {
        Write-Host "     ⚠ Non configurée (sera active avec données)" -ForegroundColor Yellow
    }
    
} catch {
    Write-Host "   ✗ Erreur: $_" -ForegroundColor Red
}

# 3. Container
Write-Host "`n3. Container Docker:" -ForegroundColor Yellow
$containerStatus = docker ps --filter "name=qdrant_production" --format "{{.Status}}"
if ($containerStatus) {
    Write-Host "   ✓ Status: $containerStatus" -ForegroundColor Green
} else {
    Write-Host "   ✗ Container non trouvé" -ForegroundColor Red
}

# 4. Logs récents
Write-Host "`n4. Logs récents (recherche erreurs):" -ForegroundColor Yellow
$recentLogs = docker logs qdrant_production --tail 20 2>&1
$errors = $recentLogs | Select-String -Pattern "error|400" -CaseSensitive:$false
if ($errors) {
    Write-Host "   ⚠ Erreurs détectées:" -ForegroundColor Yellow
    $errors | Select-Object -First 3 | ForEach-Object {
        Write-Host "     $_" -ForegroundColor White
    }
} else {
    Write-Host "   ✓ Aucune erreur critique" -ForegroundColor Green
}

Write-Host "`n═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " VÉRIFICATION TERMINÉE" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan