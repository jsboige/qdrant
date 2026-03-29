# Script de Monitoring Unifié Qdrant
# Date: 2025-10-13
# Usage: Surveillance complète de la santé de Qdrant avec paramètres flexibles
#
# EXEMPLES:
#   .\monitor_qdrant.ps1                                              # Check unique (toutes collections)
#   .\monitor_qdrant.ps1 -Collection "roo_tasks_semantic_index"      # Collection spécifique
#   .\monitor_qdrant.ps1 -Watch -IntervalSeconds 30                  # Monitoring continu
#   .\monitor_qdrant.ps1 -LogToFile                                  # Avec log fichier
#   .\monitor_qdrant.ps1 -ExportJson -OutputFile "health.json"       # Export JSON

[CmdletBinding()]
param(
    [string]$Collection = "",                    # Collection spécifique (vide = toutes)
    [switch]$Watch = $false,                     # Monitoring continu
    [int]$IntervalSeconds = 60,                  # Intervalle entre checks
    [switch]$LogToFile = $false,                 # Log dans fichier texte
    [string]$OutputFile = "",                    # Fichier de sortie
    [switch]$ExportJson = $false,                # Export au format JSON
    [string]$EnvFile = ".env.production",        # Fichier .env à utiliser
    [string]$QdrantUrl = "http://localhost:6333", # URL du service Qdrant
    [string]$ContainerName = "qdrant_production"  # Nom du container Docker
)

$ErrorActionPreference = 'Continue'

# Fonctions d'affichage
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

function Write-ColoredStatus {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Status  # "good", "warning", "error"
    )
    
    $color = switch ($Status) {
        "good" { "Green" }
        "warning" { "Yellow" }
        "error" { "Red" }
        default { "White" }
    }
    
    Write-Host "$Label`: " -NoNewline
    Write-Host $Value -ForegroundColor $color
}

function Get-ApiKey {
    param([string]$EnvFilePath)
    
    if (-not (Test-Path $EnvFilePath)) {
        throw "Fichier .env introuvable: $EnvFilePath"
    }
    
    $apiKeyLine = Get-Content $EnvFilePath | Select-String 'QDRANT.*API_KEY=(.+)'
    if (-not $apiKeyLine) {
        throw "Impossible de récupérer l'API key depuis $EnvFilePath"
    }
    
    return $apiKeyLine.Matches.Groups[1].Value
}

function Get-QdrantHealth {
    param(
        [string]$Url,
        [string]$ApiKey
    )
    
    $headers = @{
        'api-key' = $ApiKey
        'Content-Type' = 'application/json'
    }
    
    $healthData = @{
        Timestamp = Get-Date -Format 'o'
        ServiceHealth = $null
        ContainerStats = $null
        Collections = @()
        DiskSpace = $null
        Errors = @()
    }
    
    # 1. Health check du service
    Write-Section "Service Health"
    try {
        $health = Invoke-RestMethod -Uri "$Url/healthz" -Method Get -TimeoutSec 5
        $healthData.ServiceHealth = "OK"
        Write-ColoredStatus "Service Status" "Healthy ✓" "good"
    }
    catch {
        $healthData.ServiceHealth = "ERROR"
        $healthData.Errors += "Service health check failed: $($_.Exception.Message)"
        Write-ColoredStatus "Service Status" "Unhealthy ✗" "error"
        return $healthData
    }
    
    # 2. Statistiques Docker
    Write-Section "Container Statistics"
    try {
        $containerStats = docker stats $ContainerName --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.NetIO}}" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $stats = $containerStats -split ','
            $healthData.ContainerStats = @{
                CPU = $stats[0]
                Memory = $stats[1]
                Network = $stats[2]
            }
            Write-ColoredStatus "CPU Usage" $stats[0] "good"
            Write-ColoredStatus "Memory Usage" $stats[1] "good"
            Write-ColoredStatus "Network I/O" $stats[2] "good"
        }
    }
    catch {
        $healthData.Errors += "Container stats failed: $($_.Exception.Message)"
        Write-ColoredStatus "Container Stats" "Unavailable" "warning"
    }
    
    # 3. Collections
    Write-Section "Collections Status"
    try {
        $allCollections = Invoke-RestMethod -Uri "$Url/collections" -Headers $headers -Method Get
        
        foreach ($col in $allCollections.result.collections) {
            $colName = $col.name
            
            # Si une collection spécifique est demandée, filtrer
            if ($Collection -and $colName -ne $Collection) {
                continue
            }
            
            Write-Host "`n  Collection: $colName" -ForegroundColor Magenta
            
            # Récupérer détails de la collection avec temps de réponse
            $responseTime = Measure-Command {
                $colDetails = Invoke-RestMethod -Uri "$Url/collections/$colName" -Headers $headers -Method Get
            }
            
            $colInfo = @{
                Name = $colName
                Status = $colDetails.result.status
                VectorsCount = $colDetails.result.vectors_count
                PointsCount = $colDetails.result.points_count
                IndexedVectorsCount = $colDetails.result.indexed_vectors_count
                SegmentsCount = $colDetails.result.segments_count
                ResponseTime = [math]::Round($responseTime.TotalMilliseconds, 2)
            }
            
            $healthData.Collections += $colInfo
            
            Write-ColoredStatus "  Status" $colInfo.Status $(if ($colInfo.Status -eq "green") { "good" } else { "warning" })
            Write-ColoredStatus "  Points Count" $colInfo.PointsCount "good"
            Write-ColoredStatus "  Vectors Count" $colInfo.VectorsCount "good"
            Write-ColoredStatus "  Indexed Vectors" $colInfo.IndexedVectorsCount "good"
            Write-ColoredStatus "  Segments" $colInfo.SegmentsCount "good"
            Write-ColoredStatus "  Response Time" "$($colInfo.ResponseTime) ms" $(
                if ($colInfo.ResponseTime -lt 100) { "good" }
                elseif ($colInfo.ResponseTime -lt 500) { "warning" }
                else { "error" }
            )
        }
    }
    catch {
        $healthData.Errors += "Collections check failed: $($_.Exception.Message)"
        Write-ColoredStatus "Collections Status" "Error" "error"
    }
    
    # 4. Espace disque WSL
    Write-Section "Disk Space (WSL)"
    try {
        $diskSpace = wsl df -h /var/lib/docker 2>&1 | Select-Object -Skip 1
        if ($diskSpace) {
            $healthData.DiskSpace = $diskSpace
            Write-Host $diskSpace
        }
    }
    catch {
        $healthData.Errors += "Disk space check failed: $($_.Exception.Message)"
        Write-ColoredStatus "Disk Space" "Unavailable" "warning"
    }
    
    # 5. Erreurs dans les logs récents (dernière minute)
    Write-Section "Recent Log Errors"
    try {
        $recentLogs = docker logs $ContainerName --since 1m 2>&1 | Select-String -Pattern "ERROR|WARN|panic" | Select-Object -First 10
        if ($recentLogs) {
            $healthData.Errors += @($recentLogs)
            Write-Host "Found $($recentLogs.Count) errors/warnings in last minute:" -ForegroundColor Yellow
            $recentLogs | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
        else {
            Write-ColoredStatus "Recent Errors" "None ✓" "good"
        }
    }
    catch {
        Write-ColoredStatus "Log Check" "Failed" "warning"
    }
    
    return $healthData
}

# Fonction principale
function Invoke-Monitoring {
    try {
        $apiKey = Get-ApiKey -EnvFilePath $EnvFile
        
        Write-Header "Qdrant Health Monitoring - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Host "Environment: $EnvFile"
        Write-Host "URL: $QdrantUrl"
        if ($Collection) {
            Write-Host "Collection: $Collection" -ForegroundColor Cyan
        }
        
        $healthData = Get-QdrantHealth -Url $QdrantUrl -ApiKey $apiKey
        
        # Export des résultats si demandé
        if ($ExportJson) {
            $jsonFile = if ($OutputFile) { $OutputFile } else { "qdrant_health_$(Get-Date -Format 'yyyyMMdd_HHmmss').json" }
            $healthData | ConvertTo-Json -Depth 10 | Out-File $jsonFile
            Write-Host "`nHealth data exported to: $jsonFile" -ForegroundColor Green
        }
        
        if ($LogToFile) {
            $logFile = if ($OutputFile) { $OutputFile } else { "qdrant_health_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" }
            $healthData | ConvertTo-Json -Depth 10 | Out-File $logFile -Append
            Write-Host "`nHealth data logged to: $logFile" -ForegroundColor Green
        }
        
        # Résumé final
        Write-Header "Health Summary"
        $totalErrors = $healthData.Errors.Count
        if ($totalErrors -eq 0) {
            Write-ColoredStatus "Overall Status" "All systems operational ✓" "good"
        }
        else {
            Write-ColoredStatus "Overall Status" "$totalErrors issues detected" "warning"
        }
        
    }
    catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        exit 1
    }
}

# Exécution
if ($Watch) {
    Write-Host "Starting continuous monitoring (Interval: $IntervalSeconds seconds, Press Ctrl+C to stop)..." -ForegroundColor Cyan
    while ($true) {
        Clear-Host
        Invoke-Monitoring
        Start-Sleep -Seconds $IntervalSeconds
    }
}
else {
    Invoke-Monitoring
}