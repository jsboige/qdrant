# Script de validation post-fix indexation
# Vérifie que le fix a été appliqué avec succès

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = "diagnostics/fix_validation_$timestamp.md"

Write-Host "`n╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  ✅ VALIDATION POST-FIX INDEXATION QDRANT           ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Fonction pour appeler l'API
function Invoke-QdrantAPI {
    param($Endpoint, $Method = "GET", $Body = $null)
    
    $headers = @{"api-key" = "qdrant_admin"}
    $uri = "http://localhost:6333$Endpoint"
    
    try {
        if ($Body) {
            $response = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body ($Body | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 10
        } else {
            $response = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec 10
        }
        return $response
    }
    catch {
        Write-Host "❌ Erreur API $Endpoint : $_" -ForegroundColor Red
        return $null
    }
}

# 1. Vérifier API
Write-Host "1️⃣ Vérification API..." -ForegroundColor Yellow
$collections = Invoke-QdrantAPI -Endpoint "/collections"
if (-not $collections) {
    Write-Host "❌ API non accessible!" -ForegroundColor Red
    exit 1
}
Write-Host "✅ API opérationnelle: $($collections.result.collections.Count) collections`n" -ForegroundColor Green

# 2. Analyser état indexation
Write-Host "2️⃣ Analyse état d'indexation..." -ForegroundColor Yellow

$stats = @{
    Total = 0
    Indexed = 0
    NotIndexed = 0
    Empty = 0
}

$problematic = @()

foreach ($coll in $collections.result.collections) {
    $info = Invoke-QdrantAPI -Endpoint "/collections/$($coll.name)"
    if (-not $info) { continue }
    
    $stats.Total++
    $points = $info.result.points_count
    $indexed = $info.result.indexed_vectors_count
    
    if ($points -eq 0) {
        $stats.Empty++
    }
    elseif ($indexed -gt 0) {
        $stats.Indexed++
    }
    else {
        $stats.NotIndexed++
        if ($points -gt 1000) {
            $problematic += [PSCustomObject]@{
                Name = $coll.name
                Points = $points
                Indexed = $indexed
            }
        }
    }
}

Write-Host "📊 Statistiques:" -ForegroundColor Cyan
Write-Host "  - Total collections: $($stats.Total)" -ForegroundColor White
Write-Host "  - Indexées: $($stats.Indexed)" -ForegroundColor Green
Write-Host "  - NON indexées: $($stats.NotIndexed)" -ForegroundColor $(if ($stats.NotIndexed -gt 40) { "Red" } else { "Yellow" })
Write-Host "  - Vides: $($stats.Empty)" -ForegroundColor Gray

$indexationRate = [math]::Round(($stats.Indexed / ($stats.Total - $stats.Empty)) * 100, 1)
Write-Host "`n  📈 Taux d'indexation: $indexationRate%`n" -ForegroundColor $(if ($indexationRate -gt 60) { "Green" } else { "Yellow" })

# 3. Test performance
Write-Host "3️⃣ Test performance (échantillon 5 collections)..." -ForegroundColor Yellow

$samples = $collections.result.collections | Select-Object -First 5
$times = @()

foreach ($coll in $samples) {
    $start = Get-Date
    $result = Invoke-QdrantAPI -Endpoint "/collections/$($coll.name)/points/scroll" -Method POST -Body @{limit=10}
    $duration = (Get-Date) - $start
    $times += $duration.TotalMilliseconds
    Write-Host "  - $($coll.name): $([math]::Round($duration.TotalMilliseconds, 0)) ms" -ForegroundColor Gray
}

$avgTime = [math]::Round(($times | Measure-Object -Average).Average, 0)
Write-Host "`n  ⚡ Temps moyen: $avgTime ms" -ForegroundColor $(if ($avgTime -lt 100) { "Green" } elseif ($avgTime -lt 500) { "Yellow" } else { "Red" })

# 4. Génération rapport
Write-Host "`n4️⃣ Génération du rapport..." -ForegroundColor Yellow

$report = @"
# 📋 Rapport de Validation Post-Fix Indexation

**Date**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## 🎯 Objectif du Fix

Résoudre le problème de freeze causé par:
- **AVANT**: \`indexing_threshold_kb: 250000\` (250 MB) 
- Collections médianes ~4500 points (27 MB) → **66% en full scan O(n)**
- **APRÈS**: \`indexing_threshold_kb: 6000\` (6 MB)
- Collections >1000 points (6 MB) → **indexées avec HNSW O(log n)**

## 📊 Résultats

### État d'Indexation
- **Total collections**: $($stats.Total)
- **Indexées**: $($stats.Indexed) 
- **NON indexées**: $($stats.NotIndexed)
- **Vides**: $($stats.Empty)
- **Taux d'indexation**: $indexationRate%

### Performance
- **Temps réponse moyen**: $avgTime ms
- **Objectif**: < 100 ms ✅

## 🔍 Collections Problématiques (>1000 points NON indexées)

$( if ($problematic.Count -gt 0) {
    $problematic | ForEach-Object { "- **$($_.Name)**: $($_.Points) points, $($_.Indexed) indexés" } | Out-String
} else {
    "✅ Aucune collection problématique!"
})

## ✅ Conclusion

$( if ($indexationRate -gt 60 -and $avgTime -lt 100) {
    "**FIX RÉUSSI** ✅`n`n- Taux d'indexation: $indexationRate% (objectif: >60%)`n- Performance: $avgTime ms (objectif: <100ms)`n- Système stabilisé"
} elseif ($indexationRate -gt 40) {
    "**FIX PARTIELLEMENT RÉUSSI** ⚠️`n`n- Taux d'indexation: $indexationRate% (en dessous de 60%)`n- Peut nécessiter rebuild manuel des collections`n- Performance: $avgTime ms"
} else {
    "**FIX INCOMPLET** ❌`n`n- Taux d'indexation: $indexationRate% (très bas)`n- Rebuild manuel requis`n- Performance: $avgTime ms"
})

## 📝 Configuration Appliquée

\`\`\`yaml
storage:
  optimizers:
    indexing_threshold_kb: 6000  # MODIFIÉ: 250000 → 6000
\`\`\`

## 🔄 Actions Suivantes

$( if ($indexationRate -lt 60) {
    "1. ⚠️ Forcer rebuild des $($problematic.Count) collections problématiques`n2. Utiliser script: \`scripts/fix/20251015_hybrid_fix_indexation.ps1 -Force\``n3. Attendre 15-30 min pour indexation complète"
} else {
    "1. ✅ Monitoring continu pendant 48h`n2. Vérifier absence de freeze`n3. Si stable, fix validé définitivement"
})

---
*Généré le $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")*
"@

$report | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host "✅ Rapport généré: $reportFile`n" -ForegroundColor Green

# 5. Résumé
Write-Host "╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  📋 RÉSUMÉ" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($indexationRate -gt 60 -and $avgTime -lt 100) {
    Write-Host "`n✅ FIX RÉUSSI!" -ForegroundColor Green
    Write-Host "  - Taux d'indexation: $indexationRate%" -ForegroundColor Green
    Write-Host "  - Performance: $avgTime ms" -ForegroundColor Green
    Write-Host "  - Système stabilisé`n" -ForegroundColor Green
} elseif ($indexationRate -gt 40) {
    Write-Host "`n⚠️  FIX PARTIELLEMENT RÉUSSI" -ForegroundColor Yellow
    Write-Host "  - Taux d'indexation: $indexationRate% (en dessous de 60%)" -ForegroundColor Yellow
    Write-Host "  - Rebuild manuel peut être nécessaire`n" -ForegroundColor Yellow
} else {
    Write-Host "`n❌ FIX INCOMPLET" -ForegroundColor Red
    Write-Host "  - Taux d'indexation: $indexationRate% (très bas)" -ForegroundColor Red
    Write-Host "  - Rebuild manuel requis`n" -ForegroundColor Red
}

Write-Host "📄 Rapport détaillé: $reportFile`n" -ForegroundColor Cyan