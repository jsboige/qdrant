# Mesure du temps de réponse Qdrant

Write-Host "=== TEMPS DE RÉPONSE QDRANT ===" -ForegroundColor Cyan
Write-Host ""

$apiKey = $env:QDRANT_API_KEY
if (-not $apiKey) {
    Write-Host "⚠️  Variable QDRANT_API_KEY non définie" -ForegroundColor Yellow
    $headers = @{}
} else {
    $headers = @{
        "api-key" = $apiKey
    }
}

$measures = @()
$successCount = 0
$failCount = 0

Write-Host "Effectuer 5 requêtes vers /collections..." -ForegroundColor Yellow
Write-Host ""

for ($i = 1; $i -le 5; $i++) {
    try {
        $elapsed = Measure-Command {
            $response = Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $headers -Method Get -ErrorAction Stop
        }
        
        $ms = [math]::Round($elapsed.TotalMilliseconds, 2)
        $measures += $ms
        $successCount++
        
        $color = if ($ms -lt 100) { "Green" } elseif ($ms -lt 500) { "Yellow" } else { "Red" }
        Write-Host "Requête $i : $ms ms" -ForegroundColor $color
        
    } catch {
        $failCount++
        Write-Host "Requête $i : ÉCHEC - $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Start-Sleep -Milliseconds 200
}

Write-Host ""

if ($measures.Count -gt 0) {
    $avg = ($measures | Measure-Object -Average).Average
    $min = ($measures | Measure-Object -Minimum).Minimum
    $max = ($measures | Measure-Object -Maximum).Maximum
    
    Write-Host "Statistiques:" -ForegroundColor Cyan
    Write-Host "  Moyenne: $([math]::Round($avg, 2)) ms" -ForegroundColor $(if ($avg -lt 100) { "Green" } elseif ($avg -lt 500) { "Yellow" } else { "Red" })
    Write-Host "  Min: $([math]::Round($min, 2)) ms" -ForegroundColor Green
    Write-Host "  Max: $([math]::Round($max, 2)) ms" -ForegroundColor $(if ($max -lt 500) { "Green" } elseif ($max -lt 1000) { "Yellow" } else { "Red" })
    Write-Host "  Succès: $successCount/5" -ForegroundColor $(if ($successCount -eq 5) { "Green" } else { "Yellow" })
    
    Write-Host ""
    Write-Host "Évaluation:" -ForegroundColor Cyan
    if ($avg -lt 100) {
        Write-Host "  ✅ EXCELLENT - Qdrant répond très rapidement" -ForegroundColor Green
    } elseif ($avg -lt 500) {
        Write-Host "  ✅ BON - Qdrant répond rapidement" -ForegroundColor Green
    } elseif ($avg -lt 1000) {
        Write-Host "  ⚠️  ACCEPTABLE - Temps de réponse légèrement élevé" -ForegroundColor Yellow
    } else {
        Write-Host "  ❌ PROBLÈME - Temps de réponse trop élevé" -ForegroundColor Red
    }
} else {
    Write-Host "❌ Toutes les requêtes ont échoué" -ForegroundColor Red
}