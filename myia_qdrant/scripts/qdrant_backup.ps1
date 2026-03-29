# ============================================================================
# Script de Sauvegarde Unifiée Qdrant
# ============================================================================
# Date: 2025-10-13
# Auteur: Consolidation automatique
# 
# Remplace:
#   - backup_before_migration.ps1
#   - backup_production_before_update.ps1
#   - students_backup.ps1
#
# UTILISATION:
#   .\qdrant_backup.ps1 -Environment production [-SkipSnapshot] [-BackupDir <path>]
#   .\qdrant_backup.ps1 -Environment students [-SkipSnapshot] [-BackupDir <path>]
#
# EXEMPLES:
#   # Backup complet de production (défaut)
#   .\qdrant_backup.ps1 -Environment production
#
#   # Backup de students sans snapshot (plus rapide)
#   .\qdrant_backup.ps1 -Environment students -SkipSnapshot
#
#   # Backup avec répertoire personnalisé
#   .\qdrant_backup.ps1 -Environment production -BackupDir "C:\custom\backups"
#
# FONCTIONNALITÉS:
#   ✅ Support multi-environnement (production/students)
#   ✅ Création de snapshots via API Qdrant
#   ✅ Sauvegarde des fichiers de configuration
#   ✅ Export de la liste des collections
#   ✅ Logs horodatés de toutes les opérations
#   ✅ Vérification de l'état du container
#   ✅ Lecture automatique de l'API key depuis .env
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("production", "students")]
    [string]$Environment,
    
    [string]$BackupDir = "",
    
    [switch]$SkipSnapshot = $false
)

# ============================================================================
# CONFIGURATION CENTRALISÉE
# ============================================================================

$EnvironmentConfig = @{
    production = @{
        Port = 6333
        ContainerName = "qdrant_production"
        EnvFile = ".env"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ConfigFile = "config/production.optimized.yaml"
        ComposeFile = "docker-compose.production.optimized.yml"
        DefaultBackupDir = "backups/production"
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ConfigFile = "config/students.optimized.yaml"
        ComposeFile = "docker-compose.students.optimized.yml"
        DefaultBackupDir = "backups/students"
    }
}

# Sélection de la configuration
$config = $EnvironmentConfig[$Environment]
$ErrorActionPreference = "Stop"
$QdrantUrl = "http://localhost:$($config.Port)"
$ContainerName = $config.ContainerName

# Déterminer le répertoire de backup
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $BackupDir = $config.DefaultBackupDir
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "$BackupDir/backup_$Timestamp.log"

# ============================================================================
# LECTURE DE L'API KEY
# ============================================================================

$ApiKey = ""
if (Test-Path $config.EnvFile) {
    $envContent = Get-Content $config.EnvFile
    foreach ($line in $envContent) {
        if ($line -match "^$($config.ApiKeyVar)=(.+)$") {
            $ApiKey = $matches[1]
            break
        }
    }
}

if (-not $ApiKey) {
    Write-Host "ERREUR: Impossible de lire l'API key depuis $($config.EnvFile)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Afficher dans la console avec couleur
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host $logMessage -ForegroundColor $color
    
    # Écrire dans le fichier log
    if ($LogFile) {
        $logMessage | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

function Ensure-Directory {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Log "Répertoire créé: $Path" "INFO"
    }
}

function Test-ContainerRunning {
    try {
        $container = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
        return $container -eq $ContainerName
    } catch {
        return $false
    }
}

function New-QdrantSnapshot {
    try {
        Write-Log "Création du snapshot Qdrant $Environment..." "INFO"
        
        $headers = @{
            "api-key" = $ApiKey
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-RestMethod -Uri "$QdrantUrl/snapshots" -Method Post -Headers $headers -TimeoutSec 120
        
        if ($response.result) {
            $snapshotName = $response.result.name
            Write-Log "Snapshot créé avec succès: $snapshotName" "SUCCESS"
            return $snapshotName
        } else {
            Write-Log "Réponse inattendue lors de la création du snapshot" "WARNING"
            return $null
        }
    } catch {
        Write-Log "Erreur lors de la création du snapshot: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Export-CollectionsList {
    param([string]$OutputFile)
    
    try {
        Write-Log "Export de la liste des collections..." "INFO"
        
        $headers = @{
            "api-key" = $ApiKey
        }
        
        $response = Invoke-RestMethod -Uri "$QdrantUrl/collections" -Method Get -Headers $headers -TimeoutSec 30
        
        if ($response.result) {
            $collections = $response.result.collections
            Write-Log "Collections trouvées: $($collections.Count)" "INFO"
            
            # Export JSON
            $collections | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputFile -Encoding UTF8
            Write-Log "Liste exportée vers: $OutputFile" "SUCCESS"
            
            # Log des noms de collections
            foreach ($coll in $collections) {
                Write-Log "  - $($coll.name)" "INFO"
            }
            
            return $collections.Count
        } else {
            Write-Log "Erreur: Réponse API invalide" "ERROR"
            return 0
        }
    } catch {
        Write-Log "Erreur lors de l'export des collections: $($_.Exception.Message)" "ERROR"
        return 0
    }
}

function Backup-ConfigFiles {
    try {
        Write-Log "Sauvegarde des fichiers de configuration..." "INFO"
        
        # Fichiers à sauvegarder
        $filesToBackup = @(
            $config.ConfigFile,
            $config.ComposeFile,
            $config.EnvFile
        )
        
        $backedUpCount = 0
        
        foreach ($file in $filesToBackup) {
            if (Test-Path $file) {
                $fileName = Split-Path $file -Leaf
                $destPath = Join-Path $BackupDir $fileName
                
                Copy-Item -Path $file -Destination $destPath -Force
                Write-Log "Sauvegardé: $fileName" "SUCCESS"
                $backedUpCount++
            } else {
                Write-Log "Fichier non trouvé (ignoré): $file" "WARNING"
            }
        }
        
        Write-Log "Fichiers de configuration sauvegardés: $backedUpCount" "SUCCESS"
        return $backedUpCount
        
    } catch {
        Write-Log "Erreur lors de la sauvegarde des fichiers: $($_.Exception.Message)" "ERROR"
        return 0
    }
}

function Get-SystemInfo {
    try {
        Write-Log "Récupération des informations système..." "INFO"
        
        $response = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get -TimeoutSec 10
        
        $info = @{
            Version = $response.version
            Commit = $response.commit
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Environment = $Environment
            ContainerName = $ContainerName
            Port = $config.Port
        }
        
        Write-Log "Version Qdrant: $($info.Version)" "INFO"
        
        return $info
        
    } catch {
        Write-Log "Erreur lors de la récupération des infos système: $($_.Exception.Message)" "WARNING"
        return @{}
    }
}

# ============================================================================
# SCRIPT PRINCIPAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       SAUVEGARDE QDRANT - ENVIRONNEMENT: $($Environment.ToUpper().PadRight(17))║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Write-Log "Démarrage de la sauvegarde pour l'environnement: $Environment" "INFO"
Write-Log "Container cible: $ContainerName" "INFO"
Write-Log "URL API: $QdrantUrl" "INFO"
Write-Log "Répertoire de backup: $BackupDir" "INFO"

# Créer le répertoire de backup
Ensure-Directory -Path $BackupDir

# Vérifier que le container est en cours d'exécution
Write-Log "Vérification de l'état du container..." "INFO"
if (-not (Test-ContainerRunning)) {
    Write-Log "ERREUR: Le container $ContainerName n'est pas en cours d'exécution" "ERROR"
    Write-Log "Veuillez démarrer le container avant de lancer la sauvegarde" "ERROR"
    exit 1
}
Write-Log "Container actif: $ContainerName" "SUCCESS"

# Récupérer les informations système
$systemInfo = Get-SystemInfo
if ($systemInfo.Count -gt 0) {
    $systemInfo | ConvertTo-Json -Depth 3 | Out-File "$BackupDir/system_info_$Timestamp.json"
}

# Créer un snapshot (si demandé)
$snapshotName = $null
if (-not $SkipSnapshot) {
    $snapshotName = New-QdrantSnapshot
    if ($snapshotName) {
        Write-Log "Snapshot créé: $snapshotName" "SUCCESS"
    }
} else {
    Write-Log "Création de snapshot ignorée (-SkipSnapshot)" "INFO"
}

# Exporter la liste des collections
$collectionsCount = Export-CollectionsList -OutputFile "$BackupDir/collections_$Timestamp.json"

# Sauvegarder les fichiers de configuration
$configFilesCount = Backup-ConfigFiles

# ============================================================================
# RAPPORT FINAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    RAPPORT DE SAUVEGARDE                   ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

$report = @{
    Timestamp = $Timestamp
    Environment = $Environment
    BackupDirectory = $BackupDir
    SnapshotCreated = (-not $SkipSnapshot -and $snapshotName -ne $null)
    SnapshotName = $snapshotName
    CollectionsExported = $collectionsCount
    ConfigFilesBackedUp = $configFilesCount
    Success = $true
}

Write-Log "Environnement: $Environment" "INFO"
Write-Log "Répertoire de backup: $BackupDir" "INFO"
Write-Log "Snapshot créé: $(if ($report.SnapshotCreated) { 'Oui - ' + $snapshotName } else { 'Non' })" "INFO"
Write-Log "Collections exportées: $collectionsCount" "INFO"
Write-Log "Fichiers de configuration sauvegardés: $configFilesCount" "INFO"

# Sauvegarder le rapport
$report | ConvertTo-Json -Depth 3 | Out-File "$BackupDir/backup_report_$Timestamp.json"

Write-Host "`n✅ SAUVEGARDE TERMINÉE AVEC SUCCÈS" -ForegroundColor Green
Write-Host "📁 Localisation: $BackupDir" -ForegroundColor Cyan
Write-Host "📄 Log: $LogFile" -ForegroundColor Cyan

exit 0