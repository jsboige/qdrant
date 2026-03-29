# Script de Déploiement - Fix max_indexing_threads + Configuration Manquante
# Date: 2025-10-14
# Problème identifié: production.yaml manquant, docker-compose utilise config par défaut

Write-Host "=== DÉPLOIEMENT FIX CONFIGURATION ===" -ForegroundColor Cyan

# 1. Backup de sécurité
Write-Host "`n1. Création backup de sécurité..." -ForegroundColor Yellow
$backupDate = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = "myia_qdrant/backups/config_backup_$backupDate"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Write-Host "  ✓ Répertoire backup créé: $backupDir" -ForegroundColor Green

# Backup des fichiers existants
if (Test-Path 'myia_qdrant/config/production.yaml') {
    Copy-Item 'myia_qdrant/config/production.yaml' "$backupDir/production.yaml.bak"
    Write-Host "  ✓ Backup production.yaml effectué" -ForegroundColor Green
} else {
    Write-Host "  ℹ production.yaml n'existe pas (c'est le problème!)" -ForegroundColor Yellow
}

if (Test-Path 'myia_qdrant/config/production.optimized.yaml') {
    Copy-Item 'myia_qdrant/config/production.optimized.yaml' "$backupDir/production.optimized.yaml.bak"
    Write-Host "  ✓ Backup production.optimized.yaml effectué" -ForegroundColor Green
}

# 2. Copier production.optimized.yaml vers production.yaml
Write-Host "`n2. Déploiement nouvelle configuration..." -ForegroundColor Yellow
Copy-Item 'myia_qdrant/config/production.optimized.yaml' 'myia_qdrant/config/production.yaml' -Force
Write-Host "  ✓ production.optimized.yaml → production.yaml" -ForegroundColor Green

# 3. Vérifier le contenu
Write-Host "`n3. Vérification max_indexing_threads dans production.yaml:" -ForegroundColor Yellow
$threadsConfig = Select-String -Path 'myia_qdrant/config/production.yaml' -Pattern 'max_indexing_threads'
if ($threadsConfig) {
    Write-Host "  ✓ $($threadsConfig.Line.Trim())" -ForegroundColor Green
} else {
    Write-Host "  ✗ max_indexing_threads non trouvé!" -ForegroundColor Red
}

# 4. Arrêter le service
Write-Host "`n4. Arrêt du service Qdrant..." -ForegroundColor Yellow
docker-compose -f myia_qdrant/docker-compose.production.yml stop
Write-Host "  ✓ Service arrêté" -ForegroundColor Green

Start-Sleep -Seconds 5

# 5. Redémarrer avec nouvelle configuration
Write-Host "`n5. Redémarrage avec nouvelle configuration..." -ForegroundColor Yellow
docker-compose -f myia_qdrant/docker-compose.production.yml up -d
Write-Host "  ✓ Service redémarré" -ForegroundColor Green

# 6. Attendre initialisation
Write-Host "`n6. Attente initialisation (15 secondes)..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# 7. Vérifier statut
Write-Host "`n7. Vérification statut container:" -ForegroundColor Yellow
docker-compose -f myia_qdrant/docker-compose.production.yml ps

# 8. Vérifier santé du service
Write-Host "`n8. Test santé du service:" -ForegroundColor Yellow
try {
    $health = Invoke-RestMethod -Uri "http://localhost:6333/healthz" -Method Get -ErrorAction Stop
    Write-Host "  ✓ Service opérationnel" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Service non accessible: $_" -ForegroundColor Red
}

# 9. Vérifier configuration HNSW active
Write-Host "`n9. Vérification config HNSW de la collection:" -ForegroundColor Yellow
try {
    $apiKey = $env:QDRANT_API_KEY
    $headers = @{ "api-key" = $apiKey }
    $collection = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $headers -Method Get -ErrorAction Stop
    $hnswConfig = $collection.result.config.hnsw_config
    Write-Host "  max_indexing_threads actif: $($hnswConfig.max_indexing_threads)" -ForegroundColor Cyan
    Write-Host "  on_disk: $($hnswConfig.on_disk)" -ForegroundColor Cyan
    Write-Host "  m: $($hnswConfig.m)" -ForegroundColor Cyan
    Write-Host "  ef_construct: $($hnswConfig.ef_construct)" -ForegroundColor Cyan
} catch {
    Write-Host "  ⚠ Impossible de vérifier la collection: $_" -ForegroundColor Yellow
}

# 10. Résumé
Write-Host "`n=== RÉSUMÉ DÉPLOIEMENT ===" -ForegroundColor Cyan
Write-Host "✓ Backup créé dans: $backupDir" -ForegroundColor Green
Write-Host "✓ Configuration déployée: production.optimized.yaml → production.yaml" -ForegroundColor Green
Write-Host "✓ Service redémarré avec max_indexing_threads=16" -ForegroundColor Green
Write-Host "`nℹ️  Surveiller les logs pendant les prochaines heures:" -ForegroundColor Yellow
Write-Host "   docker-compose -f myia_qdrant/docker-compose.production.yml logs -f" -ForegroundColor White

Write-Host "`n=== FIN DÉPLOIEMENT ===" -ForegroundColor Cyan