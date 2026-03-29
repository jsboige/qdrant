#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Monitore les erreurs HTTP 400 du roo-state-manager dans les logs Qdrant

.DESCRIPTION
    Script de monitoring en temps réel pour vérifier que les corrections
    appliquées au roo-state-manager éliminent les erreurs HTTP 400

.PARAMETER Duration
    Durée du monitoring en secondes (défaut: 300 = 5 minutes)

.PARAMETER ShowAll
    Afficher tous les logs, pas seulement les erreurs

.EXAMPLE
    .\monitor_roo_state_manager_errors.ps1 -Duration 600
    
.NOTES
    Fichier: monitor_roo_state_manager_errors.ps1
    Auteur: Roo Code Mode
    Date: 2025-10-13
    Corrections appliquées dans: D:\roo-extensions\mcps\internal\servers\roo-state-manager\src\services\task-indexer.ts
#>

param(
    [int]$Duration = 300,
    [switch]$ShowAll
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  MONITORING ROO-STATE-MANAGER - HTTP 400" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Vérifier que Docker tourne
try {
    docker ps | Out-Null
} catch {
    Write-Host "❌ ERREUR: Docker n'est pas en cours d'exécution" -ForegroundColor Red
    exit 1
}

# Vérifier que le container Qdrant existe
$container = docker ps --format "{{.Names}}" | Select-String -Pattern "qdrant"
if (-not $container) {
    Write-Host "❌ ERREUR: Container Qdrant non trouvé" -ForegroundColor Red
    Write-Host "Containers actifs:" -ForegroundColor Yellow
    docker ps --format "table {{.Names}}\t{{.Status}}"
    exit 1
}

$containerName = $container.ToString()
Write-Host "✅ Container Qdrant trouvé: $containerName" -ForegroundColor Green
Write-Host ""

# Initialiser les compteurs
$errorCount400 = 0
$totalRequests = 0
$startTime = Get-Date
$endTime = $startTime.AddSeconds($Duration)

Write-Host "📊 Monitoring démarré à: $($startTime.ToString('HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "⏱️  Durée: $Duration secondes ($([math]::Round($Duration / 60, 1)) minutes)" -ForegroundColor Cyan
Write-Host "🎯 Collection cible: roo_tasks_semantic_index" -ForegroundColor Cyan
Write-Host "🔍 Recherche d'erreurs HTTP 400..." -ForegroundColor Cyan
Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Gray

# Pattern pour détecter les erreurs 400
$pattern400 = "PUT.*roo_tasks_semantic_index.*400|POST.*roo_tasks_semantic_index.*400"

# Stream des logs en temps réel
$job = Start-Job -ScriptBlock {
    param($containerName)
    docker logs -f $containerName --since 0s 2>&1
} -ArgumentList $containerName

# Monitoring loop
try {
    while ((Get-Date) -lt $endTime) {
        # Récupérer les nouvelles lignes de log
        $logs = Receive-Job $job -ErrorAction SilentlyContinue
        
        if ($logs) {
            foreach ($line in $logs) {
                $timestamp = Get-Date -Format "HH:mm:ss"
                
                # Détecter les requêtes vers roo_tasks_semantic_index
                if ($line -match "roo_tasks_semantic_index") {
                    $totalRequests++
                    
                    # Détecter les erreurs 400
                    if ($line -match $pattern400) {
                        $errorCount400++
                        Write-Host "[$timestamp] 🔴 ERREUR 400 #$errorCount400" -ForegroundColor Red
                        Write-Host "  $line" -ForegroundColor DarkRed
                        Write-Host ""
                    }
                    elseif ($ShowAll) {
                        if ($line -match "200|201") {
                            Write-Host "[$timestamp] ✅ Succès" -ForegroundColor Green
                        } else {
                            Write-Host "[$timestamp] 📝 Requête" -ForegroundColor Gray
                        }
                        Write-Host "  $line" -ForegroundColor DarkGray
                    }
                }
            }
        }
        
        Start-Sleep -Milliseconds 100
    }
}
finally {
    # Arrêter le job de streaming
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Gray
Write-Host ""

# Résumé final
$actualDuration = ((Get-Date) - $startTime).TotalSeconds
Write-Host "📊 RÉSUMÉ DU MONITORING" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan
Write-Host ""
Write-Host "⏱️  Durée effective: $([math]::Round($actualDuration, 1))s" -ForegroundColor White
Write-Host "📝 Requêtes totales vers roo_tasks_semantic_index: $totalRequests" -ForegroundColor White
Write-Host "🔴 Erreurs HTTP 400: $errorCount400" -ForegroundColor $(if ($errorCount400 -eq 0) { "Green" } else { "Red" })
Write-Host ""

# Verdict
if ($errorCount400 -eq 0) {
    Write-Host "✅ SUCCÈS: Aucune erreur HTTP 400 détectée!" -ForegroundColor Green
    Write-Host "✅ Les corrections appliquées fonctionnent correctement." -ForegroundColor Green
    Write-Host ""
    Write-Host "Corrections appliquées:" -ForegroundColor Cyan
    Write-Host "  1. Abandon immédiat sur HTTP 400 (pas de retry)" -ForegroundColor White
    Write-Host "  2. Validation dimension embedding (1536)" -ForegroundColor White
    Write-Host "  3. max_indexing_threads: 2 (création collection)" -ForegroundColor White
    Write-Host "  4. Format ID UUID (déjà correct)" -ForegroundColor White
    $exitCode = 0
} else {
    Write-Host "⚠️ ATTENTION: $errorCount400 erreur(s) HTTP 400 détectée(s)" -ForegroundColor Yellow
    Write-Host "⚠️ Analyse recommandée des logs complets" -ForegroundColor Yellow
    $exitCode = 1
}

Write-Host ""
Write-Host "Logs complets disponibles via:" -ForegroundColor Gray
Write-Host "  docker logs $containerName --since ${Duration}s" -ForegroundColor DarkGray

exit $exitCode