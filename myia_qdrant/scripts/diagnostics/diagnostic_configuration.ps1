# Script de Diagnostic Configuration Qdrant
# Date: 2025-10-14

Write-Host "=== VÉRIFICATION CONFIGURATION ===" -ForegroundColor Cyan

# 1. Fichiers config existants
Write-Host "`n1. Fichiers config existants:" -ForegroundColor Yellow
Get-ChildItem myia_qdrant/config/*.yaml | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

# 2. Production.yaml existe?
Write-Host "`n2. Production.yaml existe?" -ForegroundColor Yellow
if (Test-Path 'myia_qdrant/config/production.yaml') {
    Write-Host "  ✓ OUI - utilisé par docker-compose" -ForegroundColor Green
    
    Write-Host "`n3. Contenu max_indexing_threads dans production.yaml:" -ForegroundColor Yellow
    $prodThreads = Select-String -Path 'myia_qdrant/config/production.yaml' -Pattern 'max_indexing_threads' -Context 2,0
    if ($prodThreads) {
        $prodThreads | ForEach-Object { Write-Host $_.Line -ForegroundColor White }
    } else {
        Write-Host "  ⚠ max_indexing_threads non trouvé dans production.yaml" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ✗ NON - docker-compose va échouer!" -ForegroundColor Red
}

# 4. Production.optimized.yaml
Write-Host "`n4. Contenu max_indexing_threads dans production.optimized.yaml:" -ForegroundColor Yellow
$optThreads = Select-String -Path 'myia_qdrant/config/production.optimized.yaml' -Pattern 'max_indexing_threads' -Context 2,0
if ($optThreads) {
    $optThreads | ForEach-Object { Write-Host $_.Line -ForegroundColor Cyan }
} else {
    Write-Host "  ⚠ max_indexing_threads non trouvé" -ForegroundColor Yellow
}

# 5. Docker-compose configuration
Write-Host "`n5. Docker-compose pointe vers:" -ForegroundColor Yellow
$composeConfig = Select-String -Path 'myia_qdrant/docker-compose.production.yml' -Pattern 'production\.yaml'
if ($composeConfig) {
    $composeConfig | ForEach-Object { Write-Host "  $($_.Line.Trim())" -ForegroundColor White }
}

# 6. Différences entre les fichiers
Write-Host "`n6. PROBLÈME IDENTIFIÉ:" -ForegroundColor Red
Write-Host "  - docker-compose.production.yml pointe vers ./config/production.yaml" -ForegroundColor Yellow
Write-Host "  - Modifications effectuées dans production.optimized.yaml" -ForegroundColor Yellow
Write-Host "  - Les 2 fichiers sont DIFFÉRENTS!" -ForegroundColor Red

# 7. Recommandation
Write-Host "`n7. SOLUTION REQUISE:" -ForegroundColor Green
Write-Host "  1. Copier production.optimized.yaml vers production.yaml" -ForegroundColor White
Write-Host "  2. OU modifier docker-compose.yml pour utiliser production.optimized.yaml" -ForegroundColor White
Write-Host "  3. Redémarrer le service" -ForegroundColor White

Write-Host "`n=== FIN VÉRIFICATION CONFIGURATION ===" -ForegroundColor Cyan