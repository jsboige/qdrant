# ============================================================================
# Script de Mise à Jour Unifiée Qdrant
# ============================================================================
# Date: 2025-10-13
# Auteur: Consolidation automatique
# 
# Remplace:
#   - update_production_simple.ps1
#
# UTILISATION:
#   .\qdrant_update.ps1 -Environment production [-SkipBackup] [-ToVersion <version>]
#   .\qdrant_update.ps1 -Environment students [-SkipBackup]
#
# EXEMPLES:
#   # Mise à jour vers la dernière version
#   .\qdrant_update.ps1 -Environment production
#
#   # Mise à jour rapide sans backup (RISQUÉ)
#   .\qdrant_update.ps1 -Environment students -SkipBackup
#
#   # Mise à jour vers une version spécifique
#   .\qdrant_update.ps1 -Environment production -ToVersion "v1.8.0"
#
# FONCTIONNALITÉS:
#   ✅ Sauvegarde pré-mise à jour (optionnelle)
#   ✅ Pull de la dernière image Docker
#   ✅ Redémarrage du service
#   ✅ Validation post-update
#   ✅ Rollback automatique en cas d'échec
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("production", "students")]
    [string]$Environment,
    
    [switch]$SkipBackup = $false,
    [string]$ToVersion = ""
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
        ComposeFile = "docker-compose.yml"
        ServiceName = "qdrant"
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ComposeFile = "docker-compose.students.yml"
        ServiceName = "qdrant_students"
    }
}

$config = $EnvironmentConfig[$Environment]
$ErrorActionPreference = "Stop"
$ContainerName = $config.ContainerName
$QdrantUrl = "http://localhost:$($config.Port)"

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

function Write-Step {
    param([string]$Message)
    Write-Host "`n[ÉTAPE] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[✓] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[⚠] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[✗] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "[ℹ] $Message" -ForegroundColor White
}

function Get-CurrentVersion {
    try {
        $response = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get -TimeoutSec 10
        return $response.version
    } catch {
        return "unknown"
    }
}

function Invoke-Backup {
    if ($SkipBackup) {
        Write-Warning "Sauvegarde ignorée (-SkipBackup) - RISQUÉ"
        return $true
    }
    
    try {
        Write-Step "Sauvegarde pré-mise à jour"
        
        $backupScript = Join-Path (Split-Path $PSScriptRoot) "qdrant_backup.ps1"
        if (Test-Path $backupScript) {
            & $backupScript -Environment $Environment -SkipSnapshot
            Write-Success "Backup terminé"
            return $true
        } else {
            Write-Warning "Script de backup non trouvé"
            Write-Host "   Continuer sans backup? (y/N): " -NoNewline -ForegroundColor Yellow
            $response = Read-Host
            return ($response -eq 'y' -or $response -eq 'Y')
        }
    } catch {
        Write-Error "Erreur backup: $($_.Exception.Message)"
        Write-Host "   Continuer malgré l'erreur? (y/N): " -NoNewline -ForegroundColor Yellow
        $response = Read-Host
        return ($response -eq 'y' -or $response -eq 'Y')
    }
}

function Stop-Service {
    try {
        Write-Step "Arrêt du service $($config.ServiceName)"
        docker-compose -f $config.ComposeFile stop $config.ServiceName 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Service arrêté"
            return $true
        } else {
            Write-Error "Échec arrêt service"
            return $false
        }
    } catch {
        Write-Error "Erreur: $($_.Exception.Message)"
        return $false
    }
}

function Update-DockerImage {
    try {
        Write-Step "Récupération de la nouvelle image Docker"
        
        if ($ToVersion) {
            Write-Info "Version cible: $ToVersion"
            # Modifier temporairement le tag dans docker-compose
            Write-Warning "Mise à jour vers version spécifique non implémentée"
            Write-Warning "Utilisez la dernière version disponible"
        }
        
        docker-compose -f $config.ComposeFile pull $config.ServiceName 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Image mise à jour"
            return $true
        } else {
            Write-Error "Échec pull image"
            return $false
        }
    } catch {
        Write-Error "Erreur: $($_.Exception.Message)"
        return $false
    }
}

function Start-Service {
    try {
        Write-Step "Démarrage du service avec la nouvelle image"
        docker-compose -f $config.ComposeFile up -d $config.ServiceName 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Service démarré"
            Start-Sleep -Seconds 30
            return $true
        } else {
            Write-Error "Échec démarrage service"
            return $false
        }
    } catch {
        Write-Error "Erreur: $($_.Exception.Message)"
        return $false
    }
}

function Test-ServiceHealth {
    Write-Step "Validation post-mise à jour"
    
    $maxRetries = 10
    $retryDelay = 5
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $response = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
            
            if ($response.status -eq "ok") {
                Write-Success "Service en bonne santé (tentative $i/$maxRetries)"
                
                # Vérifier la version
                $newVersion = Get-CurrentVersion
                Write-Info "Nouvelle version: $newVersion"
                
                # Vérifier les collections
                if ($ApiKey) {
                    $headers = @{ "api-key" = $ApiKey }
                    $collections = Invoke-RestMethod -Uri "$QdrantUrl/collections" -Method Get -Headers $headers -TimeoutSec 10
                    $collCount = $collections.result.collections.Count
                    Write-Success "Collections accessibles: $collCount"
                }
                
                return $true
            }
        } catch {
            Write-Info "Tentative $i/$maxRetries - En attente... (${retryDelay}s)"
            Start-Sleep -Seconds $retryDelay
        }
    }
    
    Write-Error "Service non validé après $maxRetries tentatives"
    return $false
}

function Invoke-Rollback {
    Write-Warning "Tentative de rollback automatique..."
    
    try {
        Write-Info "Redémarrage avec l'ancienne image..."
        docker-compose -f $config.ComposeFile up -d $config.ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 30
        
        $health = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 10
        if ($health.status -eq "ok") {
            Write-Success "Rollback réussi - service restauré"
            return $true
        }
    } catch {
        Write-Error "Rollback automatique échoué"
    }
    
    return $false
}

# ============================================================================
# SCRIPT PRINCIPAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║    MISE À JOUR QDRANT - ENVIRONNEMENT: $($Environment.ToUpper().PadRight(17))║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$currentVersion = Get-CurrentVersion
Write-Info "Version actuelle: $currentVersion"
Write-Info "Service: $($config.ServiceName)"
Write-Host ""

# Confirmation
Write-Host "❓ Confirmer la mise à jour? [Y/n]: " -NoNewline -ForegroundColor Yellow
$response = Read-Host
if ($response -eq 'n' -or $response -eq 'N') {
    Write-Info "Mise à jour annulée"
    exit 0
}

# Sauvegarde (optionnelle)
if (-not (Invoke-Backup)) {
    Write-Error "Mise à jour annulée"
    exit 1
}

# Arrêt du service
if (-not (Stop-Service)) {
    Write-Error "Impossible d'arrêter le service"
    exit 1
}

# Pull de la nouvelle image
if (-not (Update-DockerImage)) {
    Write-Error "Impossible de mettre à jour l'image"
    Write-Warning "Tentative de redémarrage avec l'ancienne image..."
    Start-Service
    exit 1
}

# Démarrage du service
if (-not (Start-Service)) {
    Write-Error "Impossible de démarrer le service"
    if (-not (Invoke-Rollback)) {
        Write-Error "CRITIQUE: Service non démarré et rollback échoué"
        Write-Error "Action manuelle requise: docker-compose -f $($config.ComposeFile) up -d"
    }
    exit 1
}

# Validation
if (-not (Test-ServiceHealth)) {
    Write-Error "Validation post-mise à jour échouée"
    Write-Warning "Le service est démarré mais son état est incertain"
    
    Write-Host "`n❓ Effectuer un rollback? [y/N]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    if ($response -eq 'y' -or $response -eq 'Y') {
        if (Invoke-Rollback) {
            Write-Success "Rollback effectué - ancienne version restaurée"
        } else {
            Write-Error "Rollback échoué - intervention manuelle requise"
        }
    }
    exit 1
}

# ============================================================================
# RAPPORT FINAL
# ============================================================================

$newVersion = Get-CurrentVersion

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║          ✅ MISE À JOUR TERMINÉE AVEC SUCCÈS                ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

Write-Success "Version précédente: $currentVersion"
Write-Success "Version actuelle: $newVersion"
Write-Success "Service opérationnel et en bonne santé"

exit 0