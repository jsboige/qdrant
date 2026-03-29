# ===================================================================
# ANALYSE PRÉCISE DES VRAIES ERREURS HTTP 400
# ===================================================================
# Objectif: Distinguer les vraies erreurs HTTP 400 des faux positifs
# ===================================================================

param(
    [int]$Minutes = 10
)

Write-Host "=== ANALYSE ERREURS HTTP RÉELLES ===" -ForegroundColor Cyan
Write-Host "Période analysée: Dernières $Minutes minutes`n" -ForegroundColor Yellow

# Récupérer les logs
$logs = docker logs qdrant_production --since "${Minutes}m" 2>&1

# Pattern pour les vraies erreurs HTTP (format: "METHOD /path HTTP/1.1" CODE)
# Exemple: "PUT /collections/xxx HTTP/1.1" 400
$httpErrorPattern = '"[A-Z]+ /[^"]*\s+HTTP/\d\.\d"\s+([45]\d{2})\s+'

Write-Host "=== ERREURS HTTP 4xx/5xx ===" -ForegroundColor Red
$realErrors = $logs | Select-String -Pattern $httpErrorPattern
$errorCount = ($realErrors | Measure-Object).Count

if ($errorCount -eq 0) {
    Write-Host "✅ Aucune erreur HTTP 4xx/5xx détectée" -ForegroundColor Green
} else {
    Write-Host "❌ $errorCount erreurs HTTP détectées`n" -ForegroundColor Red
    
    # Grouper par code d'erreur
    $errorsByCode = $realErrors | ForEach-Object {
        if ($_.Line -match $httpErrorPattern) {
            [PSCustomObject]@{
                Code = $matches[1]
                Line = $_.Line
            }
        }
    } | Group-Object Code | Sort-Object Count -Descending
    
    foreach ($group in $errorsByCode) {
        Write-Host "`nCode HTTP $($group.Name): $($group.Count) occurrences" -ForegroundColor Yellow
        $group.Group | Select-Object -First 5 -ExpandProperty Line | ForEach-Object {
            Write-Host "  $_" -ForegroundColor DarkRed
        }
        if ($group.Count -gt 5) {
            Write-Host "  ... et $($group.Count - 5) autres" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n=== ANALYSE FAUX POSITIFS (durées contenant '400') ===" -ForegroundColor Yellow
$falsePositives = $logs | Select-String '400' | Where-Object { $_.Line -notmatch $httpErrorPattern }
$falsePositiveCount = ($falsePositives | Measure-Object).Count

Write-Host "Faux positifs détectés: $falsePositiveCount" -ForegroundColor Gray
if ($falsePositiveCount -gt 0) {
    Write-Host "Exemples de faux positifs:" -ForegroundColor DarkGray
    $falsePositives | Select-Object -First 3 -ExpandProperty Line | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }
}

Write-Host "`n=== REQUÊTES RÉUSSIES (HTTP 200) ===" -ForegroundColor Green
$successPattern = '"[A-Z]+ /[^"]*\s+HTTP/\d\.\d"\s+200\s+'
$successCount = ($logs | Select-String -Pattern $successPattern | Measure-Object).Count
Write-Host "Requêtes réussies: $successCount" -ForegroundColor Green

Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
$totalRequests = $errorCount + $successCount
$errorRate = if ($totalRequests -gt 0) { [math]::Round(($errorCount / $totalRequests) * 100, 2) } else { 0 }

Write-Host "Total requêtes analysées: $totalRequests"
Write-Host "Erreurs réelles: $errorCount" -ForegroundColor $(if ($errorCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "Requêtes réussies: $successCount" -ForegroundColor Green
Write-Host "Taux d'erreur: $errorRate%" -ForegroundColor $(if ($errorRate -eq 0) { 'Green' } elseif ($errorRate -lt 5) { 'Yellow' } else { 'Red' })

if ($errorCount -eq 0) {
    Write-Host "`n✅ AUCUNE VRAIE ERREUR HTTP - Le fix heap est EFFICACE" -ForegroundColor Green -BackgroundColor DarkGreen
} elseif ($errorRate -lt 5) {
    Write-Host "`n⚠️ QUELQUES ERREURS - Surveillance recommandée" -ForegroundColor Yellow -BackgroundColor DarkYellow
} else {
    Write-Host "`n❌ TAUX D'ERREUR ÉLEVÉ - Action corrective requise" -ForegroundColor Red -BackgroundColor DarkRed
}