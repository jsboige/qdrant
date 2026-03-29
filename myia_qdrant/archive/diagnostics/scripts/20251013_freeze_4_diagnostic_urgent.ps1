# Script de Diagnostic d'Urgence - 4ème Freeze
# Date: 2025-10-13 18:30
# Contexte: Container unhealthy pendant documentation

Write-Host "`n╔════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║  🚨 DIAGNOSTIC URGENCE - 4ÈME FREEZE DÉTECTÉ 🚨  ║" -ForegroundColor Red
Write-Host "╚════════════════════════════════════════════════════╝`n" -ForegroundColor Red

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logDir = "myia_qdrant/diagnostics"

# 1. État Docker
Write-Host "▶ État Container Docker..." -ForegroundColor Yellow
$dockerStatus = docker ps -a --filter "name=qdrant_production" --format "{{.Status}}"
Write-Host "  Status: $dockerStatus" -ForegroundColor $(if ($dockerStatus -match "unhealthy") { "Red" } else { "Green" })

# 2. Test Healthcheck
Write-Host "`n▶ Test Healthcheck..." -ForegroundColor Yellow
try {
    $health = Invoke-WebRequest -Uri "http://localhost:6333/healthz" -TimeoutSec 5 -UseBasicParsing
    Write-Host "  ✓ Service répond: $($health.StatusCode)" -ForegroundColor Green
    $serviceUp = $true
} catch {
    Write-Host "  ✗ Service ne répond pas: $_" -ForegroundColor Red
    $serviceUp = $false
}

# 3. Logs récents (500 dernières lignes)
Write-Host "`n▶ Capture des logs récents..." -ForegroundColor Yellow
$logsFile = "$logDir/freeze_4_logs_$timestamp.txt"
docker logs qdrant_production --tail 500 --timestamps > $logsFile
$logsSize = (Get-Item $logsFile).Length / 1KB
Write-Host "  ✓ $logsSize KB capturés dans $logsFile" -ForegroundColor Green

# 4. Analyse pattern d'erreurs
Write-Host "`n▶ Analyse rapide des erreurs..." -ForegroundColor Yellow
$logs = Get-Content $logsFile
$errors400 = ($logs | Select-String "400").Count
$errors500 = ($logs | Select-String "500").Count
$panics = ($logs | Select-String "panic|PANIC").Count
$timeouts = ($logs | Select-String "timeout|Timeout").Count

Write-Host "  Erreurs 400: $errors400" -ForegroundColor $(if ($errors400 -gt 10) { "Red" } else { "Yellow" })
Write-Host "  Erreurs 500: $errors500" -ForegroundColor $(if ($errors500 -gt 0) { "Red" } else { "Green" })
Write-Host "  Panics: $panics" -ForegroundColor $(if ($panics -gt 0) { "Red" } else { "Green" })
Write-Host "  Timeouts: $timeouts" -ForegroundColor $(if ($timeouts -gt 5) { "Red" } else { "Yellow" })

# 5. Dernières erreurs
Write-Host "`n▶ 10 Dernières erreurs..." -ForegroundColor Yellow
$lastErrors = $logs | Select-String "ERROR|WARN|400|500" | Select-Object -Last 10
$lastErrors | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

# 6. Métriques ressources
Write-Host "`n▶ Ressources Container..." -ForegroundColor Yellow
$stats = docker stats qdrant_production --no-stream --format "{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
if ($stats) {
    $parts = $stats -split '\t'
    Write-Host "  CPU: $($parts[0])" -ForegroundColor $(if ([float]($parts[0] -replace '%','') -gt 80) { "Red" } else { "Green" })
    Write-Host "  Mémoire: $($parts[1]) ($($parts[2]))" -ForegroundColor $(if ([float]($parts[2] -replace '%','') -gt 90) { "Red" } else { "Green" })
}

# 7. État collections (si service répond)
if ($serviceUp) {
    Write-Host "`n▶ État roo_tasks_semantic_index..." -ForegroundColor Yellow
    try {
        $apiKey = (Get-Content ".env.production" | Select-String "QDRANT_SERVICE_API_KEY").ToString().Split("=")[1].Trim()
        $collection = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers @{"api-key"=$apiKey} -TimeoutSec 5
        Write-Host "  Status: $($collection.result.status)" -ForegroundColor $(if ($collection.result.status -eq "green") { "Green" } else { "Red" })
        Write-Host "  Points: $($collection.result.points_count)" -ForegroundColor Cyan
        Write-Host "  Indexed: $($collection.result.indexed_vectors_count)" -ForegroundColor Cyan
    } catch {
        Write-Host "  ✗ Impossible de récupérer l'état: $_" -ForegroundColor Red
    }
}

# 8. Recommandations
Write-Host "`n╔════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║              RECOMMANDATIONS IMMÉDIATES            ║" -ForegroundColor Yellow
Write-Host "╚════════════════════════════════════════════════════╝`n" -ForegroundColor Yellow

if (-not $serviceUp) {
    Write-Host "🚨 SERVICE DOWN - Actions urgentes:" -ForegroundColor Red
    Write-Host "  1. Redémarrer le container:" -ForegroundColor Yellow
    Write-Host "     pwsh -File myia_qdrant/scripts/maintenance/restart_qdrant.ps1" -ForegroundColor Cyan
    Write-Host "  2. Si échec, vérifier les logs complets:" -ForegroundColor Yellow
    Write-Host "     docker logs qdrant_production --tail 1000" -ForegroundColor Cyan
} else {
    Write-Host "⚠️ SERVICE UP mais UNHEALTHY - Monitoring:" -ForegroundColor Yellow
    Write-Host "  1. Surveiller l'évolution:" -ForegroundColor Yellow
    Write-Host "     pwsh -File myia_qdrant/scripts/health/monitor_qdrant.ps1 -Watch" -ForegroundColor Cyan
    Write-Host "  2. Si dégradation, redémarrer" -ForegroundColor Yellow
}

# 9. Comparaison avec freezes précédents
Write-Host "`n▶ Comparaison avec freezes précédents..." -ForegroundColor Yellow
Write-Host "  Freeze 1 (13h48): max_indexing_threads: 0" -ForegroundColor Gray
Write-Host "  Freeze 2 (16h45): 3h après correction" -ForegroundColor Gray
Write-Host "  Freeze 3 (18h05): 1h après freeze 2 (accélération)" -ForegroundColor Gray
Write-Host "  Freeze 4 (18h30): 25 min après freeze 3 (CRITIQUE!)" -ForegroundColor Red

# 10. Export diagnostic
$diagnosticFile = "$logDir/freeze_4_diagnostic_$timestamp.json"
$diagnostic = @{
    timestamp = $timestamp
    dockerStatus = $dockerStatus
    serviceUp = $serviceUp
    errors = @{
        e400 = $errors400
        e500 = $errors500
        panics = $panics
        timeouts = $timeouts
    }
    logsFile = $logsFile
} | ConvertTo-Json -Depth 10

$diagnostic | Out-File $diagnosticFile
Write-Host "`n✓ Diagnostic exporté: $diagnosticFile" -ForegroundColor Green

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "⚠️ FREEZE 4 = PATTERN CRITIQUE!" -ForegroundColor Red
Write-Host "⚠️ Accélération: 3h → 1h → 25min" -ForegroundColor Red
Write-Host "⚠️ La correction précédente N'A PAS FONCTIONNÉ" -ForegroundColor Red
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan