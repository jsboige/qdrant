# Script de monitoring de la collection roo_tasks_semantic_index
# Date création: 2025-10-13
# Usage: Surveiller la santé post-correction et détecter toute régression

param(
    [switch]$Watch = $false,
    [int]$IntervalSeconds = 60,
    [switch]$LogToFile = $false
)

$ErrorActionPreference = 'Stop'

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

function Get-CollectionHealth {
    # Récupérer l'API key
    $apiKeyLine = Get-Content .env.production | Select-String 'QDRANT_SERVICE_API_KEY=(.+)'
    if (-not $apiKeyLine) {
        throw "Impossible de récupérer l'API key"
    }
    $apiKey = $apiKeyLine.Matches.Groups[1].Value
    
    $headers = @{
        'api-key' = $apiKey
        'Content-Type' = 'application/json'
    }
    
    # Récupérer l'état de la collection
    try {
        # Mesurer le temps de réponse sur la requête principale
        $responseTime = Measure-Command {
            $collection = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers $headers -Method Get
        }
        
        return @{
            Success = $true
            Status = $collection.result.status
            PointsCount = $collection.result.points_count
            IndexedVectorsCount = $collection.result.indexed_vectors_count
            MaxIndexingThreads = $collection.result.config.hnsw_config.max_indexing_threads
            ResponseTime = [math]::Round($responseTime.TotalMilliseconds, 2)
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
}

function Show-HealthReport {
    param($Health)
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "HEALTH CHECK - roo_tasks_semantic_index" -ForegroundColor Cyan
    Write-Host "Time: $timestamp" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    if (-not $Health.Success) {
        Write-Host "❌ ERREUR: $($Health.Error)" -ForegroundColor Red
        return $false
    }
    
    # Déterminer le statut global
    $hasIssues = $false
    
    # 1. Status collection
    $statusColor = if ($Health.Status -eq "green") { "good" } elseif ($Health.Status -eq "yellow") { "warning" } else { "error" }
    Write-ColoredStatus "Status" $Health.Status $statusColor
    if ($statusColor -ne "good") { $hasIssues = $true }
    
    # 2. Points
    Write-ColoredStatus "Points" $Health.PointsCount "good"
    
    # 3. Indexation
    $indexPct = if ($Health.PointsCount -gt 0) { [math]::Round(($Health.IndexedVectorsCount / $Health.PointsCount) * 100, 1) } else { 0 }
    $indexStatus = if ($Health.IndexedVectorsCount -eq $Health.PointsCount) { "good" } elseif ($Health.IndexedVectorsCount -eq 0) { "warning" } else { "warning" }
    Write-ColoredStatus "Vecteurs indexés" "$($Health.IndexedVectorsCount)/$($Health.PointsCount) ($indexPct%)" $indexStatus
    if ($indexStatus -ne "good" -and $Health.PointsCount -gt 0) { 
        Write-Host "  ℹ️ L'indexation peut prendre quelques minutes après des modifications" -ForegroundColor Cyan
    }
    
    # 4. max_indexing_threads (CRITIQUE)
    $threadsStatus = if ($Health.MaxIndexingThreads -gt 0) { "good" } else { "error" }
    Write-ColoredStatus "max_indexing_threads" $Health.MaxIndexingThreads $threadsStatus
    if ($threadsStatus -eq "error") { 
        Write-Host "  ⚠️ CRITIQUE: max_indexing_threads à 0 causera des freezes !" -ForegroundColor Red
        $hasIssues = $true
    }
    
    # 5. Temps de réponse
    $responseStatus = if ($Health.ResponseTime -lt 100) { "good" } elseif ($Health.ResponseTime -lt 1000) { "warning" } else { "error" }
    Write-ColoredStatus "Temps de réponse" "$($Health.ResponseTime)ms" $responseStatus
    if ($responseStatus -eq "error") { $hasIssues = $true }
    
    Write-Host ""
    
    # Résumé
    if ($hasIssues) {
        Write-Host "⚠️ DES PROBLEMES ONT ETE DETECTES" -ForegroundColor Yellow
        return $false
    } else {
        Write-Host "✅ TOUT EST OK" -ForegroundColor Green
        return $true
    }
}

# Fonction principale
function Monitor-Collection {
    do {
        $health = Get-CollectionHealth
        $isHealthy = Show-HealthReport -Health $health
        
        # Logger vers fichier si demandé
        if ($LogToFile) {
            $logPath = "diagnostics/collection_health_log.jsonl"
            $health | ConvertTo-Json -Compress | Add-Content -Path $logPath
        }
        
        if ($Watch) {
            Write-Host ""
            Write-Host "Prochain check dans $IntervalSeconds secondes... (Ctrl+C pour arrêter)" -ForegroundColor Cyan
            Start-Sleep -Seconds $IntervalSeconds
        }
    } while ($Watch)
}

# Bannière
Write-Host ""
Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   QDRANT COLLECTION HEALTH MONITOR    ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan

if ($Watch) {
    Write-Host "Mode surveillance activé (intervalle: $IntervalSeconds secondes)" -ForegroundColor Yellow
    if ($LogToFile) {
        Write-Host "Logs sauvegardés dans: diagnostics/collection_health_log.jsonl" -ForegroundColor Yellow
    }
}

# Exécuter le monitoring
try {
    Monitor-Collection
} catch {
    Write-Host ""
    Write-Host "ERREUR FATALE: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "MONITORING TERMINE" -ForegroundColor Green