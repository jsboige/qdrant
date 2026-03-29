# ============================================================================
# Script de Redémarrage Unifié Qdrant
# ============================================================================
# Date: 2025-10-13
# Auteur: Consolidation automatique
# 
# Remplace:
#   - safe_restart_production.ps1
#   - fix_network_and_restart.ps1
#
# UTILISATION:
#   .\qdrant_restart.ps1 -Environment production [-SkipSnapshot] [-Force] [-FixNetwork]
#   .\qdrant_restart.ps1 -Environment students [-SkipSnapshot] [-Force]
#
# EXEMPLES:
#   # Redémarrage sécurisé avec snapshot
#   .\qdrant_restart.ps1 -Environment production
#
#   # Redémarrage rapide sans snapshot
#   .\qdrant_restart.ps1 -Environment students -SkipSnapshot
#
#   # Redémarrage avec correction réseau Docker
#   .\qdrant_restart.ps1 -Environment production -FixNetwork
#
#   # Redémarrage forcé en urgence
#   .\qdrant_restart.ps1 -Environment production -Force
#
# FONCTIONNALITÉS:
#   ✅ Redémarrage sécurisé avec snapshot optionnel
#   ✅ Nettoyage des réseaux Docker (mode -FixNetwork)
#   ✅ Grace period configurable
#   ✅ Health checks post-redémarrage
#   ✅ Récupération automatique en cas d'échec
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("production", "students")]
    [string]$Environment,
    
    [switch]$SkipSnapshot = $false,
    [switch]$Force = $false,
    [switch]$FixNetwork = $false,
    [int]$GracePeriodSeconds = 60,
    [int]$HealthCheckRetries = 10,
    [int]$HealthCheckDelay = 5
)

# ============================================================================
# CONFIGURATION CENTRALISÉE
# ============================================================================

# Répertoire racine myia_qdrant (parent du dossier scripts)
$MyiaQdrantRoot = Split-Path -Parent $PSScriptRoot

$EnvironmentConfig = @{
    production = @{
        Port = 6333
        ServiceName = "qdrant"  # Nom du service dans docker-compose.yml
        ContainerName = "qdrant_production"  # container_name dans docker-compose.yml
        EnvFile = ".env.production"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ComposeFile = "docker-compose.production.yml"
    }
    students = @{
        Port = 6335
        ServiceName = "qdrant"  # Nom du service dans docker-compose.students.yml
        ContainerName = "qdrant_students"  # container_name dans docker-compose.students.yml
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ComposeFile = "docker-compose.students.yml"
    }
}

$config = $EnvironmentConfig[$Environment]
$ErrorActionPreference = "Stop"
$ContainerName = $config.ContainerName
$QdrantUrl = "http://localhost:$($config.Port)"

# Lecture de l'API key
$ApiKey = ""
$EnvFilePath = Join-Path $MyiaQdrantRoot $config.EnvFile
if (Test-Path $EnvFilePath) {
    $envContent = Get-Content $EnvFilePath
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

function Test-ContainerExists {
    $container = docker ps -a --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
    return $container -eq $ContainerName
}

function Test-ContainerRunning {
    $container = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
    return $container -eq $ContainerName
}

function Invoke-Snapshot {
    if ($SkipSnapshot) {
        Write-Info "Création de snapshot ignorée (-SkipSnapshot)"
        return $true
    }
    
    try {
        Write-Step "Création d'un snapshot de sécurité"
        
        $headers = @{
            "api-key" = $ApiKey
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-RestMethod -Uri "$QdrantUrl/snapshots" -Method Post -Headers $headers -TimeoutSec 120
        
        if ($response.result) {
            Write-Success "Snapshot créé: $($response.result.name)"
            return $true
        } else {
            Write-Warning "Réponse snapshot inattendue"
            return $false
        }
    } catch {
        Write-Warning "Erreur lors du snapshot: $($_.Exception.Message)"
        if ($Force) {
            Write-Warning "Continuation malgré l'échec (mode -Force)"
            return $true
        }
        return $false
    }
}

function Stop-Container {
    param([int]$GracePeriod = 60)
    
    try {
        Write-Step "Arrêt du container $ContainerName (grace period: ${GracePeriod}s)"
        
        if (-not (Test-ContainerExists)) {
            Write-Info "Container $ContainerName n'existe pas"
            return $true
        }
        
        if (-not (Test-ContainerRunning)) {
            Write-Info "Container $ContainerName déjà arrêté"
            return $true
        }
        
        docker stop $ContainerName --time $GracePeriod 2>&1 | Out-Null
        
        Start-Sleep -Seconds 5
        
        if (-not (Test-ContainerRunning)) {
            Write-Success "Container arrêté avec succès"
            return $true
        } else {
            Write-Warning "Container toujours actif, force kill..."
            docker kill $ContainerName 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            return $true
        }
    } catch {
        Write-Error "Erreur lors de l'arrêt: $($_.Exception.Message)"
        return $false
    }
}

function Repair-DockerNetwork {
    try {
        Write-Step "Nettoyage des réseaux Docker"
        
        # Arrêter tous les services
        Write-Info "Arrêt de tous les services Docker Compose..."
        $ComposeFilePath = Join-Path $MyiaQdrantRoot $config.ComposeFile
        docker-compose -f $ComposeFilePath down 2>&1 | Out-Null
        
        # Nettoyer les réseaux orphelins
        Write-Info "Suppression des réseaux orphelins..."
        docker network prune -f 2>&1 | Out-Null
        
        # Supprimer le réseau qdrant_default spécifiquement
        Write-Info "Suppression du réseau qdrant_default..."
        docker network rm qdrant_default 2>&1 | Out-Null
        
        Write-Success "Réseaux Docker nettoyés"
        return $true
        
    } catch {
        Write-Warning "Nettoyage réseau partiel: $($_.Exception.Message)"
        return $true  # Non bloquant
    }
}

function Start-Container {
    try {
        Write-Step "Démarrage du service $($config.ServiceName) (container: $ContainerName)"
        
        # IMPORTANT: Utiliser ServiceName (nom dans docker-compose.yml), pas ContainerName
        $ComposeFilePath = Join-Path $MyiaQdrantRoot $config.ComposeFile
        docker-compose -f $ComposeFilePath up -d $config.ServiceName 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Container démarré"
            return $true
        } else {
            Write-Error "Échec du démarrage"
            
            # Tentative de récupération
            Write-Warning "Tentative de récupération avec --force-recreate..."
            docker-compose -f $ComposeFilePath up -d --force-recreate $config.ServiceName 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Container démarré avec force-recreate"
                return $true
            }
            
            return $false
        }
    } catch {
        Write-Error "Erreur lors du démarrage: $($_.Exception.Message)"
        return $false
    }
}

function Wait-ForService {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelaySeconds = 5
    )
    
    Write-Step "Attente du démarrage du service (max $MaxAttempts tentatives)"
    
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $response = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
            
            if ($response.status -eq "ok") {
                Write-Success "Service prêt (tentative $i/$MaxAttempts)"
                return $true
            }
        } catch {
            Write-Info "Tentative $i/$MaxAttempts - En attente... (${DelaySeconds}s)"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    
    Write-Error "Service non disponible après $MaxAttempts tentatives"
    return $false
}

function Test-ServiceHealth {
    try {
        Write-Step "Vérification de la santé du service"
        
        # Health check
        $health = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 10
        if ($health.status -eq "ok") {
            Write-Success "Health check: OK"
        } else {
            Write-Warning "Health check: $($health.status)"
            return $false
        }
        
        # Version info
        $info = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get -TimeoutSec 10
        Write-Info "Version: $($info.version)"
        
        # Collections
        if ($ApiKey) {
            $headers = @{ "api-key" = $ApiKey }
            $collections = Invoke-RestMethod -Uri "$QdrantUrl/collections" -Method Get -Headers $headers -TimeoutSec 10
            $count = $collections.result.collections.Count
            Write-Success "Collections accessibles: $count"
        }
        
        return $true
        
    } catch {
        Write-Error "Erreur de validation: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================================
# SCRIPT PRINCIPAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     REDÉMARRAGE QDRANT - ENVIRONNEMENT: $($Environment.ToUpper().PadRight(17))║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$startTime = Get-Date

# Confirmation si pas en mode Force
if (-not $Force -and -not $FixNetwork) {
    Write-Host "❓ Confirmer le redémarrage de $ContainerName? [Y/n]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    if ($response -eq 'n' -or $response -eq 'N') {
        Write-Info "Redémarrage annulé"
        exit 0
    }
}

# Mode FixNetwork: Nettoyage réseau d'abord
if ($FixNetwork) {
    if (-not (Repair-DockerNetwork)) {
        Write-Error "Échec du nettoyage réseau"
        exit 1
    }
}

# Snapshot de sécurité (si container actif)
if (Test-ContainerRunning) {
    if (-not (Invoke-Snapshot)) {
        if (-not $Force) {
            Write-Error "Échec du snapshot, redémarrage annulé (utilisez -Force pour ignorer)"
            exit 1
        }
    }
}

# Arrêt du container
if (-not (Stop-Container -GracePeriod $GracePeriodSeconds)) {
    Write-Error "Impossible d'arrêter le container"
    exit 1
}

# Démarrage du container
if (-not (Start-Container)) {
    Write-Error "Impossible de démarrer le container"
    Write-Error "Vérifiez les logs: docker logs $ContainerName"
    exit 1
}

# Attente du service
if (-not (Wait-ForService -MaxAttempts $HealthCheckRetries -DelaySeconds $HealthCheckDelay)) {
    Write-Error "Service non disponible après le redémarrage"
    Write-Warning "Vérifiez les logs: docker logs $ContainerName"
    exit 1
}

# Validation finale
if (-not (Test-ServiceHealth)) {
    Write-Warning "Service démarré mais validation partielle"
    exit 1
}

# ============================================================================
# RAPPORT FINAL
# ============================================================================

$endTime = Get-Date
$duration = ($endTime - $startTime).TotalSeconds

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║         ✅ REDÉMARRAGE TERMINÉ AVEC SUCCÈS                  ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

Write-Success "Container: $ContainerName"
Write-Success "Durée totale: $([math]::Round($duration, 2)) secondes"
Write-Success "Service en bonne santé et opérationnel"

exit 0