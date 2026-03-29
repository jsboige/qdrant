# Script de Redémarrage Sécurisé Qdrant
# Date: 2025-10-13
# Usage: Redémarrage contrôlé avec vérification de santé
#
# EXEMPLES:
#   .\restart_qdrant.ps1                                             # Restart production
#   .\restart_qdrant.ps1 -ContainerName "qdrant_students"           # Restart Students
#   .\restart_qdrant.ps1 -SkipBackup                                # Sans backup préalable
#   .\restart_qdrant.ps1 -WaitHealthy -HealthTimeout 300            # Attendre santé avec timeout

[CmdletBinding()]
param(
    [string]$ContainerName = "qdrant_production",        # Nom du container Docker
    [string]$EnvFile = ".env.production",                # Fichier .env à utiliser
    [int]$Port = 6333,                                   # Port Qdrant
    [switch]$SkipBackup = $false,                        # Ne pas créer de backup avant restart
    [switch]$WaitHealthy = $true,                        # Attendre que le service soit healthy
    [int]$HealthTimeout = 180,                           # Timeout pour health check (secondes)
    [int]$HealthCheckInterval = 5,                       # Intervalle entre checks (secondes)
    [switch]$Force = $false                              # Forcer le restart même si des erreurs
)

$ErrorActionPreference = 'Stop'
$QdrantUrl = "http://localhost:$Port"

function Write-Step {
    param(
        [string]$Message,
        [string]$Status = "INFO"
    )
    
    $icon = switch ($Status) {
        "SUCCESS" { "✓" }
        "ERROR" { "✗" }
        "WARNING" { "⚠" }
        default { "•" }
    }
    
    $color = switch ($Status) {
        "SUCCESS" { "Green" }
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        default { "Cyan" }
    }
    
    Write-Host "$icon $Message" -ForegroundColor $color
}

function Get-ApiKey {
    param([string]$EnvPath)
    
    if (-not (Test-Path $EnvPath)) {
        throw "Fichier .env introuvable: $EnvPath"
    }
    
    $envContent = Get-Content $EnvPath
    foreach ($line in $envContent) {
        if ($line -match "^QDRANT.*API_KEY=(.+)$") {
            return $matches[1]
        }
    }
    
    throw "Impossible de récupérer l'API key depuis $EnvPath"
}

function Test-QdrantHealth {
    param(
        [string]$Url,
        [string]$ApiKey
    )
    
    try {
        $headers = @{ 'api-key' = $ApiKey }
        $response = Invoke-RestMethod -Uri "$Url/healthz" -Headers $headers -Method Get -TimeoutSec 5 -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Wait-QdrantHealthy {
    param(
        [string]$Url,
        [string]$ApiKey,
        [int]$TimeoutSeconds,
        [int]$IntervalSeconds
    )
    
    $elapsed = 0
    $maxAttempts = [math]::Ceiling($TimeoutSeconds / $IntervalSeconds)
    
    Write-Step "Attente que le service devienne healthy (timeout: ${TimeoutSeconds}s)..." "INFO"
    
    for ($i = 1; $i -le $maxAttempts; $i++) {
        if (Test-QdrantHealth -Url $Url -ApiKey $ApiKey) {
            Write-Step "Service healthy après ${elapsed}s" "SUCCESS"
            return $true
        }
        
        Write-Host "  Tentative $i/$maxAttempts - Service pas encore prêt..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
    }
    
    Write-Step "Timeout: Service non healthy après ${TimeoutSeconds}s" "ERROR"
    return $false
}

# DÉBUT DU SCRIPT PRINCIPAL
Write-Host "`n╔════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Redémarrage Sécurisé Qdrant              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Container: $ContainerName"
Write-Host "Environment: $EnvFile"
Write-Host "Port: $Port"
Write-Host ""

try {
    # 1. Vérifier que le container existe
    Write-Step "Vérification du container..." "INFO"
    $containerExists = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}" 2>&1
    
    if ($containerExists -ne $ContainerName) {
        throw "Container '$ContainerName' introuvable"
    }
    Write-Step "Container trouvé" "SUCCESS"
    
    # 2. Récupérer l'API key
    Write-Step "Récupération de l'API key..." "INFO"
    $apiKey = Get-ApiKey -EnvPath $EnvFile
    Write-Step "API key récupérée" "SUCCESS"
    
    # 3. Vérifier l'état actuel
    Write-Step "Vérification de l'état actuel..." "INFO"
    $wasHealthy = Test-QdrantHealth -Url $QdrantUrl -ApiKey $apiKey
    
    if ($wasHealthy) {
        Write-Step "Service actuellement healthy" "SUCCESS"
    }
    else {
        Write-Step "Service actuellement non healthy" "WARNING"
        
        if (-not $Force) {
            $continue = Read-Host "Le service n'est pas healthy. Continuer quand même? (o/N)"
            if ($continue -ne "o") {
                Write-Step "Opération annulée par l'utilisateur" "WARNING"
                exit 0
            }
        }
    }
    
    # 4. Backup (optionnel)
    if (-not $SkipBackup -and $wasHealthy) {
        Write-Step "Création d'un backup de sécurité..." "INFO"
        
        $backupScript = Join-Path $PSScriptRoot "../backup/backup_qdrant.ps1"
        
        if (Test-Path $backupScript) {
            $backupParams = @{
                EnvFile = $EnvFile
                Port = $Port
                ContainerName = $ContainerName
                SkipSnapshot = $true  # Pas de snapshot, juste config
            }
            
            & $backupScript @backupParams
            
            if ($LASTEXITCODE -eq 0) {
                Write-Step "Backup créé avec succès" "SUCCESS"
            }
            else {
                Write-Step "Échec du backup" "WARNING"
                
                if (-not $Force) {
                    $continue = Read-Host "Le backup a échoué. Continuer quand même? (o/N)"
                    if ($continue -ne "o") {
                        Write-Step "Opération annulée" "WARNING"
                        exit 1
                    }
                }
            }
        }
        else {
            Write-Step "Script de backup introuvable, ignoré" "WARNING"
        }
    }
    else {
        Write-Step "Backup ignoré (SkipBackup ou service non healthy)" "INFO"
    }
    
    # 5. Redémarrage du container
    Write-Step "Redémarrage du container..." "INFO"
    
    $restartOutput = docker restart $ContainerName 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        throw "Échec du redémarrage: $restartOutput"
    }
    
    Write-Step "Container redémarré" "SUCCESS"
    
    # 6. Attendre que le service soit healthy
    if ($WaitHealthy) {
        Write-Host ""
        $isHealthy = Wait-QdrantHealthy -Url $QdrantUrl -ApiKey $apiKey -TimeoutSeconds $HealthTimeout -IntervalSeconds $HealthCheckInterval
        
        if (-not $isHealthy) {
            throw "Le service n'est pas devenu healthy dans le délai imparti"
        }
    }
    else {
        Write-Step "Vérification de santé ignorée (WaitHealthy=$false)" "INFO"
    }
    
    # 7. Vérification post-restart
    Write-Host ""
    Write-Step "Vérification post-restart..." "INFO"
    
    # Vérifier les logs récents
    $recentLogs = docker logs $ContainerName --tail 20 2>&1
    $errors = $recentLogs | Select-String -Pattern "ERROR|CRITICAL|panic"
    
    if ($errors.Count -gt 0) {
        Write-Step "Erreurs détectées dans les logs récents:" "WARNING"
        $errors | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
    else {
        Write-Step "Aucune erreur dans les logs récents" "SUCCESS"
    }
    
    # Vérifier les stats du container
    $stats = docker stats $ContainerName --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $statsArray = $stats -split ','
        Write-Step "CPU: $($statsArray[0])" "INFO"
        Write-Step "Memory: $($statsArray[1])" "INFO"
    }
    
    # Résumé final
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  Redémarrage terminé avec succès!         ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Container: $ContainerName" -ForegroundColor Cyan
    Write-Host "Status: Healthy ✓" -ForegroundColor Green
    Write-Host "URL: $QdrantUrl" -ForegroundColor Cyan
    
}
catch {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║  ERREUR lors du redémarrage               ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Step "Erreur: $($_.Exception.Message)" "ERROR"
    Write-Host ""
    Write-Host "Commandes de récupération:" -ForegroundColor Yellow
    Write-Host "  docker logs $ContainerName --tail 100" -ForegroundColor Cyan
    Write-Host "  docker inspect $ContainerName" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}