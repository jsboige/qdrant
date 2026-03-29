# Monitoring des erreurs HTTP 400 avant/après fix heap MCP

Write-Host "=== MONITORING ERREURS HTTP 400 ===" -ForegroundColor Cyan
Write-Host ""

# Heure de redémarrage VS Code estimée: ~23:30 UTC (01:30 heure locale)
$restartTime = Get-Date "2025-10-13T23:30:00Z"
$now = Get-Date

Write-Host "Heure actuelle: $($now.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow
Write-Host "Heure redémarrage VS Code estimée: $($restartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow
Write-Host ""

# AVANT redémarrage (30 minutes avant 23:30)
Write-Host "AVANT redémarrage VS Code (23:00-23:30 UTC):" -ForegroundColor Yellow
$beforeCount = docker logs qdrant_production --since "2025-10-13T23:00:00Z" --until "2025-10-13T23:30:00Z" 2>&1 | Select-String "400" | Measure-Object | Select-Object -ExpandProperty Count
Write-Host "  Erreurs 400: $beforeCount" -ForegroundColor $(if ($beforeCount -gt 10) { "Red" } else { "Yellow" })

# APRÈS redémarrage (depuis 23:30)
Write-Host ""
Write-Host "APRÈS redémarrage VS Code (depuis 23:30 UTC):" -ForegroundColor Green
$afterCount = docker logs qdrant_production --since "2025-10-13T23:30:00Z" 2>&1 | Select-String "400" | Measure-Object | Select-Object -ExpandProperty Count
Write-Host "  Erreurs 400: $afterCount" -ForegroundColor $(if ($afterCount -eq 0) { "Green" } elseif ($afterCount -lt 5) { "Yellow" } else { "Red" })

# Calcul de la réduction
Write-Host ""
if ($beforeCount -gt 0) {
    $reduction = [math]::Round((($beforeCount - $afterCount) / $beforeCount) * 100, 1)
    Write-Host "Réduction des erreurs: $reduction%" -ForegroundColor $(if ($reduction -gt 50) { "Green" } elseif ($reduction -gt 0) { "Yellow" } else { "Red" })
} else {
    Write-Host "Aucune erreur avant redémarrage pour comparaison" -ForegroundColor Yellow
}

# Dernières erreurs 400 (si présentes)
Write-Host ""
Write-Host "Dernières erreurs 400 (5 dernières):" -ForegroundColor Cyan
docker logs qdrant_production --since "2025-10-13T23:30:00Z" 2>&1 | Select-String "400" | Select-Object -Last 5

Write-Host ""
Write-Host "Critères de succès:" -ForegroundColor Cyan
Write-Host "  ✅ Excellent: 0 erreur après redémarrage" -ForegroundColor Green
Write-Host "  ✅ Bon: <5 erreurs après redémarrage (réduction >75%)" -ForegroundColor Green
Write-Host "  ⚠️  Acceptable: <10 erreurs après redémarrage (réduction >50%)" -ForegroundColor Yellow
Write-Host "  ❌ Problème: >10 erreurs après redémarrage" -ForegroundColor Red