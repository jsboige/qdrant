# Vérification de l'état de la collection roo_tasks_semantic_index

Write-Host "=== ÉTAT COLLECTION ROO_TASKS_SEMANTIC_INDEX ===" -ForegroundColor Cyan
Write-Host ""

# Récupérer les informations de la collection
$apiKey = $env:QDRANT_API_KEY
if (-not $apiKey) {
    Write-Host "⚠️  Variable QDRANT_API_KEY non définie, tentative sans authentification..." -ForegroundColor Yellow
    $headers = @{}
} else {
    $headers = @{
        "api-key" = $apiKey
    }
}

try {
    $response = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers -Method Get
    $result = $response.result
    
    Write-Host "✅ Collection trouvée" -ForegroundColor Green
    Write-Host ""
    
    # Statut général
    Write-Host "Status: " -NoNewline
    $statusColor = if ($result.status -eq "green") { "Green" } elseif ($result.status -eq "yellow") { "Yellow" } else { "Red" }
    Write-Host "$($result.status)" -ForegroundColor $statusColor
    
    # Points et vecteurs
    Write-Host "Points count: $($result.points_count)" -ForegroundColor $(if ($result.points_count -gt 0) { "Green" } else { "Yellow" })
    Write-Host "Indexed vectors: $($result.indexed_vectors_count)" -ForegroundColor $(if ($result.indexed_vectors_count -gt 0) { "Green" } else { "Yellow" })
    
    # Configuration HNSW
    Write-Host ""
    Write-Host "Configuration HNSW:" -ForegroundColor Cyan
    Write-Host "  Max indexing threads: $($result.config.hnsw_config.max_indexing_threads)"
    Write-Host "  M: $($result.config.hnsw_config.m)"
    Write-Host "  EF construct: $($result.config.hnsw_config.ef_construct)"
    
    # Optimizers status
    Write-Host ""
    Write-Host "Optimizers status:" -ForegroundColor Cyan
    if ($result.optimizer_status) {
        Write-Host "  Status: $($result.optimizer_status.status)"
        if ($result.optimizer_status.running) {
            Write-Host "  Running: Yes" -ForegroundColor Yellow
        } else {
            Write-Host "  Running: No" -ForegroundColor Green
        }
    }
    
    # Segments
    Write-Host ""
    Write-Host "Segments:" -ForegroundColor Cyan
    if ($result.segments_count) {
        Write-Host "  Count: $($result.segments_count)"
    }
    
    # Analyse de santé
    Write-Host ""
    Write-Host "Analyse de santé:" -ForegroundColor Cyan
    
    if ($result.status -eq "green" -and $result.points_count -gt 0) {
        Write-Host "  ✅ Collection opérationnelle et contient des données" -ForegroundColor Green
    } elseif ($result.status -eq "green" -and $result.points_count -eq 0) {
        Write-Host "  ⚠️  Collection opérationnelle mais vide (indexation en cours?)" -ForegroundColor Yellow
    } else {
        Write-Host "  ❌ Problème détecté avec la collection" -ForegroundColor Red
    }
    
    if ($result.config.hnsw_config.max_indexing_threads -eq 2) {
        Write-Host "  ✅ Threads d'indexation optimisés (2)" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Threads d'indexation: $($result.config.hnsw_config.max_indexing_threads)" -ForegroundColor Yellow
    }
    
} catch {
    Write-Host "❌ Erreur lors de la récupération de la collection" -ForegroundColor Red
    Write-Host "Détails: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Temps écoulé depuis redémarrage: ~$([math]::Round(((Get-Date) - (Get-Date '2025-10-13T23:30:00Z')).TotalMinutes, 1)) minutes" -ForegroundColor Yellow