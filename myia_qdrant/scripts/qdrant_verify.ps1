# ============================================================================
# Script de Vérification Unifiée Qdrant
# ============================================================================
# Date: 2025-10-13
# Auteur: Consolidation automatique
# 
# Remplace:
#   - verify_qdrant_config.ps1
#
# UTILISATION:
#   .\qdrant_verify.ps1 -Environment production [-Detailed]
#   .\qdrant_verify.ps1 -Environment students [-Detailed]
#   .\qdrant_verify.ps1 -Environment all [-Detailed]
#
# EXEMPLES:
#   # Vérification rapide de production
#   .\qdrant_verify.ps1 -Environment production
#
#   # Vérification détaillée de students
#   .\qdrant_verify.ps1 -Environment students -Detailed
#
#   # Vérification de tous les environnements
#   .\qdrant_verify.ps1 -Environment all
#
# FONCTIONNALITÉS:
#   ✅ Vérification Docker disponible
#   ✅ Vérification des volumes
#   ✅ Vérification des fichiers de config
#   ✅ Test de connectivité API
#   ✅ Rapport détaillé (mode -Detailed)
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("production", "students", "all")]
    [string]$Environment,
    
    [switch]$Detailed = $false
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
        Volumes = @("qdrant_qdrant-storage", "qdrant_qdrant-snapshots")
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ConfigFile = "config/students.yaml"
        ComposeFile = "docker-compose.students.yml"
        Volumes = @("qdrant_qdrant-students-storage", "qdrant_qdrant-students-snapshots")
    }
}

$ErrorActionPreference = "Continue"

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

function Write-Section {
    param([string]$Title)
    Write-Host "`n▶ $Title" -ForegroundColor Cyan
}

function Write-Check {
    param(
        [string]$Item,
        [bool]$Success,
        [string]$Details = ""
    )
    
    $status = if ($Success) { "✓" } else { "✗" }
    $color = if ($Success) { "Green" } else { "Red" }
    
    Write-Host "   $status $Item" -ForegroundColor $color
    if ($Details) {
        Write-Host "     $Details" -ForegroundColor Gray
    }
}

function Test-DockerAvailable {
    try {
        docker --version | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-ContainerRunning {
    param([string]$ContainerName)
    
    try {
        $container = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
        return $container -eq $ContainerName
    } catch {
        return $false
    }
}

function Test-VolumeExists {
    param([string]$VolumeName)
    
    try {
        $volume = docker volume ls --filter "name=^${VolumeName}$" --format "{{.Name}}" 2>$null
        return $volume -eq $VolumeName
    } catch {
        return $false
    }
}

function Get-VolumeDetails {
    param([string]$VolumeName)
    
    try {
        $details = docker volume inspect $VolumeName 2>$null | ConvertFrom-Json
        return @{
            Mountpoint = $details.Mountpoint
            Driver = $details.Driver
            CreatedAt = $details.CreatedAt
            Success = $true
        }
    } catch {
        return @{ Success = $false }
    }
}

function Test-ApiConnectivity {
    param(
        [string]$Url,
        [string]$ApiKey
    )
    
    try {
        $response = Invoke-RestMethod -Uri "$Url/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
        return @{
            Success = $true
            Status = $response.status
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-QdrantInfo {
    param(
        [string]$Url,
        [string]$ApiKey
    )
    
    try {
        $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 10
        return @{
            Version = $response.version
            Commit = $response.commit
            Success = $true
        }
    } catch {
        return @{ Success = $false }
    }
}

function Get-CollectionsCount {
    param(
        [string]$Url,
        [string]$ApiKey
    )
    
    try {
        $headers = @{ "api-key" = $ApiKey }
        $response = Invoke-RestMethod -Uri "$Url/collections" -Method Get -Headers $headers -TimeoutSec 10
        return @{
            Count = $response.result.collections.Count
            Success = $true
        }
    } catch {
        return @{ Count = 0; Success = $false }
    }
}

# ============================================================================
# FONCTION DE VÉRIFICATION PAR ENVIRONNEMENT
# ============================================================================

function Test-Environment {
    param([hashtable]$Config, [string]$EnvName)
    
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║       VÉRIFICATION ENVIRONNEMENT: $($EnvName.ToUpper().PadRight(23))║" -ForegroundColor Yellow
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    
    $results = @{
        Environment = $EnvName
        Checks = @{}
    }
    
    # 1. Fichiers de configuration
    Write-Section "Fichiers de Configuration"
    
    $configExists = Test-Path $Config.ConfigFile
    Write-Check "Config YAML" $configExists $Config.ConfigFile
    $results.Checks.ConfigFile = $configExists
    
    $composeExists = Test-Path $Config.ComposeFile
    Write-Check "Docker Compose" $composeExists $Config.ComposeFile
    $results.Checks.ComposeFile = $composeExists
    
    $envExists = Test-Path $Config.EnvFile
    Write-Check "Fichier ENV" $envExists $Config.EnvFile
    $results.Checks.EnvFile = $envExists
    
    # Lire l'API key
    $ApiKey = ""
    if ($envExists) {
        $envContent = Get-Content $Config.EnvFile
        foreach ($line in $envContent) {
            if ($line -match "^$($Config.ApiKeyVar)=(.+)$") {
                $ApiKey = $matches[1]
                Write-Check "API Key" $true "Trouvée dans $($Config.EnvFile)"
                $results.Checks.ApiKey = $true
                break
            }
        }
    }
    
    # 2. Volumes Docker
    Write-Section "Volumes Docker"
    
    foreach ($volumeName in $Config.Volumes) {
        $volumeExists = Test-VolumeExists $volumeName
        Write-Check $volumeName $volumeExists
        
        if ($Detailed -and $volumeExists) {
            $details = Get-VolumeDetails $volumeName
            if ($details.Success) {
                Write-Host "       Driver: $($details.Driver)" -ForegroundColor Gray
                Write-Host "       Mountpoint: $($details.Mountpoint)" -ForegroundColor Gray
            }
        }
    }
    
    # 3. Container
    Write-Section "Container Docker"
    
    $containerRunning = Test-ContainerRunning $Config.ContainerName
    Write-Check "$($Config.ContainerName) actif" $containerRunning
    $results.Checks.ContainerRunning = $containerRunning
    
    if (-not $containerRunning) {
        # Vérifier si le container existe mais est arrêté
        $containerExists = docker ps -a --filter "name=^/$($Config.ContainerName)$" --format "{{.Names}}" 2>$null
        if ($containerExists -eq $Config.ContainerName) {
            Write-Host "     Container existe mais est arrêté" -ForegroundColor Yellow
        }
    }
    
    # 4. Connectivité API
    Write-Section "Connectivité API"
    
    $QdrantUrl = "http://localhost:$($Config.Port)"
    $apiTest = Test-ApiConnectivity -Url $QdrantUrl -ApiKey $ApiKey
    
    Write-Check "Health Check ($QdrantUrl)" $apiTest.Success $(if ($apiTest.Success) { "Status: $($apiTest.Status)" } else { "Erreur: $($apiTest.Error)" })
    $results.Checks.ApiConnectivity = $apiTest.Success
    
    if ($apiTest.Success) {
        # Informations système
        $sysInfo = Get-QdrantInfo -Url $QdrantUrl -ApiKey $ApiKey
        if ($sysInfo.Success) {
            Write-Check "Version Qdrant" $true $sysInfo.Version
            if ($Detailed) {
                Write-Host "       Commit: $($sysInfo.Commit)" -ForegroundColor Gray
            }
        }
        
        # Collections
        if ($ApiKey) {
            $collections = Get-CollectionsCount -Url $QdrantUrl -ApiKey $ApiKey
            if ($collections.Success) {
                Write-Check "Collections accessibles" $true "$($collections.Count) collections"
            }
        } else {
            Write-Host "     ⚠ Impossible de vérifier les collections (API key manquante)" -ForegroundColor Yellow
        }
    }
    
    # 5. Résumé
    Write-Section "Résumé"
    
    $totalChecks = $results.Checks.Values.Count
    $passedChecks = ($results.Checks.Values | Where-Object { $_ -eq $true }).Count
    $healthScore = if ($totalChecks -gt 0) { [math]::Round(($passedChecks / $totalChecks) * 100, 1) } else { 0 }
    
    $scoreColor = switch ($healthScore) {
        { $_ -ge 90 } { "Green" }
        { $_ -ge 70 } { "Yellow" }
        default { "Red" }
    }
    
    Write-Host "   Score de santé: " -NoNewline
    Write-Host "$healthScore%" -ForegroundColor $scoreColor
    Write-Host "   Vérifications réussies: $passedChecks / $totalChecks" -ForegroundColor Gray
    
    $results.HealthScore = $healthScore
    
    return $results
}

# ============================================================================
# SCRIPT PRINCIPAL
# ============================================================================

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║              DIAGNOSTIC CONFIGURATION QDRANT               ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# Vérification Docker
Write-Section "Infrastructure"
$dockerAvailable = Test-DockerAvailable
Write-Check "Docker disponible" $dockerAvailable

if (-not $dockerAvailable) {
    Write-Host "`n✗ Docker non disponible - Impossible de continuer" -ForegroundColor Red
    exit 1
}

$dockerVersion = docker --version
Write-Host "   $dockerVersion" -ForegroundColor Gray

# Vérifier les environnements demandés
$allResults = @()

if ($Environment -eq "all") {
    $allResults += Test-Environment -Config $EnvironmentConfig.production -EnvName "production"
    $allResults += Test-Environment -Config $EnvironmentConfig.students -EnvName "students"
} else {
    $allResults += Test-Environment -Config $EnvironmentConfig[$Environment] -EnvName $Environment
}

# Rapport global
if ($Environment -eq "all") {
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                     RAPPORT GLOBAL                         ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    foreach ($result in $allResults) {
        $scoreColor = switch ($result.HealthScore) {
            { $_ -ge 90 } { "Green" }
            { $_ -ge 70 } { "Yellow" }
            default { "Red" }
        }
        Write-Host "   $($result.Environment.PadRight(15)): " -NoNewline
        Write-Host "$($result.HealthScore)%" -ForegroundColor $scoreColor
    }
}

Write-Host "`n✅ Diagnostic terminé" -ForegroundColor Green

exit 0