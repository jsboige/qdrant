# Script de diagnostic du freeze post-correction
# Date: 2025-10-13
# Contexte: Freeze 2h après correction de max_indexing_threads

Write-Host "=== DIAGNOSTIC FREEZE POST-CORRECTION ===" -ForegroundColor Cyan
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# Récupérer l'API key proprement ligne par ligne
$apiKeyLine = Get-Content .env.production | Where-Object { $_ -match '^QDRANT_API_KEY=' }
$apiKey = ($apiKeyLine -split '=',2)[1].Trim()
$headers = @{ "api-key" = $apiKey }
Write-Host "DEBUG: API Key length = $($apiKey.Length)" -ForegroundColor DarkGray

Write-Host "`n1. ÉTAT DE LA COLLECTION roo_tasks_semantic_index" -ForegroundColor Yellow
$collection = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers
Write-Host "   Status: $($collection.result.status)" -ForegroundColor $(if($collection.result.status -eq 'green'){'Green'}else{'Red'})
Write-Host "   Points: $($collection.result.points_count)" -ForegroundColor White
Write-Host "   Indexed vectors: $($collection.result.indexed_vectors_count)" -ForegroundColor $(if($collection.result.indexed_vectors_count -eq 0){'Red'}else{'Green'})
Write-Host "   max_indexing_threads: $($collection.result.config.hnsw_config.max_indexing_threads)" -ForegroundColor White

Write-Host "`n2. POINTS DANS LA COLLECTION" -ForegroundColor Yellow
$points = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/points/scroll?limit=10" -Headers $headers
Write-Host "   Nombre de points récupérés: $($points.result.points.Count)" -ForegroundColor White
if ($points.result.points.Count -gt 0) {
    Write-Host "   Premier point ID: $($points.result.points[0].id)" -ForegroundColor Gray
    Write-Host "   Dimension vecteur: $($points.result.points[0].vector.Length)" -ForegroundColor Gray
} else {
    Write-Host "   AUCUN POINT TROUVÉ!" -ForegroundColor Red
}

Write-Host "`n3. TEST D'INSERTION (SIMULATION)" -ForegroundColor Yellow
Write-Host "   Tentative d'insertion d'un point test..." -ForegroundColor Gray
$testPoint = @{
    points = @(
        @{
            id = "test-$(Get-Date -Format 'yyyyMMddHHmmss')"
            vector = @(1..1536 | ForEach-Object { Get-Random -Minimum -1.0 -Maximum 1.0 })
            payload = @{
                test = $true
                timestamp = (Get-Date -Format 'o')
            }
        }
    )
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Method Put `
        -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/points?wait=true" `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $testPoint `
        -ErrorAction Stop
    Write-Host "   ✓ Insertion réussie!" -ForegroundColor Green
    Write-Host "   Status: $($response.status)" -ForegroundColor White
} catch {
    Write-Host "   ✗ ERREUR lors de l'insertion:" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) {
        Write-Host "   Détails: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
    }
}

Write-Host "`n4. ANALYSE DES LOGS" -ForegroundColor Yellow
$logs = Get-Content diagnostics/20251013_freeze_post_correction.log | Select-String "400" | Select-Object -Last 10
Write-Host "   Dernières erreurs 400:" -ForegroundColor White
$logs | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }

Write-Host "`n5. STATISTIQUES DES ERREURS" -ForegroundColor Yellow
$errors400 = Get-Content diagnostics/20251013_freeze_post_correction.log | Select-String "400"
$errorsByTime = $errors400 | Group-Object { $_.Line.Substring(0, 19) }
Write-Host "   Total erreurs 400: $($errors400.Count)" -ForegroundColor White
Write-Host "   Plage temporelle:" -ForegroundColor White
if ($errorsByTime.Count -gt 0) {
    Write-Host "   Première: $($errorsByTime[0].Name)" -ForegroundColor Gray
    Write-Host "   Dernière: $($errorsByTime[-1].Name)" -ForegroundColor Gray
    $gap = [datetime]::Parse($errorsByTime[-1].Name) - [datetime]::Parse($errorsByTime[0].Name)
    Write-Host "   Durée: $($gap.TotalMinutes.ToString('F1')) minutes" -ForegroundColor White
}

Write-Host "`n6. ÉTAT DES RESSOURCES" -ForegroundColor Yellow
$stats = docker stats qdrant_production --no-stream --format "{{.MemUsage}}"
Write-Host "   Mémoire: $stats" -ForegroundColor White

Write-Host "`n7. RECOMMANDATIONS" -ForegroundColor Yellow
if ($collection.result.indexed_vectors_count -eq 0 -and $collection.result.points_count -gt 0) {
    Write-Host "   ⚠ PROBLÈME CRITIQUE: Indexation bloquée!" -ForegroundColor Red
    Write-Host "   → $($collection.result.points_count) points présents mais 0 indexés" -ForegroundColor Red
    Write-Host "   → La collection est inutilisable pour les recherches vectorielles" -ForegroundColor Red
    Write-Host "`n   SOLUTIONS POSSIBLES:" -ForegroundColor Yellow
    Write-Host "   1. Supprimer et recréer la collection" -ForegroundColor White
    Write-Host "   2. Forcer la réindexation (si possible)" -ForegroundColor White
    Write-Host "   3. Redémarrer le service (peut débloquer)" -ForegroundColor White
}

Write-Host "`n=== FIN DU DIAGNOSTIC ===" -ForegroundColor Cyan