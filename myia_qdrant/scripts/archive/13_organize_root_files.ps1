# Script de rangement des fichiers à la racine vers myia_qdrant
# Date: 2025-10-13

Write-Host "=== RANGEMENT DES FICHIERS RACINE ===" -ForegroundColor Cyan

# Déplacer les documents de migration
Write-Host "Déplacement des documents de migration..." -ForegroundColor Yellow
$migrationDocs = @(
    "MIGRATION_GUIDE.md",
    "MIGRATION_REPORT_20251008.md",
    "SETUP_STUDENTS_QDRANT.md",
    "STUDENTS_ANALYSIS_20251008.md",
    "STUDENTS_MIGRATION_PLAN.md"
)

foreach ($doc in $migrationDocs) {
    if (Test-Path $doc) {
        Move-Item -Path $doc -Destination "myia_qdrant/docs/" -Force
        Write-Host "  ✓ $doc -> myia_qdrant/docs/" -ForegroundColor Green
    }
}

# Déplacer les incidents et logs
Write-Host "`nDéplacement des incidents et logs..." -ForegroundColor Yellow
if (Test-Path "INCIDENT_20250929_001202.json") {
    New-Item -ItemType Directory -Path "myia_qdrant/docs/incidents/20250929" -Force | Out-Null
    Move-Item -Path "INCIDENT_20250929_001202.json" -Destination "myia_qdrant/docs/incidents/20250929/" -Force
    Write-Host "  ✓ INCIDENT_20250929_001202.json -> myia_qdrant/docs/incidents/20250929/" -ForegroundColor Green
}

if (Test-Path "freeze_analysis_logs.txt") {
    Move-Item -Path "freeze_analysis_logs.txt" -Destination "myia_qdrant/docs/incidents/20251013_freeze/" -Force
    Write-Host "  ✓ freeze_analysis_logs.txt -> myia_qdrant/docs/incidents/20251013_freeze/" -ForegroundColor Green
}

# Déplacer backups
Write-Host "`nDéplacement du répertoire backups..." -ForegroundColor Yellow
if (Test-Path "backups") {
    if (-not (Test-Path "myia_qdrant/backups")) {
        Move-Item -Path "backups" -Destination "myia_qdrant/backups" -Force
        Write-Host "  ✓ backups/ -> myia_qdrant/backups/" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ myia_qdrant/backups existe déjà, fusion nécessaire" -ForegroundColor Yellow
    }
}

# Vérifier le README.md
Write-Host "`nVérification du README.md..." -ForegroundColor Yellow
if (Test-Path "README.md") {
    $rootReadme = Get-Content "README.md" -Raw
    if ($rootReadme -match "myia_qdrant|Qdrant Management") {
        Write-Host "  ⚠ README.md semble être celui de myia_qdrant, à vérifier manuellement" -ForegroundColor Yellow
    }
}

Write-Host "`n=== RANGEMENT TERMINÉ ===" -ForegroundColor Green