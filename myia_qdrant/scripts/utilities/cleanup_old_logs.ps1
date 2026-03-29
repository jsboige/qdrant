<#
.SYNOPSIS
    Nettoyage sécurisé des logs volumineux et fichiers temporaires obsolètes

.DESCRIPTION
    Script de nettoyage automatisé pour supprimer les logs de diagnostic volumineux,
    fichiers temporaires et backups de configuration obsolètes.
    
    Inclut un mode DryRun pour validation avant suppression réelle.
    Génère un rapport détaillé dans myia_qdrant/logs/cleanup_YYYYMMDD_HHMMSS.log

.PARAMETER DryRun
    Si $true, simule la suppression sans modifier les fichiers (par défaut: $true)

.PARAMETER SkipBackup
    Si $true, ne crée pas d'archive de sécurité avant suppression (par défaut: $false)

.EXAMPLE
    # Mode simulation (recommandé en premier)
    .\cleanup_old_logs.ps1
    
.EXAMPLE
    # Exécution réelle après validation
    .\cleanup_old_logs.ps1 -DryRun:$false
    
.EXAMPLE
    # Exécution sans archive de sécurité
    .\cleanup_old_logs.ps1 -DryRun:$false -SkipBackup
    
.NOTES
    Auteur: Roo Code Mode
    Date: 2025-10-16
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $true,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipBackup
)

# Configuration
$ErrorActionPreference = "Stop"
$BaseDir = "d:\qdrant\myia_qdrant"
$LogsDir = Join-Path $BaseDir "logs"
$ArchiveDir = Join-Path $BaseDir "archive\logs_cleanup_$(Get-Date -Format 'yyyyMMdd')"
$ReportFile = Join-Path $LogsDir "cleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Définition des batches de fichiers à nettoyer
$FilesToClean = @{
    "Batch 1 - Logs diagnostics volumineux (>1MB)" = @(
        @{ Path = "diagnostics\20251016_logs_2_restarts.txt"; MinSize = 1MB }
        @{ Path = "diagnostics\20251015_freeze_7h30_complet.txt"; MinSize = 100KB }
        @{ Path = "diagnostics\20251015_blocage_post_hnsw.log"; MinSize = 100KB }
        @{ Path = "diagnostics\20251015_blocage_tail500.log"; MinSize = 10KB }
    )
    
    "Batch 2 - Logs incidents archivés" = @(
        @{ Path = "docs\incidents\20251013_freeze\freeze_analysis_logs.txt"; MinSize = 1MB }
        @{ Path = "docs\incidents\20251013_freeze\freeze_3_logs.txt"; MinSize = 100KB }
    )
    
    "Batch 3 - Logs racine (si existe)" = @(
        @{ Path = "..\crash_logs_complets.txt"; MinSize = 100KB }
    )
    
    "Batch 4 - Anciens logs de fix" = @(
        @{ Path = "logs\20251014_fix_hnsw_20251014_101849.log"; MinSize = 0 }
        @{ Path = "logs\20251014_fix_hnsw_20251014_101925.log"; MinSize = 0 }
        @{ Path = "logs\20251014_apply_fixes_20251014_095912.log"; MinSize = 0 }
        @{ Path = "logs\20251014_apply_fixes_20251014_101544.log"; MinSize = 0 }
    )
    
    "Batch 5 - Backups config temporaires" = @(
        @{ Path = "config\production.optimized.yaml.backup_20251015_230954"; MinSize = 0 }
        @{ Path = "config\production.optimized.yaml.backup_20251015_231522"; MinSize = 0 }
    )
}

# Fonctions utilitaires
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [$Level] $Message"
    Write-Host $LogMessage
    Add-Content -Path $ReportFile -Value $LogMessage
}

function Format-FileSize {
    param([long]$Size)
    
    if ($Size -ge 1GB) {
        return "{0:N2} GB" -f ($Size / 1GB)
    } elseif ($Size -ge 1MB) {
        return "{0:N2} MB" -f ($Size / 1MB)
    } elseif ($Size -ge 1KB) {
        return "{0:N2} KB" -f ($Size / 1KB)
    } else {
        return "$Size bytes"
    }
}

function Test-FileCanBeDeleted {
    param([string]$FilePath)
    
    $FullPath = Join-Path $BaseDir $FilePath
    
    # Vérifier existence
    if (-not (Test-Path $FullPath)) {
        return @{ CanDelete = $false; Reason = "Fichier n'existe pas" }
    }
    
    # Vérifier type (pas de .md, .json, .ps1 sauf logs)
    $Extension = [System.IO.Path]::GetExtension($FullPath)
    if ($Extension -in @(".md", ".json", ".ps1") -and $FilePath -notmatch "logs\\") {
        return @{ CanDelete = $false; Reason = "Type de fichier protégé: $Extension" }
    }
    
    # Vérifier âge (> 7 jours OU explicitement dans la liste)
    $FileAge = (Get-Date) - (Get-Item $FullPath).LastWriteTime
    if ($FileAge.Days -lt 7 -and $FilePath -notmatch "20251014|20251015") {
        return @{ CanDelete = $false; Reason = "Fichier trop récent (< 7 jours)" }
    }
    
    return @{ CanDelete = $true; Reason = "OK" }
}

# Initialisation
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  NETTOYAGE LOGS VOLUMINEUX v1.0" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "MODE: SIMULATION (DryRun)" -ForegroundColor Yellow
    Write-Host "Aucun fichier ne sera supprimé`n" -ForegroundColor Yellow
} else {
    Write-Host "MODE: EXÉCUTION RÉELLE" -ForegroundColor Red
    Write-Host "Les fichiers SERONT SUPPRIMÉS !`n" -ForegroundColor Red
}

# Créer répertoire de logs si nécessaire
if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}

Write-Log "========================================" "START"
Write-Log "Début du nettoyage - Mode: $(if ($DryRun) { 'SIMULATION' } else { 'RÉEL' })"
Write-Log "Répertoire de base: $BaseDir"
Write-Log "========================================"

# Statistiques globales
$TotalFiles = 0
$TotalSize = 0
$FilesDeleted = 0
$SizeRecovered = 0
$FilesSkipped = 0
$FilesFailed = 0

# Traitement par batch
foreach ($BatchName in $FilesToClean.Keys) {
    Write-Host "`n=== $BatchName ===" -ForegroundColor Cyan
    Write-Log "`n=== $BatchName ==="
    
    $BatchFiles = $FilesToClean[$BatchName]
    $BatchSize = 0
    $BatchDeleted = 0
    
    foreach ($FileInfo in $BatchFiles) {
        $RelativePath = $FileInfo.Path
        $FullPath = Join-Path $BaseDir $RelativePath
        $TotalFiles++
        
        # Vérifier si le fichier peut être supprimé
        $CheckResult = Test-FileCanBeDeleted -FilePath $RelativePath
        
        if (-not $CheckResult.CanDelete) {
            Write-Host "  [SKIP] $RelativePath" -ForegroundColor Gray
            Write-Host "         Raison: $($CheckResult.Reason)" -ForegroundColor Gray
            Write-Log "SKIP: $RelativePath - $($CheckResult.Reason)" "SKIP"
            $FilesSkipped++
            continue
        }
        
        # Récupérer taille du fichier
        try {
            $FileItem = Get-Item $FullPath
            $FileSize = $FileItem.Length
            $FormattedSize = Format-FileSize -Size $FileSize
            
            $TotalSize += $FileSize
            $BatchSize += $FileSize
            
            Write-Host "  [OK] $RelativePath" -ForegroundColor Green
            Write-Host "       Taille: $FormattedSize" -ForegroundColor Green
            Write-Host "       Modifié: $($FileItem.LastWriteTime)" -ForegroundColor Green
            
            Write-Log "FOUND: $RelativePath - Taille: $FormattedSize - Modifié: $($FileItem.LastWriteTime)"
            
            # Suppression (si mode réel)
            if (-not $DryRun) {
                try {
                    # Créer archive de sécurité si demandé
                    if (-not $SkipBackup) {
                        $ArchivePath = Join-Path $ArchiveDir $RelativePath
                        $ArchiveParent = Split-Path $ArchivePath -Parent
                        
                        if (-not (Test-Path $ArchiveParent)) {
                            New-Item -ItemType Directory -Path $ArchiveParent -Force | Out-Null
                        }
                        
                        Copy-Item -Path $FullPath -Destination $ArchivePath -Force
                        Write-Log "BACKUP: $RelativePath -> $ArchivePath" "BACKUP"
                    }
                    
                    # Supprimer le fichier
                    Remove-Item -Path $FullPath -Force
                    Write-Host "       [SUPPRIMÉ]" -ForegroundColor Red
                    Write-Log "DELETE: $RelativePath - SUCCÈS" "DELETE"
                    
                    $FilesDeleted++
                    $BatchDeleted++
                    $SizeRecovered += $FileSize
                    
                } catch {
                    Write-Host "       [ERREUR] $($_.Exception.Message)" -ForegroundColor Red
                    Write-Log "DELETE: $RelativePath - ERREUR: $($_.Exception.Message)" "ERROR"
                    $FilesFailed++
                }
            }
            
        } catch {
            Write-Host "  [ERREUR] $RelativePath" -ForegroundColor Red
            Write-Host "           $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "ERROR: $RelativePath - $($_.Exception.Message)" "ERROR"
            $FilesFailed++
        }
    }
    
    # Statistiques du batch
    if ($BatchSize -gt 0) {
        $FormattedBatchSize = Format-FileSize -Size $BatchSize
        Write-Host "`n  Sous-total batch: $FormattedBatchSize" -ForegroundColor Yellow
        Write-Log "BATCH TOTAL: $FormattedBatchSize"
    }
}

# Rapport final
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  RAPPORT FINAL" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Log "`n========================================"
Write-Log "RAPPORT FINAL"
Write-Log "========================================"

$Report = @"

Fichiers analysés:      $TotalFiles
Fichiers sautés:        $FilesSkipped
Fichiers en erreur:     $FilesFailed
Fichiers $(if ($DryRun) { 'à supprimer' } else { 'supprimés' }): $FilesDeleted

Taille totale identifiée: $(Format-FileSize -Size $TotalSize)
Espace $(if ($DryRun) { 'récupérable' } else { 'récupéré' }):        $(Format-FileSize -Size $SizeRecovered)

Mode d'exécution:       $(if ($DryRun) { 'SIMULATION (DryRun)' } else { 'RÉEL' })
Archive de sécurité:    $(if ($SkipBackup) { 'NON' } else { "OUI ($ArchiveDir)" })
Rapport sauvegardé:     $ReportFile
"@

Write-Host $Report
Write-Log $Report

if ($DryRun) {
    Write-Host "`n⚠️  MODE SIMULATION ACTIF" -ForegroundColor Yellow
    Write-Host "Pour exécuter la suppression réelle, relancez avec:" -ForegroundColor Yellow
    Write-Host ".\cleanup_old_logs.ps1 -DryRun:`$false" -ForegroundColor Yellow
} else {
    Write-Host "`n✅ Nettoyage terminé avec succès !" -ForegroundColor Green
    
    if (-not $SkipBackup -and $FilesDeleted -gt 0) {
        Write-Host "`nArchive de sécurité créée dans:" -ForegroundColor Green
        Write-Host "$ArchiveDir" -ForegroundColor Green
    }
}

Write-Log "`n========================================"
Write-Log "Nettoyage terminé - Status: $(if ($DryRun) { 'SIMULATION' } else { 'RÉEL' })" "END"
Write-Log "========================================"

Write-Host "`nRapport complet disponible dans:" -ForegroundColor Cyan
Write-Host "$ReportFile`n" -ForegroundColor Cyan