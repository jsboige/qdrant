# Script d'analyse des logs de freeze Qdrant Production
$logFile = "freeze_analysis_logs.txt"

Write-Host "=== ANALYSE DES LOGS QDRANT PRODUCTION ===" -ForegroundColor Cyan
Write-Host ""

# 1. Compter les erreurs
$errors = Get-Content $logFile | Select-String -Pattern 'error|ERROR|panic|PANIC|timeout|TIMEOUT|deadlock|DEADLOCK|400|fatal|FATAL'
Write-Host "Total erreurs trouvees: $($errors.Count)" -ForegroundColor Yellow
Write-Host ""

# 2. Afficher les 50 premières erreurs
Write-Host "=== 50 PREMIERES ERREURS ===" -ForegroundColor Cyan
$errors | Select-Object -First 50 | ForEach-Object { Write-Host $_.Line }
Write-Host ""

# 3. Chercher les patterns spécifiques
Write-Host "=== PATTERNS SPECIFIQUES ===" -ForegroundColor Cyan
Write-Host "Erreurs 400:" -ForegroundColor Yellow
Get-Content $logFile | Select-String -Pattern '400' | Select-Object -First 10
Write-Host ""

Write-Host "Timeouts:" -ForegroundColor Yellow
Get-Content $logFile | Select-String -Pattern 'timeout|TIMEOUT' | Select-Object -First 10
Write-Host ""

Write-Host "Deadlocks:" -ForegroundColor Yellow
Get-Content $logFile | Select-String -Pattern 'deadlock|DEADLOCK|lock.*wait' | Select-Object -First 10
Write-Host ""

# 4. Analyser les timestamps pour détecter les patterns temporels
Write-Host "=== ANALYSE TEMPORELLE DES ERREURS ===" -ForegroundColor Cyan
$errors | ForEach-Object {
    if ($_.Line -match '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') {
        $matches[1]
    }
} | Group-Object { $_.Substring(0, 13) } | Sort-Object Count -Descending | Select-Object -First 10 | Format-Table Count, Name

# 5. Chercher les logs autour de 2025-10-11 06:58 (période suspecte)
Write-Host "=== LOGS AUTOUR DE 2025-10-11 06:58 (periode suspecte) ===" -ForegroundColor Cyan
Get-Content $logFile | Select-String -Pattern '2025-10-11T06:5[78]' | Select-Object -First 50

Write-Host ""
Write-Host "=== ANALYSE TERMINEE ===" -ForegroundColor Green