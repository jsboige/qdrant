# Script de vérification post-correction
# Date: 2025-10-13
# Tâche 5: Vérifier le résultat de la correction

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VERIFICATION POST-CORRECTION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Récupérer l'API key
$apiKeyLine = Get-Content .env.production | Select-String 'QDRANT_SERVICE_API_KEY=(.+)'
if ($apiKeyLine) {
    $apiKey = $apiKeyLine.Matches.Groups[1].Value
    Write-Host "API Key récupérée: $($apiKey.Substring(0,8))..." -ForegroundColor Green
} else {
    Write-Host "ERREUR: Impossible de récupérer l'API key" -ForegroundColor Red
    exit 1
}
Write-Host ""

$headers = @{
    'api-key' = $apiKey
    'Content-Type' = 'application/json'
}

# 1. Vérifier l'état de la collection
Write-Host "=== 1. ETAT DE LA COLLECTION ===" -ForegroundColor Yellow
try {
    $collection = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers $headers -Method Get
    
    Write-Host "Status: $($collection.result.status)" -ForegroundColor $(if ($collection.result.status -eq "green") { "Green" } else { "Yellow" })
    Write-Host "Points: $($collection.result.points_count)" -ForegroundColor Cyan
    Write-Host "Vecteurs indexés: $($collection.result.indexed_vectors_count)" -ForegroundColor $(if ($collection.result.indexed_vectors_count -gt 0) { "Green" } else { "Yellow" })
    Write-Host "Points indexés: $($collection.result.indexed_vectors_count)/$($collection.result.points_count)" -ForegroundColor $(if ($collection.result.indexed_vectors_count -eq $collection.result.points_count) { "Green" } else { "Yellow" })
    
    Write-Host ""
    Write-Host "=== CONFIGURATION HNSW ===" -ForegroundColor Yellow
    Write-Host "max_indexing_threads: $($collection.result.config.hnsw_config.max_indexing_threads)" -ForegroundColor $(if ($collection.result.config.hnsw_config.max_indexing_threads -gt 0) { "Green" } else { "Red" })
    Write-Host "m: $($collection.result.config.hnsw_config.m)"
    Write-Host "ef_construct: $($collection.result.config.hnsw_config.ef_construct)"
    Write-Host "on_disk: $($collection.result.config.hnsw_config.on_disk)"
    
    Write-Host ""
    Write-Host "=== CONFIGURATION OPTIMIZER ===" -ForegroundColor Yellow
    Write-Host "indexing_threshold: $($collection.result.config.optimizer_config.indexing_threshold)"
    Write-Host "memmap_threshold: $($collection.result.config.optimizer_config.memmap_threshold)"
    Write-Host "flush_interval_sec: $($collection.result.config.optimizer_config.flush_interval_sec)"
    
    # Sauvegarder la sortie complète
    $outputPath = "diagnostics/20251013_collection_state_verified.json"
    $collection.result | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding utf8
    Write-Host ""
    Write-Host "État complet sauvegardé dans: $outputPath" -ForegroundColor Green
    
} catch {
    Write-Host "ERREUR lors de la vérification: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# 2. Tester une requête simple
Write-Host "=== 2. TEST DE REPONSE ===" -ForegroundColor Yellow
try {
    $time = Measure-Command {
        $points = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index/points?limit=5' -Headers $headers -Method Get
    }
    Write-Host "Temps de réponse: $($time.TotalMilliseconds)ms" -ForegroundColor $(if ($time.TotalMilliseconds -lt 100) { "Green" } else { "Yellow" })
    Write-Host "Points récupérés: $($points.result.points.Count)" -ForegroundColor Cyan
} catch {
    Write-Host "ERREUR lors du test: $_" -ForegroundColor Red
}

Write-Host ""

# 3. Résumé de la vérification
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "RESUME DE LA VERIFICATION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$success = $true
$issues = @()

if ($collection.result.config.hnsw_config.max_indexing_threads -eq 0) {
    $success = $false
    $issues += "❌ max_indexing_threads encore à 0"
} else {
    Write-Host "✅ max_indexing_threads corrigé: $($collection.result.config.hnsw_config.max_indexing_threads)" -ForegroundColor Green
}

if ($collection.result.status -ne "green") {
    $success = $false
    $issues += "❌ Status collection: $($collection.result.status)"
} else {
    Write-Host "✅ Status collection: green" -ForegroundColor Green
}

if ($collection.result.points_count -eq 0) {
    $issues += "⚠️ Aucun point dans la collection"
} else {
    Write-Host "✅ Points restaurés: $($collection.result.points_count)" -ForegroundColor Green
}

if ($collection.result.indexed_vectors_count -lt $collection.result.points_count) {
    Write-Host "⚠️ Indexation en cours: $($collection.result.indexed_vectors_count)/$($collection.result.points_count)" -ForegroundColor Yellow
    Write-Host "   (Normal juste après la correction, vérifier dans quelques minutes)" -ForegroundColor Cyan
} else {
    Write-Host "✅ Tous les vecteurs indexés" -ForegroundColor Green
}

if ($time.TotalMilliseconds -lt 100) {
    Write-Host "✅ Temps de réponse excellent: $($time.TotalMilliseconds)ms" -ForegroundColor Green
} else {
    Write-Host "⚠️ Temps de réponse: $($time.TotalMilliseconds)ms" -ForegroundColor Yellow
}

Write-Host ""

if ($issues.Count -gt 0) {
    Write-Host "PROBLEMES DETECTES:" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "  $issue" -ForegroundColor Red
    }
} else {
    Write-Host "✅ CORRECTION VALIDEE AVEC SUCCES !" -ForegroundColor Green
    Write-Host "Tous les paramètres sont corrects" -ForegroundColor Green
}

Write-Host ""
Write-Host "VERIFICATION TERMINEE" -ForegroundColor Green