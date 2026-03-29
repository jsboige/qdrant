# Script d'Analyse des Logs Qdrant
# Date: 2025-10-14

Write-Host "`n=== ANALYSE LOGS RÉCENTS ===" -ForegroundColor Cyan

# 1. Derniers 100 logs
Write-Host "`n1. Logs 100 dernières lignes:" -ForegroundColor Yellow
docker-compose -f myia_qdrant/docker-compose.production.yml logs --tail 100

Write-Host "`n2. Erreurs critiques récentes:" -ForegroundColor Yellow
$criticalErrors = docker-compose -f myia_qdrant/docker-compose.production.yml logs --tail 500 | Select-String -Pattern "error|panic|fatal|crash|killed|oom" -CaseSensitive:$false
if ($criticalErrors) {
    $criticalErrors | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
} else {
    Write-Host "  Aucune erreur critique trouvée" -ForegroundColor Green
}

Write-Host "`n3. Patterns saturation mémoire:" -ForegroundColor Yellow
$memoryIssues = docker-compose -f myia_qdrant/docker-compose.production.yml logs --tail 500 | Select-String -Pattern "memory|out of memory|allocation|heap" -CaseSensitive:$false
if ($memoryIssues) {
    $memoryIssues | ForEach-Object { Write-Host $_.Line -ForegroundColor Yellow }
} else {
    Write-Host "  Aucun problème mémoire trouvé" -ForegroundColor Green
}

Write-Host "`n4. Patterns problèmes disque:" -ForegroundColor Yellow
$diskIssues = docker-compose -f myia_qdrant/docker-compose.production.yml logs --tail 500 | Select-String -Pattern "disk|space|write|flush|sync" -CaseSensitive:$false
if ($diskIssues) {
    $diskIssues | ForEach-Object { Write-Host $_.Line -ForegroundColor Yellow }
} else {
    Write-Host "  Aucun problème disque trouvé" -ForegroundColor Green
}

Write-Host "`n5. Patterns de redémarrage:" -ForegroundColor Yellow
$restartPatterns = docker-compose -f myia_qdrant/docker-compose.production.yml logs --tail 500 | Select-String -Pattern "starting|started|initializing|boot|restart" -CaseSensitive:$false
if ($restartPatterns) {
    Write-Host "  Nombre de patterns de démarrage trouvés: $($restartPatterns.Count)" -ForegroundColor Cyan
    $restartPatterns | Select-Object -First 5 | ForEach-Object { Write-Host $_.Line -ForegroundColor Cyan }
} else {
    Write-Host "  Aucun pattern de redémarrage trouvé" -ForegroundColor Green
}

Write-Host "`n=== FIN ANALYSE LOGS ===" -ForegroundColor Cyan