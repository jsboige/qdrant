# ============================================================================
# Script de Monitoring Unifié Qdrant
# ============================================================================
# Date: 2025-10-13
# Auteur: Consolidation automatique
# 
# Remplace:
#   - monitor_qdrant_health_enhanced.ps1
#   - students_monitor.ps1
#
# UTILISATION:
#   .\qdrant_monitor.ps1 -Environment production [-Continuous] [-RefreshInterval <seconds>]
#   .\qdrant_monitor.ps1 -Environment students [-OutputFile <path>] [-ExportJson]
#
# EXEMPLES:
#   # Monitoring unique (production)
#   .\qdrant_monitor.ps1 -Environment production
#
#   # Monitoring continu avec refresh toutes les 30 secondes
#   .\qdrant_monitor.ps1 -Environment students -Continuous -RefreshInterval 30
#
#   # Export vers fichier texte
#   .\qdrant_monitor.ps1 -Environment production -OutputFile monitor.log
#
#   # Export JSON pour automatisation
#   .\qdrant_monitor.ps1 -Environment production -ExportJson
#
# FONCTIONNALITÉS:
#   ✅ Health check du service
#   ✅ Statistiques du container Docker
#   ✅ État des collections
#   ✅ Espace disque
#   ✅ Métriques de performance
#   ✅ Mode continu avec refresh configurable
#   ✅ Export JSON pour monitoring automatisé
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("production", "students")]
    [string]$Environment,
    
    [switch]$Continuous = $false,
    [int]$RefreshInterval = 30,
    [string]$OutputFile = "",
    [switch]$ExportJson = $false
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
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
    }
}

$config = $EnvironmentConfig[$Environment]
$ErrorActionPreference = "Continue"
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

if (-not $ApiKey) {
    Write-Host "AVERTISSEMENT: Impossible de lire l'API key depuis $($config.EnvFile)" -ForegroundColor Yellow
    Write-Host "Certaines fonctionnalités seront limitées." -ForegroundColor Yellow
}

# ============================================================================
# FONCTIONS D'AFFICHAGE
# ============================================================================

function Write-Header {
    param([string]$Text)
    Write-Host "`n╔$('═' * ($Text.Length + 2))╗" -ForegroundColor Cyan
    Write-Host "║ $Text ║" -ForegroundColor Cyan
    Write-Host "╚$('═' * ($Text.Length + 2))╝" -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host "`n▶ $Title" -ForegroundColor Yellow -BackgroundColor DarkBlue
}

function Write-Metric {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Status = "info"
    )
    
    $color = switch ($Status) {
        "ok" { "Green" }
        "warning" { "Yellow" }
        "error" { "Red" }
        default { "White" }
    }
    
    $labelPadded = $Label.PadRight(35, '.')
    Write-Host "  $labelPadded " -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor $color
}

# ============================================================================
# FONCTIONS DE MONITORING
# ============================================================================

function Test-ContainerRunning {
    try {
        $container = docker ps --filter "name=^/${ContainerName}$" --format "{{.Names}}" 2>$null
        return $container -eq $ContainerName
    } catch {
        return $false
    }
}

function Get-HealthStatus {
    try {
        $response = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
        return @{
            Status = $response.status
            Success = ($response.status -eq "ok")
        }
    } catch {
        return @{
            Status = "unreachable"
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-ContainerStats {
    try {
        $statsJson = docker stats $ContainerName --no-stream --format "{{json .}}" 2>$null
        
        if ($statsJson) {
            $stats = $statsJson | ConvertFrom-Json
            return @{
                CPUPerc = $stats.CPUPerc
                MemUsage = $stats.MemUsage
                MemPerc = $stats.MemPerc
                NetIO = $stats.NetIO
                BlockIO = $stats.BlockIO
            }
        }
        return $null
    } catch {
        return $null
    }
}

function Get-CollectionsInfo {
    try {
        $headers = @{ "api-key" = $ApiKey }
        $response = Invoke-RestMethod -Uri "$QdrantUrl/collections" -Method Get -Headers $headers -TimeoutSec 10
        
        if ($response.result) {
            $collections = $response.result.collections
            return @{
                Count = $collections.Count
                Collections = $collections
                Success = $true
            }
        }
        return @{ Count = 0; Success = $false }
    } catch {
        return @{ Count = 0; Success = $false; Error = $_.Exception.Message }
    }
}

function Get-SystemInfo {
    try {
        $response = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get -TimeoutSec 10
        return @{
            Version = $response.version
            Commit = $response.commit
            Success = $true
        }
    } catch {
        return @{ Success = $false }
    }
}

function Get-DiskUsage {
    try {
        # Récupérer les volumes du container
        $volumeInfo = docker inspect $ContainerName 2>$null | ConvertFrom-Json
        
        if ($volumeInfo -and $volumeInfo.Mounts) {
            $storageMount = $volumeInfo.Mounts | Where-Object { $_.Destination -like "*/storage" } | Select-Object -First 1
            
            if ($storageMount -and $storageMount.Source) {
                # Essayer d'obtenir la taille du volume
                $volumeName = $storageMount.Name
                if ($volumeName) {
                    return @{
                        VolumeName = $volumeName
                        MountPoint = $storageMount.Source
                        Success = $true
                    }
                }
            }
        }
        
        return @{ Success = $false }
    } catch {
        return @{ Success = $false }
    }
}

function Get-ErrorCount {
    try {
        $logs = docker logs $ContainerName --tail 100 2>&1
        $errors = ($logs | Select-String -Pattern "ERROR|error" -AllMatches).Count
        $warnings = ($logs | Select-String -Pattern "WARN|warning" -AllMatches).Count
        
        return @{
            Errors = $errors
            Warnings = $warnings
            Success = $true
        }
    } catch {
        return @{ Errors = 0; Warnings = 0; Success = $false }
    }
}

# ============================================================================
# FONCTION DE MONITORING PRINCIPALE
# ============================================================================

function Invoke-Monitoring {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Header
    Write-Header "MONITORING QDRANT - $($Environment.ToUpper()) - $timestamp"
    
    # 1. État du container
    Write-Section "État du Container"
    $containerRunning = Test-ContainerRunning
    if ($containerRunning) {
        Write-Metric "Container $ContainerName" "EN COURS D'EXÉCUTION ✓" "ok"
    } else {
        Write-Metric "Container $ContainerName" "ARRÊTÉ ✗" "error"
        return @{ Success = $false; Error = "Container not running" }
    }
    
    # 2. Health Check
    Write-Section "Health Check API"
    $health = Get-HealthStatus
    if ($health.Success) {
        Write-Metric "Status API" "$($health.Status.ToUpper()) ✓" "ok"
    } else {
        Write-Metric "Status API" "UNREACHABLE ✗" "error"
        if ($health.Error) {
            Write-Metric "Erreur" $health.Error "error"
        }
    }
    
    # 3. Informations Système
    Write-Section "Informations Système"
    $sysInfo = Get-SystemInfo
    if ($sysInfo.Success) {
        Write-Metric "Version Qdrant" $sysInfo.Version "info"
        Write-Metric "Commit" $sysInfo.Commit "info"
    } else {
        Write-Metric "Informations système" "NON DISPONIBLES" "warning"
    }
    
    # 4. Statistiques Container
    Write-Section "Ressources Container"
    $stats = Get-ContainerStats
    if ($stats) {
        Write-Metric "CPU" $stats.CPUPerc "info"
        Write-Metric "Mémoire" $stats.MemUsage "info"
        Write-Metric "Mémoire %" $stats.MemPerc "info"
        Write-Metric "Réseau I/O" $stats.NetIO "info"
        Write-Metric "Disque I/O" $stats.BlockIO "info"
    } else {
        Write-Metric "Statistiques" "NON DISPONIBLES" "warning"
    }
    
    # 5. Collections
    Write-Section "Collections"
    $collections = Get-CollectionsInfo
    if ($collections.Success) {
        Write-Metric "Nombre de collections" $collections.Count "ok"
        
        if ($collections.Collections -and $collections.Count -le 10) {
            foreach ($coll in $collections.Collections) {
                Write-Metric "  └─ $($coll.name)" "points: $($coll.points_count)" "info"
            }
        } elseif ($collections.Count -gt 10) {
            Write-Host "  (Trop de collections pour afficher, utilisez l'API pour la liste complète)" -ForegroundColor Gray
        }
    } else {
        Write-Metric "Collections" "NON DISPONIBLES" "warning"
    }
    
    # 6. Espace Disque
    Write-Section "Stockage"
    $disk = Get-DiskUsage
    if ($disk.Success) {
        Write-Metric "Volume Docker" $disk.VolumeName "info"
        Write-Metric "Point de montage" $disk.MountPoint "info"
    } else {
        Write-Metric "Informations stockage" "NON DISPONIBLES" "warning"
    }
    
    # 7. Erreurs dans les logs
    Write-Section "Logs (100 dernières lignes)"
    $errorInfo = Get-ErrorCount
    if ($errorInfo.Success) {
        $errorStatus = if ($errorInfo.Errors -eq 0) { "ok" } elseif ($errorInfo.Errors -lt 5) { "warning" } else { "error" }
        Write-Metric "Erreurs détectées" $errorInfo.Errors $errorStatus
        
        $warnStatus = if ($errorInfo.Warnings -eq 0) { "ok" } elseif ($errorInfo.Warnings -lt 10) { "warning" } else { "error" }
        Write-Metric "Avertissements" $errorInfo.Warnings $warnStatus
    }
    
    # Résumé
    $monitoringResult = @{
        Timestamp = $timestamp
        Environment = $Environment
        ContainerRunning = $containerRunning
        HealthOk = $health.Success
        CollectionCount = $collections.Count
        Errors = $errorInfo.Errors
        Warnings = $errorInfo.Warnings
    }
    
    return $monitoringResult
}

# ============================================================================
# SCRIPT PRINCIPAL
# ============================================================================

do {
    $result = Invoke-Monitoring
    
    # Export JSON si demandé
    if ($ExportJson) {
        $jsonOutput = $result | ConvertTo-Json -Depth 3
        if ($OutputFile) {
            $jsonOutput | Out-File $OutputFile -Encoding UTF8
            Write-Host "`n📄 JSON exporté vers: $OutputFile" -ForegroundColor Cyan
        } else {
            Write-Host "`n📄 JSON:" -ForegroundColor Cyan
            Write-Host $jsonOutput
        }
    }
    
    # Export texte si demandé
    if ($OutputFile -and -not $ExportJson) {
        $result | Out-File $OutputFile -Append -Encoding UTF8
    }
    
    # Mode continu
    if ($Continuous) {
        Write-Host "`n⏳ Prochaine actualisation dans $RefreshInterval secondes... (Ctrl+C pour arrêter)" -ForegroundColor Yellow
        Start-Sleep -Seconds $RefreshInterval
        Clear-Host
    }
    
} while ($Continuous)

Write-Host "`n✅ Monitoring terminé" -ForegroundColor Green

exit 0