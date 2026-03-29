#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Vide complètement le répertoire scripts/ en déplaçant tous les fichiers vers myia_qdrant/scripts/
    
.DESCRIPTION
    Ce script finalise la consolidation en vidant TOTALEMENT le répertoire scripts/.
    Tous les scripts doivent désormais être utilisés depuis myia_qdrant/scripts/.
#>

$ErrorActionPreference = 'Stop'

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║     VIDAGE COMPLET DU RÉPERTOIRE scripts/                ║" -ForegroundColor Red
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Red

# Chemins
$sourceDir = "scripts"
$targetDir = "myia_qdrant/scripts"

# Vérifier que les répertoires existent
if (-not (Test-Path $sourceDir)) {
    Write-Host "❌ ERREUR: Le répertoire $sourceDir n'existe pas" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $targetDir)) {
    Write-Host "❌ ERREUR: Le répertoire $targetDir n'existe pas" -ForegroundColor Red
    exit 1
}

# Lister tous les fichiers dans scripts/
Write-Host "▶ Étape 1: Listage des fichiers à supprimer..." -ForegroundColor Cyan
$filesToDelete = Get-ChildItem $sourceDir -File
Write-Host "   Fichiers trouvés: $($filesToDelete.Count)" -ForegroundColor Yellow

if ($filesToDelete.Count -eq 0) {
    Write-Host "`n✅ Le répertoire scripts/ est déjà vide!" -ForegroundColor Green
    exit 0
}

foreach ($file in $filesToDelete) {
    Write-Host "   - $($file.Name)" -ForegroundColor Gray
}

# Vérifier que chaque fichier existe déjà dans myia_qdrant/scripts/
Write-Host "`n▶ Étape 2: Vérification de la présence dans $targetDir..." -ForegroundColor Cyan
$allPresent = $true
$missingFiles = @()

foreach ($file in $filesToDelete) {
    $targetFile = Join-Path $targetDir $file.Name
    if (Test-Path $targetFile) {
        Write-Host "   ✓ $($file.Name) existe dans $targetDir" -ForegroundColor Green
    } else {
        Write-Host "   ✗ $($file.Name) MANQUANT dans $targetDir" -ForegroundColor Red
        $allPresent = $false
        $missingFiles += $file.Name
    }
}

if (-not $allPresent) {
    Write-Host "`n⚠ ATTENTION: Les fichiers suivants n'existent pas dans $targetDir :" -ForegroundColor Yellow
    foreach ($missing in $missingFiles) {
        Write-Host "   - $missing" -ForegroundColor Red
    }
    Write-Host "`nVoulez-vous continuer quand même? Les fichiers manquants seront DÉFINITIVEMENT PERDUS!" -ForegroundColor Red
    Write-Host "Appuyez sur Ctrl+C pour annuler, ou Entrée pour continuer..." -ForegroundColor Yellow
    Read-Host
}

# Suppression des fichiers
Write-Host "`n▶ Étape 3: Suppression de TOUS les fichiers dans scripts/..." -ForegroundColor Red
$deletedCount = 0
$errors = @()

foreach ($file in $filesToDelete) {
    try {
        Remove-Item -Path $file.FullName -Force
        Write-Host "   ✓ Supprimé: $($file.Name)" -ForegroundColor Green
        $deletedCount++
    }
    catch {
        Write-Host "   ✗ ERREUR lors de la suppression de $($file.Name): $_" -ForegroundColor Red
        $errors += @{
            File = $file.Name
            Error = $_.Exception.Message
        }
    }
}

# Vérification finale
Write-Host "`n▶ Étape 4: Vérification que scripts/ est VIDE..." -ForegroundColor Cyan
$remaining = Get-ChildItem $sourceDir -File

if ($remaining.Count -eq 0) {
    Write-Host "   ✅ SUCCESS: scripts/ est maintenant COMPLÈTEMENT VIDE (0 fichiers)" -ForegroundColor Green
} else {
    Write-Host "   ❌ ERREUR: Il reste encore $($remaining.Count) fichiers:" -ForegroundColor Red
    $remaining | Select-Object Name | Format-Table -AutoSize
}

# Rapport final
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    RAPPORT FINAL                           ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Write-Host "Fichiers supprimés: $deletedCount" -ForegroundColor $(if ($deletedCount -gt 0) { "Green" } else { "Yellow" })
Write-Host "Fichiers restants: $($remaining.Count)" -ForegroundColor $(if ($remaining.Count -eq 0) { "Green" } else { "Red" })
Write-Host "Erreurs: $($errors.Count)" -ForegroundColor $(if ($errors.Count -eq 0) { "Green" } else { "Red" })

if ($errors.Count -gt 0) {
    Write-Host "`n⚠ Erreurs détectées:" -ForegroundColor Yellow
    foreach ($err in $errors) {
        Write-Host "   - $($err.File): $($err.Error)" -ForegroundColor Red
    }
}

# Afficher le contenu de myia_qdrant/scripts/
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     TOUS LES SCRIPTS SONT MAINTENANT DANS:                ║" -ForegroundColor Cyan
Write-Host "║     myia_qdrant/scripts/                                   ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Get-ChildItem $targetDir -Filter "qdrant_*.ps1" | 
    Select-Object Name, @{Name='Taille (KB)'; Expression={[math]::Round($_.Length/1KB, 2)}} |
    Format-Table -AutoSize

Write-Host "Total: $((Get-ChildItem $targetDir -Filter 'qdrant_*.ps1').Count) scripts consolidés" -ForegroundColor Cyan

if ($remaining.Count -eq 0 -and $errors.Count -eq 0) {
    Write-Host "`n🎉 SUCCÈS TOTAL: Le répertoire scripts/ est maintenant VIDE!" -ForegroundColor Green
    Write-Host "   Utilisez désormais les scripts depuis: myia_qdrant/scripts/" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n⚠ ATTENTION: Des problèmes ont été détectés" -ForegroundColor Yellow
    exit 1
}