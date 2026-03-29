<#
.SYNOPSIS
    Script de monitoring continu Qdrant avec auto-healing

.DESCRIPTION
    Surveille en continu la santé du container Qdrant et effectue:
    - Vérification healthcheck toutes les 30s
    - Détection freeze (timeout > 10s)
    - Capture logs automatique au freeze
    - Redémarrage auto si freeze confirmé
    - Alertes si problèmes récurrents (>3 en 1h)
    - Statistiques ressources (CPU, RAM)

.PARAMETER CheckInterval
    Intervalle entre checks en secondes (défaut: 30)

.PARAMETER HealthTimeout
    Timeout pour considérer freeze en secondes (défaut: 10)

.PARAMETER MaxRestarts
    Nombre max redémarrages en 1h avant alerte (défaut: 3)

.PARAMETER LogPath
    Chemin du répertoire de logs (défaut: ./logs/monitoring)

.PARAMETER AutoRestart
    Active le redémarrage automatique (défaut: $true)

.EXAMPLE
    .\continuous_health_check.ps1
    # Mode par défaut: monitoring + auto-restart

.EXAMPLE
    .\continuous_health_check.ps1 -AutoRestart $false
    # Mode monitoring seul sans redémarrage auto

.EXAMPLE
    .\continuous_health_check.ps1 -CheckInterval 60 -HealthTimeout 15
    # Intervalle personnalisé: 60s, timeout 15s

.NOTES
    Date: 2025-10-15
    Version: 1.0
    Auteur: Infrastructure Team
#>

param(
    [int]$CheckInterval = 30,
    [int]$HealthTimeout = 10,
    [int]$MaxRestarts = 3,
    [string]$LogPath = "logs/monitoring",
    [bool]$AutoRestart = $true
)

# Configuration
$ContainerName = "qdrant_production"
$HealthEndpoint = "http://localhost:6333/healthz"
$ComposeFile = "docker-compose.production.yml"

# Couleurs pour output
$ColorSuccess = "Green"
$ColorWarning = "Yellow"
$ColorError = "Red"
$ColorInfo = "Cyan"

# Initialisation
$RestartHistory = @()
$FreezeCount = 0
$StartTime = Get-Date

# Créer répertoire logs
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$LogFile = Join-Path $LogPath "health_check_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    # Écrire dans fichier
    Add-Content -Path $LogFile -Value $LogEntry
    
    # Afficher dans console avec couleur
    $Color = switch ($Level) {
        "SUCCESS" { $ColorSuccess }
        "WARNING" { $ColorWarning }
        "ERROR" { $ColorError }
        default { $ColorInfo }
    }
    Write-Host $LogEntry -ForegroundColor $Color
}

function Test-QdrantHealth {
    <#
    .SYNOPSIS
        Teste la santé du container Qdrant
    .OUTPUTS
        Hashtable avec status, responseTime, healthy, containerStatus
    #>
    
    $Result = @{
        healthy = $false
        responseTime = 0
        status = "unknown"
        containerStatus = "unknown"
        error = $null
    }
    
    try {
        # Vérifier statut container Docker
        $ContainerInfo = docker ps --filter "name=$ContainerName" --format "{{.Status}}" 2>$null
        
        if (-not $ContainerInfo) {
            $Result.status = "stopped"
            $Result.containerStatus = "stopped"
            $Result.error = "Container not running"
            return $Result
        }
        
        $Result.containerStatus = $ContainerInfo
        
        # Vérifier santé via endpoint HTTP
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        $Response = Invoke-WebRequest -Uri $HealthEndpoint -TimeoutSec $HealthTimeout -UseBasicParsing -ErrorAction Stop
        
        $Stopwatch.Stop()
        $Result.responseTime = $Stopwatch.ElapsedMilliseconds
        
        if ($Response.StatusCode -eq 200) {
            $Result.healthy = $true
            $Result.status = "healthy"
        } else {
            $Result.status = "unhealthy"
            $Result.error = "HTTP $($Response.StatusCode)"
        }
        
    } catch {
        $Result.status = "timeout"
        $Result.error = $_.Exception.Message
        
        # Si timeout, considérer comme freeze
        if ($_.Exception.Message -match "timeout") {
            $Result.status = "freeze"
        }
    }
    
    return $Result
}

function Get-QdrantStats {
    <#
    .SYNOPSIS
        Récupère statistiques ressources du container
    .OUTPUTS
        Hashtable avec cpu, memory, memoryLimit
    #>
    
    try {
        $StatsJson = docker stats $ContainerName --no-stream --format "{{json .}}" 2>$null | ConvertFrom-Json
        
        return @{
            cpu = $StatsJson.CPUPerc
            memory = $StatsJson.MemUsage
            memoryLimit = $StatsJson.MemPerc
        }
    } catch {
        return @{
            cpu = "N/A"
            memory = "N/A"
            memoryLimit = "N/A"
        }
    }
}

function Capture-FreezeLogs {
    <#
    .SYNOPSIS
        Capture les logs au moment d'un freeze
    #>
    param(
        [string]$Reason
    )
    
    $FreezeLogFile = Join-Path $LogPath "freeze_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    
    Write-Log "📸 Capture logs freeze: $Reason" "WARNING"
    
    # Logs container (dernières 200 lignes)
    docker logs $ContainerName --tail 200 > $FreezeLogFile 2>&1
    
    # Stats container
    "=== STATS CONTAINER ===" | Add-Content $FreezeLogFile
    docker stats $ContainerName --no-stream >> $FreezeLogFile 2>&1
    
    # Processus container
    "=== PROCESSUS ===" | Add-Content $FreezeLogFile
    docker top $ContainerName >> $FreezeLogFile 2>&1
    
    Write-Log "Logs capturés: $FreezeLogFile" "INFO"
    
    return $FreezeLogFile
}

function Restart-QdrantContainer {
    <#
    .SYNOPSIS
        Redémarre le container Qdrant proprement
    .OUTPUTS
        Boolean: $true si succès, $false sinon
    #>
    
    Write-Log "🔄 Redémarrage container en cours..." "WARNING"
    
    try {
        # Arrêt gracieux (60s grace period)
        Write-Log "Arrêt gracieux (60s grace period)..." "INFO"
        docker compose -f $ComposeFile down 2>&1 | Out-Null
        
        Start-Sleep -Seconds 5
        
        # Redémarrage
        Write-Log "Démarrage container..." "INFO"
        docker compose -f $ComposeFile up -d 2>&1 | Out-Null
        
        # Attendre démarrage (40s start_period healthcheck)
        Write-Log "Attente démarrage (40s)..." "INFO"
        Start-Sleep -Seconds 40
        
        # Vérifier santé
        $Health = Test-QdrantHealth
        
        if ($Health.healthy) {
            Write-Log "✅ Redémarrage réussi (temps réponse: $($Health.responseTime)ms)" "SUCCESS"
            return $true
        } else {
            Write-Log "❌ Container démarré mais unhealthy: $($Health.error)" "ERROR"
            return $false
        }
        
    } catch {
        Write-Log "❌ Erreur redémarrage: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Send-Alert {
    <#
    .SYNOPSIS
        Envoie une alerte (placeholder pour intégration future)
    #>
    param(
        [string]$Message,
        [string]$Severity = "WARNING"
    )
    
    Write-Log "🚨 ALERTE [$Severity]: $Message" "ERROR"
    
    # TODO: Intégrer avec système notification (email, Slack, Teams, etc.)
    # Pour l'instant, juste log + beep
    [Console]::Beep(1000, 500)
}

# ============================================
# BOUCLE PRINCIPALE DE MONITORING
# ============================================

Write-Log "========================================" "INFO"
Write-Log "🔍 MONITORING QDRANT DÉMARRÉ" "SUCCESS"
Write-Log "========================================" "INFO"
Write-Log "Container: $ContainerName" "INFO"
Write-Log "Check interval: ${CheckInterval}s" "INFO"
Write-Log "Health timeout: ${HealthTimeout}s" "INFO"
Write-Log "Auto-restart: $AutoRestart" "INFO"
Write-Log "Max restarts/h: $MaxRestarts" "INFO"
Write-Log "Log file: $LogFile" "INFO"
Write-Log "========================================" "INFO"
Write-Log "" "INFO"

try {
    while ($true) {
        $CheckTime = Get-Date
        
        # Test santé
        $Health = Test-QdrantHealth
        $Stats = Get-QdrantStats
        
        # Log status
        $StatusMsg = "Status: $($Health.status) | Response: $($Health.responseTime)ms | CPU: $($Stats.cpu) | RAM: $($Stats.memory) ($($Stats.memoryLimit))"
        
        if ($Health.healthy) {
            Write-Log "✅ $StatusMsg" "SUCCESS"
            $FreezeCount = 0  # Reset compteur freeze
        } else {
            Write-Log "⚠️ $StatusMsg | Error: $($Health.error)" "WARNING"
            $FreezeCount++
            
            # Capture logs
            $FreezeLogPath = Capture-FreezeLogs -Reason $Health.error
            
            # Décider si redémarrage nécessaire
            if ($AutoRestart -and ($Health.status -eq "freeze" -or $Health.status -eq "stopped" -or $FreezeCount -ge 2)) {
                
                # Vérifier historique redémarrages
                $OneHourAgo = (Get-Date).AddHours(-1)
                $RestartHistory = $RestartHistory | Where-Object { $_ -gt $OneHourAgo }
                
                if ($RestartHistory.Count -ge $MaxRestarts) {
                    Send-Alert -Message "TROP DE REDÉMARRAGES: $($RestartHistory.Count) en 1h. Redémarrage bloqué. Intervention manuelle requise." -Severity "CRITICAL"
                    Write-Log "🛑 Monitoring suspendu: Trop de redémarrages. Vérifier: $FreezeLogPath" "ERROR"
                    break
                }
                
                # Redémarrer
                $RestartSuccess = Restart-QdrantContainer
                
                if ($RestartSuccess) {
                    $RestartHistory += $CheckTime
                    $FreezeCount = 0
                    Write-Log "Redémarrage #$($RestartHistory.Count) dans la dernière heure" "INFO"
                } else {
                    Send-Alert -Message "ÉCHEC REDÉMARRAGE QDRANT. Vérifier logs: $FreezeLogPath" -Severity "CRITICAL"
                }
            }
        }
        
        # Statistiques session
        $Uptime = (Get-Date) - $StartTime
        Write-Log "Session: $([math]::Round($Uptime.TotalMinutes, 1))min | Restarts: $($RestartHistory.Count)/h | Freezes: $FreezeCount" "INFO"
        Write-Log "---" "INFO"
        
        # Attendre prochain check
        Start-Sleep -Seconds $CheckInterval
    }
    
} catch {
    Write-Log "❌ ERREUR CRITIQUE MONITORING: $($_.Exception.Message)" "ERROR"
    Send-Alert -Message "MONITORING QDRANT ARRÊTÉ: $($_.Exception.Message)" -Severity "CRITICAL"
    throw
} finally {
    Write-Log "🛑 Monitoring arrêté" "WARNING"
}