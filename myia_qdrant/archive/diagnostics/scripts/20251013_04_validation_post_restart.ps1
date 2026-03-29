# Script de validation post-redémarrage
# Date: 2025-10-13
# Objectif: Vérifier que l'indexation fonctionne après redémarrage

Write-Host "=== VALIDATION POST-REDÉMARRAGE ===" -ForegroundColor Cyan
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# Récupérer l'API key
$apiKeyLine = Get-Content .env.production | Where-Object { $_ -match '^QDRANT_API_KEY=' }
if ($apiKeyLine) {
    $apiKey = ($apiKeyLine -split '=',2)[1].Trim()
    $headers = @{ "api-key" = $apiKey }
} else {
    Write-Host "✗ Impossible de trouver QDRANT_API_KEY" -ForegroundColor Red
    $headers = @{}
}

Write-Host "`n1. ÉTAT DU SERVICE" -ForegroundColor Yellow
try {
    $health = Invoke-RestMethod -Uri "http://localhost:6333/" -TimeoutSec 5
    Write-Host "   ✓ Service accessible" -ForegroundColor Green
    Write-Host "   Version: $($health.version)" -ForegroundColor White
} catch {
    Write-Host "   ✗ Service inaccessible: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "`n2. HEALTHCHECK" -ForegroundColor Yellow
try {
    $healthz = Invoke-RestMethod -Uri "http://localhost:6333/healthz" -TimeoutSec 5
    Write-Host "   ✓ Healthcheck: $healthz" -ForegroundColor Green
} catch {
    Write-Host "   ⚠ Healthcheck échoué" -ForegroundColor Yellow
}

Write-Host "`n3. DOCKER STATUS" -ForegroundColor Yellow
$status = docker ps --filter "name=qdrant_production" --format "{{.Status}}"
Write-Host "   Status: $status" -ForegroundColor $(if($status -match 'healthy'){'Green'}elseif($status -match 'unhealthy'){'Red'}else{'Yellow'})

Write-Host "`n4. COLLECTION roo_tasks_semantic_index" -ForegroundColor Yellow
try {
    $collection = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers -TimeoutSec 10
    $result = $collection.result
    
    Write-Host "   Status: $($result.status)" -ForegroundColor $(if($result.status -eq 'green'){'Green'}else{'Red'})
    Write-Host "   Points: $($result.points_count)" -ForegroundColor White
    Write-Host "   Indexed vectors: $($result.indexed_vectors_count)" -ForegroundColor $(if($result.indexed_vectors_count -gt 0){'Green'}else{'Red'})
    Write-Host "   max_indexing_threads: $($result.config.hnsw_config.max_indexing_threads)" -ForegroundColor White
    
    # Calcul du taux d'indexation
    if ($result.points_count -gt 0) {
        $indexRate = [math]::Round(($result.indexed_vectors_count / $result.points_count) * 100, 1)
        Write-Host "   Taux d'indexation: $indexRate%" -ForegroundColor $(if($indexRate -gt 80){'Green'}elseif($indexRate -gt 0){'Yellow'}else{'Red'})
    }
    
    # VALIDATION CRITIQUE
    if ($result.indexed_vectors_count -eq 0 -and $result.points_count -gt 0) {
        Write-Host "`n   ⚠ PROBLÈME: Indexation toujours bloquée!" -ForegroundColor Red
        return $false
    } elseif ($result.indexed_vectors_count -gt 0) {
        Write-Host "`n   ✓ SUCCÈS: Indexation fonctionnelle!" -ForegroundColor Green
        return $true
    } else {
        Write-Host "`n   ℹ Collection vide, état normal" -ForegroundColor Cyan
        return $true
    }
    
} catch {
    Write-Host "   ✗ Erreur lors de la vérification: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) {
        Write-Host "   Détails: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
    }
    return $false
}

Write-Host "`n5. RESSOURCES" -ForegroundColor Yellow
$stats = docker stats qdrant_production --no-stream --format "{{.MemUsage}} | {{.CPUPerc}}"
Write-Host "   Mémoire / CPU: $stats" -ForegroundColor White

Write-Host "`n=== FIN VALIDATION ===" -ForegroundColor Cyan