# ============================================================================
# Script de Rollback Unifié Qdrant
# ============================================================================
# Date: 2025-10-13
# Auteur: Consolidation automatique
# 
# Remplace:
#   - rollback_migration.ps1
#   - students_rollback.ps1
#
# UTILISATION:
#   .\qdrant_rollback.ps1 -Environment production [-Force] [-SkipValidation]
#   .\qdrant_rollback.ps1 -Environment students [-Force] [-SkipValidation]
#
# EXEMPLES:
#   # Rollback interactif (demande confirmation)
#   .\qdrant_rollback.ps1 -Environment production
#
#   # Rollback automatique en urgence (DANGEREUX)
#   .\qdrant_rollback.ps1 -Environment students -Force
#
#   # Rollback sans validation post-restauration
#   .\qdrant_rollback.ps1 -Environment production -SkipValidation
#
# PRÉREQUIS:
#   Fichiers de backup créés par qdrant_backup.ps1 :
#   - config/<env>.yaml.pre-migration-*
#   - docker-compose.<env>.yml.pre-migration-*
#
# ATTENTION: Ce script arrêtera et redémarrera le service Qdrant!
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("production", "students")]
    [string]$Environment,
    
    [switch]$Force = $false,
    [switch]$SkipValidation = $false
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
        ConfigFile = "config/production.yaml"
        ComposeFile = "docker-compose.yml"
        BackupDir = "backups/production"
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ConfigFile = "config/students.yaml"
        ComposeFile = "docker-compose.students.yml"
        BackupDir = "backups/students"
    }
}

$config = $EnvironmentConfig[$Environment]
$ErrorActionPreference = "Stop"
$ContainerName = $config.ContainerName
$QdrantUrl = "http://localhost:$($config.Port)"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "$($config.BackupDir)/rollback_$Timestamp.log"

# Lecture de l'API key
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
    
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        "CRITICAL" { "Magenta" }
        default { "White" }
    }
    Write-Host $logMessage -ForegroundColor $color
    
    if ($LogFile -and (Test-Path (Split-Path $LogFile -Parent))) {
        $logMessage | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

function Test-BackupFileExists {
    param([string]$FilePath)
    
    if (Test-Path $FilePath) {
        Write-Log "✓ Fichier trouvé: $FilePath" "SUCCESS"
        return $true
    } else {
        Write-Log "✗ Fichier manquant: $FilePath" "ERROR"
        return $false
    }
}

function Get-LatestBackupFile {
    param([string]$Pattern)
    
    $files = Get-ChildItem -Path (Split-Path $Pattern) -Filter (Split-Path $Pattern -Leaf) -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1
    
    if ($files) {
        return $files.FullName
    }
    return $null
}

function Stop-QdrantContainer {
    try {
        Write-Log "Arrêt du container $ContainerName..." "INFO"
        
        $containerExists = docker ps -a --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
        
        if ($containerExists -eq $ContainerName) {
            docker stop $ContainerName --time 30 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            
            $stillRunning = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
            if ($stillRunning -ne $ContainerName) {
                Write-Log "✓ Container arrêté avec succès" "SUCCESS"
                return $true
            } else {
                Write-Log "⚠ Container toujours actif, force stop..." "WARNING"
                docker kill $ContainerName 2>&1 | Out-Null
                Start-Sleep -Seconds 3
                return $true
            }
        } else {
            Write-Log "ℹ Container $ContainerName n'existe pas ou est déjà arrêté" "INFO"
            return $true
        }
    } catch {
        Write-Log "Erreur lors de l'arrêt du container: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Restore-ConfigFile {
    param(
        [string]$BackupPath,
        [string]$TargetPath
    )
    
    try {
        if (-not (Test-Path $BackupPath)) {
            Write-Log "✗ Fichier de backup non trouvé: $BackupPath" "ERROR"
            return $false
        }
        
        # Sauvegarder le fichier actuel avant de restaurer
        if (Test-Path $TargetPath) {
            $currentBackup = "$TargetPath.before-rollback-$Timestamp"
            Copy-Item $TargetPath $currentBackup -Force
            Write-Log "Fichier actuel sauvegardé: $currentBackup" "INFO"
        }
        
        # Restaurer le backup
        Copy-Item $BackupPath $TargetPath -Force
        Write-Log "✓ Fichier restauré: $TargetPath" "SUCCESS"
        return $true
        
    } catch {
        Write-Log "Erreur lors de la restauration: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Start-QdrantContainer {
    try {
        Write-Log "Démarrage du container $ContainerName..." "INFO"
        
        docker-compose -f $config.ComposeFile up -d $ContainerName 2>&1 | Out-Null
        
        Write-Log "Attente du démarrage (30 secondes)..." "INFO"
        Start-Sleep -Seconds 30
        
        $containerRunning = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
        if ($containerRunning -eq $ContainerName) {
            Write-Log "✓ Container démarré avec succès" "SUCCESS"
            return $true
        } else {
            Write-Log "✗ Le container n'a pas démarré" "ERROR"
            return $false
        }
        
    } catch {
        Write-Log "Erreur lors du démarrage: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Test-ServiceHealth {
    $maxRetries = 10
    $retryDelay = 5
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $response = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
            
            if ($response.status -eq "ok") {
                Write-Log "✓ Service en bonne santé (tentative $i/$maxRetries)" "SUCCESS"
                
                if ($ApiKey) {
                    $headers = @{ "api-key" = $ApiKey }
                    $collections = Invoke-RestMethod -Uri "$QdrantUrl/collections" -Method Get -Headers $headers -TimeoutSec 10
                    $collCount = $collections.result.collections.Count
                    Write-Log "✓ Collections accessibles: $collCount" "SUCCESS"
                }
                
                return $true
            }
        } catch {
            Write-Log "⚠ Tentative $i/$maxRetries échouée, nouvelle tentative dans ${retryDelay}s..." "WARNING"
            Start-Sleep -Seconds $retryDelay
        }
    }
    
    Write-Log "✗ Le service n'a pas pu être validé après $maxRetries tentatives" "ERROR"
    return $false
}

# ============================================================================
# SCRIPT PRINCIPAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║    🚨 ROLLBACK QDRANT - ENVIRONNEMENT: $($Environment.ToUpper().PadRight(17))║" -ForegroundColor Magenta
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Magenta

Write-Log "⚠ ATTENTION: Rollback en cours pour $Environment" "CRITICAL"
Write-Log "Container cible: $ContainerName" "INFO"

# Créer le répertoire de logs si nécessaire
if (-not (Test-Path $config.BackupDir)) {
    New-Item -ItemType Directory -Path $config.BackupDir -Force | Out-Null
}

# Confirmation si pas en mode Force
if (-not $Force) {
    Write-Host "`n❓ Êtes-vous sûr de vouloir effectuer un rollback?" -ForegroundColor Yellow
    Write-Host "   Cela va restaurer les fichiers de configuration pré-migration." -ForegroundColor Yellow
    Write-Host "   Continuer? [y/N]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Log "Rollback annulé par l'utilisateur" "INFO"
        exit 0
    }
}

# Étape 1: Vérifier l'existence des fichiers de backup
Write-Host "`n▶ Vérification des fichiers de backup..." -ForegroundColor Cyan

$configBackup = Get-LatestBackupFile "$($config.ConfigFile).pre-migration-*"
$composeBackup = Get-LatestBackupFile "$($config.ComposeFile).pre-migration-*"

$hasConfigBackup = $configBackup -and (Test-BackupFileExists $configBackup)
$hasComposeBackup = $composeBackup -and (Test-BackupFileExists $composeBackup)

if (-not $hasConfigBackup) {
    Write-Log "✗ Aucun backup de configuration trouvé" "ERROR"
    Write-Log "Recherché: $($config.ConfigFile).pre-migration-*" "ERROR"
    exit 1
}

# Étape 2: Arrêter le container
Write-Host "`n▶ Arrêt du service..." -ForegroundColor Cyan
if (-not (Stop-QdrantContainer)) {
    Write-Log "❌ Impossible d'arrêter le container, rollback annulé" "ERROR"
    exit 1
}

# Étape 3: Restaurer les fichiers de configuration
Write-Host "`n▶ Restauration des fichiers de configuration..." -ForegroundColor Cyan

$configRestored = Restore-ConfigFile -BackupPath $configBackup -TargetPath $config.ConfigFile

if ($hasComposeBackup) {
    $composeRestored = Restore-ConfigFile -BackupPath $composeBackup -TargetPath $config.ComposeFile
} else {
    Write-Log "⚠ Pas de backup docker-compose, fichier non modifié" "WARNING"
    $composeRestored = $true
}

if (-not $configRestored) {
    Write-Log "❌ Échec de la restauration de la configuration" "ERROR"
    Write-Log "⚠ Le service est arrêté mais la configuration n'a pas été restaurée" "CRITICAL"
    exit 1
}

# Étape 4: Redémarrer le container
Write-Host "`n▶ Redémarrage du service..." -ForegroundColor Cyan
if (-not (Start-QdrantContainer)) {
    Write-Log "❌ Impossible de redémarrer le container" "ERROR"
    Write-Log "⚠ Configuration restaurée mais service non démarré" "CRITICAL"
    Write-Log "⚠ Démarrage manuel requis: docker-compose -f $($config.ComposeFile) up -d" "CRITICAL"
    exit 1
}

# Étape 5: Validation (si demandée)
if (-not $SkipValidation) {
    Write-Host "`n▶ Validation post-rollback..." -ForegroundColor Cyan
    if (-not (Test-ServiceHealth)) {
        Write-Log "⚠ Service démarré mais validation échouée" "WARNING"
        Write-Log "⚠ Vérification manuelle recommandée" "WARNING"
    }
} else {
    Write-Log "Validation ignorée (-SkipValidation)" "INFO"
}

# ============================================================================
# RAPPORT FINAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║            ✅ ROLLBACK TERMINÉ AVEC SUCCÈS                  ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

$report = @{
    Timestamp = $Timestamp
    Environment = $Environment
    ConfigRestored = $configRestored
    ComposeRestored = $composeRestored
    ServiceRestarted = $true
    BackupFiles = @{
        Config = $configBackup
        Compose = $composeBackup
    }
}

$reportPath = "$($config.BackupDir)/rollback_report_$Timestamp.json"
$report | ConvertTo-Json -Depth 3 | Out-File $reportPath

Write-Log "Fichiers restaurés:" "INFO"
Write-Log "  - Configuration: $configBackup" "SUCCESS"
if ($hasComposeBackup) {
    Write-Log "  - Docker Compose: $composeBackup" "SUCCESS"
}
Write-Log "Rapport sauvegardé: $reportPath" "INFO"
Write-Log "Log: $LogFile" "INFO"

exit 0