# ============================================================================
# Script de Finalisation de la Consolidation des Scripts Qdrant
# ============================================================================
# Date: 2025-10-13
# Tâche: 09 - Finaliser la consolidation
#
# Ce script :
# 1. Copie les 7 scripts unifiés de myia_qdrant/scripts/ vers scripts/
# 2. Supprime tous les anciens scripts de scripts/
# 3. Vérifie que scripts/ ne contient que les nouveaux scripts
# 4. Génère un rapport de consolidation
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       FINALISATION DE LA CONSOLIDATION DES SCRIPTS        ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$report = @{
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ScriptsCopied = @()
    ScriptsDeleted = @()
    Errors = @()
}

# ============================================================================
# ÉTAPE 1: COPIER LES NOUVEAUX SCRIPTS
# ============================================================================

Write-Host "▶ Étape 1: Copie des scripts unifiés..." -ForegroundColor Yellow

$sourceDir = "myia_qdrant/scripts"
$targetDir = "scripts"

$newScripts = Get-ChildItem $sourceDir -Filter "qdrant_*.ps1" -File

Write-Host "   Scripts à copier: $($newScripts.Count)" -ForegroundColor Cyan

foreach ($script in $newScripts) {
    try {
        Copy-Item $script.FullName $targetDir -Force
        Write-Host "   ✓ Copié: $($script.Name)" -ForegroundColor Green
        $report.ScriptsCopied += $script.Name
    } catch {
        Write-Host "   ✗ Erreur: $($script.Name) - $($_.Exception.Message)" -ForegroundColor Red
        $report.Errors += "Copie échouée: $($script.Name)"
    }
}

# ============================================================================
# ÉTAPE 2: SUPPRIMER LES ANCIENS SCRIPTS
# ============================================================================

Write-Host "`n▶ Étape 2: Suppression des anciens scripts..." -ForegroundColor Yellow

# Liste des anciens scripts à supprimer (tous sauf les nouveaux qdrant_*.ps1)
$oldScripts = Get-ChildItem $targetDir -Filter "*.ps1" -File | 
    Where-Object { $_.Name -notmatch '^qdrant_' }

Write-Host "   Scripts à supprimer: $($oldScripts.Count)" -ForegroundColor Cyan

foreach ($script in $oldScripts) {
    try {
        Remove-Item $script.FullName -Force
        Write-Host "   ✓ Supprimé: $($script.Name)" -ForegroundColor Red
        $report.ScriptsDeleted += $script.Name
    } catch {
        Write-Host "   ✗ Erreur: $($script.Name) - $($_.Exception.Message)" -ForegroundColor Red
        $report.Errors += "Suppression échouée: $($script.Name)"
    }
}

# ============================================================================
# ÉTAPE 3: VÉRIFICATION
# ============================================================================

Write-Host "`n▶ Étape 3: Vérification..." -ForegroundColor Yellow

$finalScripts = Get-ChildItem $targetDir -Filter "*.ps1" -File
$expectedScripts = @(
    "qdrant_backup.ps1",
    "qdrant_migrate.ps1",
    "qdrant_monitor.ps1",
    "qdrant_rollback.ps1",
    "qdrant_restart.ps1",
    "qdrant_update.ps1",
    "qdrant_verify.ps1"
)

Write-Host "   Scripts présents dans scripts/: $($finalScripts.Count)" -ForegroundColor Cyan

$allPresent = $true
foreach ($expected in $expectedScripts) {
    $found = $finalScripts | Where-Object { $_.Name -eq $expected }
    if ($found) {
        Write-Host "   ✓ $expected" -ForegroundColor Green
    } else {
        Write-Host "   ✗ $expected MANQUANT" -ForegroundColor Red
        $allPresent = $false
        $report.Errors += "Script manquant: $expected"
    }
}

# Vérifier qu'il n'y a pas de scripts inattendus
$unexpected = $finalScripts | Where-Object { $_.Name -notin $expectedScripts }
if ($unexpected) {
    Write-Host "`n   ⚠ Scripts inattendus détectés:" -ForegroundColor Yellow
    foreach ($script in $unexpected) {
        Write-Host "     - $($script.Name)" -ForegroundColor Yellow
    }
}

# ============================================================================
# ÉTAPE 4: RAPPORT FINAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    RAPPORT FINAL                           ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

Write-Host "Scripts copiés: $($report.ScriptsCopied.Count)" -ForegroundColor Green
foreach ($script in $report.ScriptsCopied) {
    Write-Host "  ✓ $script" -ForegroundColor Gray
}

Write-Host "`nScripts supprimés: $($report.ScriptsDeleted.Count)" -ForegroundColor Red
foreach ($script in $report.ScriptsDeleted) {
    Write-Host "  ✓ $script" -ForegroundColor Gray
}

if ($report.Errors.Count -gt 0) {
    Write-Host "`nErreurs: $($report.Errors.Count)" -ForegroundColor Red
    foreach ($err in $report.Errors) {
        Write-Host "  ✗ $err" -ForegroundColor Red
    }
}

# Sauvegarder le rapport
$reportPath = "myia_qdrant/scripts/consolidation_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$report | ConvertTo-Json -Depth 3 | Out-File $reportPath

Write-Host "`n✅ Consolidation finalisée avec succès!" -ForegroundColor Green
Write-Host "📄 Rapport sauvegardé: $reportPath" -ForegroundColor Cyan

# ============================================================================
# ÉTAPE 5: AFFICHER LE CONTENU FINAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║              CONTENU FINAL DE scripts/                     ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Get-ChildItem $targetDir -File | 
    Select-Object Name, @{Name='Taille (KB)'; Expression={[math]::Round($_.Length/1KB, 2)}} |
    Format-Table -AutoSize

Write-Host "Total: $((Get-ChildItem $targetDir -File).Count) fichiers" -ForegroundColor Cyan

if ($allPresent -and $report.Errors.Count -eq 0) {
    Write-Host "`n🎉 SUCCÈS TOTAL: Tous les scripts unifiés sont en place!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n⚠ ATTENTION: Des problèmes ont été détectés, vérifiez le rapport" -ForegroundColor Yellow
    exit 1
}