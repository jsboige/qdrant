# Script de recréation de la collection roo_tasks_semantic_index
# Date: 2025-10-13
# Raison: Indexation bloquée irrémédiablement

Write-Host "=== RECRÉATION COLLECTION roo_tasks_semantic_index ===" -ForegroundColor Cyan
Write-Host "⚠ Cette opération va SUPPRIMER les 8 points existants!" -ForegroundColor Yellow
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# Récupérer l'API key en reconstruisant le fichier fragmenté
$envContent = (Get-Content .env.production -Raw) -replace '\r?\n(?![A-Z_]+=)',''
if ($envContent -match 'QDRANT_SERVICE_API_KEY=([^\r\n]+)') {
    $apiKey = $matches[1].Trim()
    $headers = @{ "api-key" = $apiKey }
    Write-Host "   ✓ API Key chargée" -ForegroundColor Green
} else {
    Write-Host "✗ Impossible de trouver QDRANT_SERVICE_API_KEY" -ForegroundColor Red
    exit 1
}

Write-Host "`n1. SAUVEGARDE DE LA CONFIGURATION ACTUELLE" -ForegroundColor Yellow
try {
    $collection = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers
    $config = $collection.result.config
    
    # Sauvegarder la config en JSON
    $configJson = $config | ConvertTo-Json -Depth 10
    $backupPath = "diagnostics/20251013_roo_tasks_semantic_index_backup_config.json"
    $configJson | Out-File -FilePath $backupPath -Encoding utf8
    
    Write-Host "   ✓ Configuration sauvegardée dans: $backupPath" -ForegroundColor Green
    Write-Host "   Paramètres clés:" -ForegroundColor White
    Write-Host "     - Vector size: $($config.params.vectors.''.size)" -ForegroundColor Gray
    Write-Host "     - Distance: $($config.params.vectors.''.distance)" -ForegroundColor Gray
    Write-Host "     - max_indexing_threads: $($config.hnsw_config.max_indexing_threads)" -ForegroundColor Gray
} catch {
    Write-Host "   ✗ Erreur lors de la sauvegarde: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "`n2. SUPPRESSION DE LA COLLECTION" -ForegroundColor Yellow
Write-Host "   Suppression en cours..." -ForegroundColor White
try {
    $deleteResult = Invoke-RestMethod -Method Delete `
        -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" `
        -Headers $headers `
        -TimeoutSec 30
    
    if ($deleteResult.result -eq $true) {
        Write-Host "   ✓ Collection supprimée avec succès" -ForegroundColor Green
    } else {
        Write-Host "   ⚠ Résultat inattendu: $($deleteResult | ConvertTo-Json)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "   ✗ Erreur lors de la suppression: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) {
        Write-Host "   Détails: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
    }
    exit 1
}

Write-Host "`n3. ATTENTE (3 secondes)..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

Write-Host "`n4. RECRÉATION DE LA COLLECTION" -ForegroundColor Yellow
Write-Host "   Configuration:" -ForegroundColor White
Write-Host "     - Vector size: 1536 (OpenAI)" -ForegroundColor Gray
Write-Host "     - Distance: Cosine" -ForegroundColor Gray
Write-Host "     - max_indexing_threads: 2 (CORRIGÉ)" -ForegroundColor Green
Write-Host "     - on_disk: true" -ForegroundColor Gray

$newCollectionConfig = @{
    vectors = @{
        size = 1536
        distance = "Cosine"
    }
    shard_number = 1
    replication_factor = 1
    write_consistency_factor = 1
    on_disk_payload = $true
    hnsw_config = @{
        m = 32
        ef_construct = 200
        full_scan_threshold = 10000
        max_indexing_threads = 2
        on_disk = $true
    }
    optimizers_config = @{
        deleted_threshold = 0.2
        vacuum_min_vector_number = 10000
        default_segment_number = 0
        indexing_threshold = 300000
        flush_interval_sec = 5
    }
    wal_config = @{
        wal_capacity_mb = 512
        wal_segments_ahead = 0
    }
} | ConvertTo-Json -Depth 10

try {
    $createResult = Invoke-RestMethod -Method Put `
        -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $newCollectionConfig `
        -TimeoutSec 30
    
    if ($createResult.result -eq $true) {
        Write-Host "   ✓ Collection recréée avec succès!" -ForegroundColor Green
    } else {
        Write-Host "   ⚠ Résultat inattendu: $($createResult | ConvertTo-Json)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "   ✗ Erreur lors de la création: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) {
        Write-Host "   Détails: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
    }
    exit 1
}

Write-Host "`n5. VALIDATION DE LA NOUVELLE COLLECTION" -ForegroundColor Yellow
Start-Sleep -Seconds 2

try {
    $newCollection = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers
    $result = $newCollection.result
    
    Write-Host "   Status: $($result.status)" -ForegroundColor $(if($result.status -eq 'green'){'Green'}else{'Red'})
    Write-Host "   Points: $($result.points_count)" -ForegroundColor White
    Write-Host "   Indexed vectors: $($result.indexed_vectors_count)" -ForegroundColor White
    Write-Host "   max_indexing_threads: $($result.config.hnsw_config.max_indexing_threads)" -ForegroundColor $(if($result.config.hnsw_config.max_indexing_threads -eq 2){'Green'}else{'Red'})
    
    if ($result.status -eq 'green' -and $result.config.hnsw_config.max_indexing_threads -eq 2) {
        Write-Host "`n   ✓ SUCCÈS: Collection recréée et fonctionnelle!" -ForegroundColor Green
        Write-Host "   ℹ La collection est maintenant vide et prête à recevoir des points" -ForegroundColor Cyan
        return $true
    } else {
        Write-Host "`n   ⚠ Problème détecté dans la nouvelle collection" -ForegroundColor Yellow
        return $false
    }
} catch {
    Write-Host "   ✗ Erreur lors de la validation: $($_.Exception.Message)" -ForegroundColor Red
    return $false
}

Write-Host "`n=== FIN RECRÉATION ===" -ForegroundColor Cyan