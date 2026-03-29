# Script de correction de la collection roo_tasks_semantic_index
# Date: 2025-10-13
# Problème: max_indexing_threads: 0 cause des freezes avec wait=true
# Solution: Recréer la collection avec max_indexing_threads: 2

param(
    [switch]$DryRun = $false,
    [switch]$Force = $false
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FIX roo_tasks_semantic_index" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "MODE DRY-RUN: Aucune modification ne sera appliquée" -ForegroundColor Yellow
    Write-Host ""
}

# 1. Récupérer l'API key
Write-Host "=== 1. RECUPERATION API KEY ===" -ForegroundColor Yellow
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

# 2. Vérifier l'état actuel de la collection
Write-Host "=== 2. ETAT ACTUEL DE LA COLLECTION ===" -ForegroundColor Yellow
try {
    $currentCollection = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers $headers -Method Get
    Write-Host "Collection trouvée:" -ForegroundColor Green
    Write-Host "  - Points: $($currentCollection.result.points_count)"
    Write-Host "  - Vecteurs indexés: $($currentCollection.result.indexed_vectors_count)"
    Write-Host "  - Status: $($currentCollection.result.status)"
    Write-Host "  - max_indexing_threads: $($currentCollection.result.config.hnsw_config.max_indexing_threads)" -ForegroundColor $(if ($currentCollection.result.config.hnsw_config.max_indexing_threads -eq 0) { "Red" } else { "Green" })
} catch {
    Write-Host "ERREUR lors de la récupération de la collection: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 3. Backup de la collection (snapshot)
Write-Host "=== 3. BACKUP DE LA COLLECTION ===" -ForegroundColor Yellow
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$snapshotName = "roo_tasks_semantic_index_backup_$timestamp"

if (-not $DryRun) {
    try {
        Write-Host "Création du snapshot: $snapshotName" -ForegroundColor Cyan
        $snapshotResult = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/snapshots" -Headers $headers -Method Post -Body "{`"snapshot_name`":`"$snapshotName`"}"
        Write-Host "Snapshot créé avec succès: $($snapshotResult.result.name)" -ForegroundColor Green
    } catch {
        Write-Host "ERREUR lors de la création du snapshot: $_" -ForegroundColor Red
        Write-Host "Abandon de l'opération pour sécurité" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[DRY-RUN] Snapshot qui serait créé: $snapshotName" -ForegroundColor Yellow
}
Write-Host ""

# 4. Export des points existants (si nécessaire pour restauration)
Write-Host "=== 4. EXPORT DES POINTS EXISTANTS ===" -ForegroundColor Yellow
$points = @()
if ($currentCollection.result.points_count -gt 0) {
    try {
        $scrollResult = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/points/scroll" -Headers $headers -Method Post -Body '{"limit":100,"with_payload":true,"with_vector":true}'
        $points = $scrollResult.result.points
        Write-Host "Exporté: $($points.Count) points" -ForegroundColor Green
        
        if (-not $DryRun) {
            $exportPath = "backups/roo_tasks_semantic_index_points_$timestamp.json"
            $points | ConvertTo-Json -Depth 10 | Out-File -FilePath $exportPath -Encoding utf8
            Write-Host "Points sauvegardés dans: $exportPath" -ForegroundColor Green
        } else {
            Write-Host "[DRY-RUN] Points qui seraient sauvegardés: $($points.Count)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "ATTENTION: Impossible d'exporter les points: $_" -ForegroundColor Yellow
        if (-not $Force) {
            Write-Host "Continuer quand même ? (O/N)" -ForegroundColor Yellow
            $response = Read-Host
            if ($response -ne "O") {
                Write-Host "Opération annulée" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "Mode -Force activé: continuation automatique" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "Aucun point à exporter (collection vide)" -ForegroundColor Cyan
}
Write-Host ""

# 5. Suppression de la collection existante
Write-Host "=== 5. SUPPRESSION DE LA COLLECTION ===" -ForegroundColor Yellow
if (-not $DryRun) {
    Write-Host "ATTENTION: La collection va être supprimée !" -ForegroundColor Red
    Write-Host "Un backup a été créé: $snapshotName" -ForegroundColor Yellow
    
    if (-not $Force) {
        Write-Host "Voulez-vous continuer ? (O/N)" -ForegroundColor Yellow
        $response = Read-Host
    } else {
        Write-Host "Mode -Force activé: suppression automatique" -ForegroundColor Yellow
        $response = "O"
    }
    
    if ($response -eq "O") {
        try {
            $deleteResult = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers -Method Delete
            Write-Host "Collection supprimée avec succès" -ForegroundColor Green
            Start-Sleep -Seconds 2
        } catch {
            Write-Host "ERREUR lors de la suppression: $_" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "Opération annulée par l'utilisateur" -ForegroundColor Yellow
        exit 0
    }
} else {
    Write-Host "[DRY-RUN] Collection qui serait supprimée: roo_tasks_semantic_index" -ForegroundColor Yellow
}
Write-Host ""

# 6. Recréation de la collection avec configuration corrigée
Write-Host "=== 6. RECREATION DE LA COLLECTION ===" -ForegroundColor Yellow

$newConfig = @{
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
        max_indexing_threads = 2  # ⚠️ CORRECTION: 0 -> 2
        on_disk = $true
    }
    optimizer_config = @{
        deleted_threshold = 0.2
        vacuum_min_vector_number = 10000
        default_segment_number = 0
        memmap_threshold = 300000
        indexing_threshold = 300000
        flush_interval_sec = 5
    }
    wal_config = @{
        wal_capacity_mb = 512
        wal_segments_ahead = 0
        wal_retain_closed = 1
    }
}

$createBody = @{
    name = "roo_tasks_semantic_index"
    vectors = $newConfig.vectors
    shard_number = $newConfig.shard_number
    replication_factor = $newConfig.replication_factor
    write_consistency_factor = $newConfig.write_consistency_factor
    on_disk_payload = $newConfig.on_disk_payload
    hnsw_config = $newConfig.hnsw_config
    optimizer_config = $newConfig.optimizer_config
    wal_config = $newConfig.wal_config
} | ConvertTo-Json -Depth 10

if (-not $DryRun) {
    try {
        Write-Host "Création de la nouvelle collection avec max_indexing_threads: 2" -ForegroundColor Cyan
        $createResult = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers -Method Put -Body $createBody
        Write-Host "Collection recréée avec succès" -ForegroundColor Green
        Start-Sleep -Seconds 2
    } catch {
        Write-Host "ERREUR lors de la recréation: $_" -ForegroundColor Red
        Write-Host "Vous pouvez restaurer depuis le snapshot: $snapshotName" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[DRY-RUN] Configuration qui serait appliquée:" -ForegroundColor Yellow
    Write-Host $createBody
}
Write-Host ""

# 7. Restauration des points (si existants)
Write-Host "=== 7. RESTAURATION DES POINTS ===" -ForegroundColor Yellow
if ($points.Count -gt 0) {
    if (-not $DryRun) {
        try {
            Write-Host "Réinsertion de $($points.Count) points..." -ForegroundColor Cyan
            $upsertBody = @{
                points = $points
            } | ConvertTo-Json -Depth 10
            
            $upsertResult = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index/points?wait=true" -Headers $headers -Method Put -Body $upsertBody
            Write-Host "Points réinsérés avec succès" -ForegroundColor Green
        } catch {
            Write-Host "ERREUR lors de la réinsertion des points: $_" -ForegroundColor Red
            Write-Host "Les points sont sauvegardés dans: backups/roo_tasks_semantic_index_points_$timestamp.json" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[DRY-RUN] $($points.Count) points qui seraient réinsérés" -ForegroundColor Yellow
    }
} else {
    Write-Host "Aucun point à restaurer" -ForegroundColor Cyan
}
Write-Host ""

# 8. Vérification finale
Write-Host "=== 8. VERIFICATION FINALE ===" -ForegroundColor Yellow
if (-not $DryRun) {
    Start-Sleep -Seconds 2
    try {
        $verifyCollection = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers $headers -Method Get
        Write-Host "Collection vérifiée:" -ForegroundColor Green
        Write-Host "  - Points: $($verifyCollection.result.points_count)" -ForegroundColor $(if ($verifyCollection.result.points_count -eq $currentCollection.result.points_count) { "Green" } else { "Yellow" })
        Write-Host "  - Vecteurs indexés: $($verifyCollection.result.indexed_vectors_count)" -ForegroundColor Cyan
        Write-Host "  - Status: $($verifyCollection.result.status)" -ForegroundColor $(if ($verifyCollection.result.status -eq "green") { "Green" } else { "Yellow" })
        Write-Host "  - max_indexing_threads: $($verifyCollection.result.config.hnsw_config.max_indexing_threads)" -ForegroundColor $(if ($verifyCollection.result.config.hnsw_config.max_indexing_threads -gt 0) { "Green" } else { "Red" })
        
        if ($verifyCollection.result.config.hnsw_config.max_indexing_threads -gt 0) {
            Write-Host ""
            Write-Host "✅ CORRECTION REUSSIE !" -ForegroundColor Green
            Write-Host "L'indexation est maintenant activée avec $($verifyCollection.result.config.hnsw_config.max_indexing_threads) threads" -ForegroundColor Green
            Write-Host "Les freezes devraient maintenant être résolus" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "⚠️ ATTENTION: max_indexing_threads toujours à 0" -ForegroundColor Red
        }
    } catch {
        Write-Host "ERREUR lors de la vérification: $_" -ForegroundColor Red
    }
} else {
    Write-Host "[DRY-RUN] Vérification qui serait effectuée" -ForegroundColor Yellow
}
Write-Host ""

# 9. Résumé
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "RESUME DE L'OPERATION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if (-not $DryRun) {
    Write-Host "✅ Snapshot créé: $snapshotName" -ForegroundColor Green
    Write-Host "✅ Collection roo_tasks_semantic_index recréée" -ForegroundColor Green
    Write-Host "✅ Configuration corrigée: max_indexing_threads = 2" -ForegroundColor Green
    if ($points.Count -gt 0) {
        Write-Host "✅ $($points.Count) points restaurés" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "PROCHAINES ETAPES:" -ForegroundColor Yellow
    Write-Host "1. Monitorer les logs pendant 24h pour vérifier l'absence d'erreurs 400" -ForegroundColor Cyan
    Write-Host "2. Vérifier que les vecteurs sont bien indexés (indexed_vectors_count > 0)" -ForegroundColor Cyan
    Write-Host "3. Si tout fonctionne, planifier l'upgrade RAM à 32GB (Solution 3)" -ForegroundColor Cyan
} else {
    Write-Host "MODE DRY-RUN - Aucune modification effectuée" -ForegroundColor Yellow
    Write-Host "Exécutez sans -DryRun pour appliquer les changements" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "SCRIPT TERMINE" -ForegroundColor Green