# ============================================================================
# Script de Migration Unifiée Qdrant
# ============================================================================
# Date: 2025-10-13
# Auteur: Consolidation automatique
# 
# Remplace:
#   - execute_migration.ps1
#   - students_migration.ps1
#
# UTILISATION:
#   .\qdrant_migrate.ps1 -Environment production [-DryRun] [-AutoConfirm] [-SkipBackup]
#   .\qdrant_migrate.ps1 -Environment students [-DryRun] [-AutoConfirm] [-SkipBackup]
#
# EXEMPLES:
#   # Migration en mode interactif (demande confirmation à chaque étape)
#   .\qdrant_migrate.ps1 -Environment production
#
#   # Migration en mode test (simulation sans modification)
#   .\qdrant_migrate.ps1 -Environment students -DryRun
#
#   # Migration automatique sans confirmation (DANGEREUX - pour CI/CD uniquement)
#   .\qdrant_migrate.ps1 -Environment production -AutoConfirm
#
# FONCTIONNALITÉS:
#   ✅ Vérification complète des prérequis
#   ✅ Sauvegarde automatique avant migration
#   ✅ Arrêt gracieux du service
#   ✅ Copie des nouveaux fichiers de configuration
#   ✅ Redémarrage avec validation
#   ✅ Monitoring post-migration
#   ✅ Rapport détaillé de migration
#   ✅ Mode DRY-RUN pour tests
#   ✅ Confirmations interactives entre chaque étape
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("production", "students")]
    [string]$Environment,
    
    [switch]$DryRun = $false,
    [switch]$AutoConfirm = $false,
    [switch]$UseOptimizedCompose = $true,
    [string]$LogDir = "logs",
    [switch]$SkipBackup = $false
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
        OptimizedConfigFile = "config/production.optimized.yaml"
        ComposeFile = "docker-compose.yml"
        OptimizedComposeFile = "docker-compose.production.optimized.yml"
        BackupDir = "backups/production"
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ConfigFile = "config/students.yaml"
        OptimizedConfigFile = "config/students.optimized.yaml"
        ComposeFile = "docker-compose.students.yml"
        OptimizedComposeFile = "docker-compose.students.optimized.yml"
        BackupDir = "backups/students"
    }
}

$config = $EnvironmentConfig[$Environment]
$ErrorActionPreference = "Stop"
$QdrantUrl = "http://localhost:$($config.Port)"
$ContainerName = $config.ContainerName
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "$LogDir/migration_${Environment}_$Timestamp.log"

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

# Statistiques de migration
$MigrationStats = @{
    StartTime = Get-Date
    Steps = @()
    Errors = @()
    Warnings = @()
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
        "INFO" { "White" }
        "STEP" { "Cyan" }
        default { "White" }
    }
    Write-Host $logMessage -ForegroundColor $color
    
    if ($LogFile -and (Test-Path (Split-Path $LogFile -Parent))) {
        $logMessage | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

function Write-StepHeader {
    param([string]$Title)
    
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  $($Title.PadRight(58)) ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
    Write-Log "ÉTAPE: $Title" "STEP"
}

function Confirm-Step {
    param(
        [string]$Message,
        [string]$DefaultChoice = "Y"
    )
    
    if ($AutoConfirm) {
        Write-Log "Auto-confirmé: $Message" "INFO"
        return $true
    }
    
    if ($DryRun) {
        Write-Log "[DRY-RUN] Simulation: $Message" "INFO"
        return $false
    }
    
    Write-Host "`n❓ $Message" -ForegroundColor Yellow
    Write-Host "   Continuer? [Y/n]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    
    if ([string]::IsNullOrWhiteSpace($response)) {
        $response = $DefaultChoice
    }
    
    return ($response -eq 'Y' -or $response -eq 'y')
}

function Test-Prerequisites {
    Write-StepHeader "Vérification des prérequis"
    
    $allOk = $true
    
    # Docker
    try {
        docker --version | Out-Null
        Write-Log "✓ Docker disponible" "SUCCESS"
    } catch {
        Write-Log "✗ Docker non disponible" "ERROR"
        $allOk = $false
    }
    
    # Fichiers de configuration optimisée
    if (Test-Path $config.OptimizedConfigFile) {
        Write-Log "✓ Configuration optimisée trouvée: $($config.OptimizedConfigFile)" "SUCCESS"
    } else {
        Write-Log "✗ Configuration optimisée manquante: $($config.OptimizedConfigFile)" "ERROR"
        $allOk = $false
    }
    
    if ($UseOptimizedCompose) {
        if (Test-Path $config.OptimizedComposeFile) {
            Write-Log "✓ Docker Compose optimisé trouvé: $($config.OptimizedComposeFile)" "SUCCESS"
        } else {
            Write-Log "✗ Docker Compose optimisé manquant: $($config.OptimizedComposeFile)" "ERROR"
            $allOk = $false
        }
    }
    
    # Container en cours d'exécution
    $containerRunning = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
    if ($containerRunning -eq $ContainerName) {
        Write-Log "✓ Container $ContainerName en cours d'exécution" "SUCCESS"
    } else {
        Write-Log "⚠ Container $ContainerName non actif (sera démarré)" "WARNING"
    }
    
    return $allOk
}

function Invoke-Backup {
    Write-StepHeader "Sauvegarde pré-migration"
    
    if ($SkipBackup) {
        Write-Log "Sauvegarde ignorée (-SkipBackup)" "WARNING"
        return $true
    }
    
    if ($DryRun) {
        Write-Log "[DRY-RUN] Backup serait exécuté ici" "INFO"
        return $true
    }
    
    try {
        $backupScript = Join-Path (Split-Path $PSScriptRoot) "qdrant_backup.ps1"
        if (Test-Path $backupScript) {
            Write-Log "Exécution du script de backup unifié..." "INFO"
            & $backupScript -Environment $Environment
            Write-Log "✓ Backup terminé avec succès" "SUCCESS"
            return $true
        } else {
            Write-Log "⚠ Script de backup non trouvé, backup manuel recommandé" "WARNING"
            return (Confirm-Step "Continuer sans backup?")
        }
    } catch {
        Write-Log "Erreur lors du backup: $($_.Exception.Message)" "ERROR"
        return (Confirm-Step "Continuer malgré l'échec du backup? (RISQUÉ)")
    }
}

function Stop-QdrantService {
    Write-StepHeader "Arrêt du service Qdrant"
    
    if ($DryRun) {
        Write-Log "[DRY-RUN] Service serait arrêté ici" "INFO"
        return $true
    }
    
    try {
        $composeFile = if ($UseOptimizedCompose) { $config.OptimizedComposeFile } else { $config.ComposeFile }
        
        Write-Log "Arrêt gracieux du container $ContainerName..." "INFO"
        docker-compose -f $composeFile stop $ContainerName --time 30 2>&1 | Out-Null
        
        Start-Sleep -Seconds 5
        
        # Vérifier que le container est bien arrêté
        $containerRunning = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
        if ($containerRunning -ne $ContainerName) {
            Write-Log "✓ Service arrêté avec succès" "SUCCESS"
            return $true
        } else {
            Write-Log "⚠ Le container est toujours actif, tentative de force stop..." "WARNING"
            docker stop $ContainerName --time 10 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            return $true
        }
    } catch {
        Write-Log "Erreur lors de l'arrêt du service: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Update-ConfigFiles {
    Write-StepHeader "Mise à jour des fichiers de configuration"
    
    if ($DryRun) {
        Write-Log "[DRY-RUN] Configuration serait mise à jour ici" "INFO"
        return $true
    }
    
    try {
        # Sauvegarder l'ancienne configuration
        if (Test-Path $config.ConfigFile) {
            $backupPath = "$($config.ConfigFile).pre-migration-$Timestamp"
            Copy-Item $config.ConfigFile $backupPath -Force
            Write-Log "✓ Ancienne configuration sauvegardée: $backupPath" "SUCCESS"
        }
        
        # Copier la nouvelle configuration
        Copy-Item $config.OptimizedConfigFile $config.ConfigFile -Force
        Write-Log "✓ Nouvelle configuration appliquée" "SUCCESS"
        
        # Mettre à jour docker-compose si demandé
        if ($UseOptimizedCompose -and (Test-Path $config.OptimizedComposeFile)) {
            if (Test-Path $config.ComposeFile) {
                $backupPath = "$($config.ComposeFile).pre-migration-$Timestamp"
                Copy-Item $config.ComposeFile $backupPath -Force
                Write-Log "✓ Ancien docker-compose sauvegardé: $backupPath" "SUCCESS"
            }
            Copy-Item $config.OptimizedComposeFile $config.ComposeFile -Force
            Write-Log "✓ Nouveau docker-compose appliqué" "SUCCESS"
        }
        
        return $true
    } catch {
        Write-Log "Erreur lors de la mise à jour: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Start-QdrantService {
    Write-StepHeader "Redémarrage du service Qdrant"
    
    if ($DryRun) {
        Write-Log "[DRY-RUN] Service serait redémarré ici" "INFO"
        return $true
    }
    
    try {
        $composeFile = if ($UseOptimizedCompose) { $config.ComposeFile } else { $config.ComposeFile }
        
        Write-Log "Démarrage du service..." "INFO"
        docker-compose -f $composeFile up -d $ContainerName 2>&1 | Out-Null
        
        Write-Log "Attente du démarrage (30 secondes)..." "INFO"
        Start-Sleep -Seconds 30
        
        # Vérifier que le service est actif
        $containerRunning = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
        if ($containerRunning -eq $ContainerName) {
            Write-Log "✓ Service démarré avec succès" "SUCCESS"
            return $true
        } else {
            Write-Log "✗ Le service n'a pas démarré correctement" "ERROR"
            return $false
        }
    } catch {
        Write-Log "Erreur lors du démarrage: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Test-ServiceHealth {
    Write-StepHeader "Validation post-migration"
    
    if ($DryRun) {
        Write-Log "[DRY-RUN] Validation serait effectuée ici" "INFO"
        return $true
    }
    
    $maxRetries = 10
    $retryDelay = 5
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $response = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
            
            if ($response.status -eq "ok") {
                Write-Log "✓ Service en bonne santé (tentative $i/$maxRetries)" "SUCCESS"
                
                # Vérifier les collections
                $headers = @{ "api-key" = $ApiKey }
                $collections = Invoke-RestMethod -Uri "$QdrantUrl/collections" -Method Get -Headers $headers -TimeoutSec 10
                $collCount = $collections.result.collections.Count
                Write-Log "✓ Collections accessibles: $collCount" "SUCCESS"
                
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

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       MIGRATION QDRANT - ENVIRONNEMENT: $($Environment.ToUpper().PadRight(17))║" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "║                    🧪 MODE TEST (DRY-RUN)                   ║" -ForegroundColor Yellow
}
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$MigrationStats.StartTime = Get-Date

# Créer le répertoire de logs
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Étape 1: Vérification des prérequis
if (-not (Test-Prerequisites)) {
    Write-Log "❌ Prérequis non satisfaits, migration annulée" "ERROR"
    exit 1
}
$MigrationStats.Steps += "Prerequisites: OK"

if (-not (Confirm-Step "Démarrer la migration vers la configuration optimisée?")) {
    Write-Log "Migration annulée par l'utilisateur" "INFO"
    exit 0
}

# Étape 2: Backup
if (-not (Invoke-Backup)) {
    Write-Log "❌ Backup échoué ou annulé, migration annulée" "ERROR"
    exit 1
}
$MigrationStats.Steps += "Backup: OK"

# Étape 3: Arrêt du service
if (-not (Stop-QdrantService)) {
    Write-Log "❌ Impossible d'arrêter le service, migration annulée" "ERROR"
    exit 1
}
$MigrationStats.Steps += "Stop Service: OK"

# Étape 4: Mise à jour de la configuration
if (-not (Update-ConfigFiles)) {
    Write-Log "❌ Mise à jour de la configuration échouée" "ERROR"
    Write-Log "⚠ Tentative de rollback recommandée" "WARNING"
    exit 1
}
$MigrationStats.Steps += "Update Config: OK"

# Étape 5: Redémarrage
if (-not (Start-QdrantService)) {
    Write-Log "❌ Impossible de redémarrer le service" "ERROR"
    Write-Log "⚠ ROLLBACK URGENT RECOMMANDÉ" "ERROR"
    exit 1
}
$MigrationStats.Steps += "Start Service: OK"

# Étape 6: Validation
if (-not (Test-ServiceHealth)) {
    Write-Log "❌ Validation post-migration échouée" "ERROR"
    Write-Log "⚠ Service démarré mais état incertain, vérification manuelle recommandée" "WARNING"
    exit 1
}
$MigrationStats.Steps += "Health Check: OK"

# ============================================================================
# RAPPORT FINAL
# ============================================================================

$MigrationStats.EndTime = Get-Date
$MigrationStats.Duration = ($MigrationStats.EndTime - $MigrationStats.StartTime).TotalSeconds

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              ✅ MIGRATION TERMINÉE AVEC SUCCÈS              ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

Write-Log "Durée totale: $($MigrationStats.Duration) secondes" "SUCCESS"
Write-Log "Étapes réussies: $($MigrationStats.Steps.Count)" "SUCCESS"

# Sauvegarder le rapport
$reportPath = "$LogDir/migration_report_${Environment}_$Timestamp.json"
$MigrationStats | ConvertTo-Json -Depth 3 | Out-File $reportPath
Write-Log "Rapport sauvegardé: $reportPath" "INFO"

exit 0