#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Validation post-correction HNSW - Vérification de l'état des collections
    
.DESCRIPTION
    Vérifie que toutes les collections ont bien max_indexing_threads=16
    et génère un rapport détaillé.
#>

$ErrorActionPreference = "Stop"
$API_KEY = "qdrant_admin"
$QDRANT_URL = "http://localhost:6333"

Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  VALIDATION CORRECTION HNSW                                   ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Récupération de toutes les collections
Write-Host "🔍 Récupération de la liste des collections..." -ForegroundColor Cyan
$collectionsResponse = Invoke-RestMethod -Uri "$QDRANT_URL/collections" -Headers @{"api-key"=$API_KEY} -Method Get
$allCollections = $collectionsResponse.result.collections

Write-Host "📊 Total collections: $($allCollections.Count)`n" -ForegroundColor Cyan

# Analyse de chaque collection
$results = @()
$threadsZero = @()
$threads16 = @()
$threadsOther = @()

foreach ($col in $allCollections) {
    try {
        $info = Invoke-RestMethod -Uri "$QDRANT_URL/collections/$($col.name)" -Headers @{"api-key"=$API_KEY} -Method Get
        $threads = $info.result.config.hnsw_config.max_indexing_threads
        $points = $info.result.points_count
        
        $result = [PSCustomObject]@{
            Name = $col.name
            Threads = $threads
            Points = $points
            Segments = $info.result.segments_count
        }
        
        $results += $result
        
        switch ($threads) {
            0 { $threadsZero += $result }
            16 { $threads16 += $result }
            default { $threadsOther += $result }
        }
    }
    catch {
        Write-Host "⚠️  Erreur lecture $($col.name): $_" -ForegroundColor Yellow
    }
}

# Affichage du résumé
Write-Host "`n=== RÉSUMÉ GLOBAL ===" -ForegroundColor Cyan
Write-Host "✅ Threads=16:  $($threads16.Count) collections" -ForegroundColor Green
Write-Host "❌ Threads=0:   $($threadsZero.Count) collections" -ForegroundColor $(if ($threadsZero.Count -eq 0) { "Green" } else { "Red" })
Write-Host "⚠️  Autres:     $($threadsOther.Count) collections" -ForegroundColor $(if ($threadsOther.Count -eq 0) { "Green" } else { "Yellow" })

# Détails des anomalies
if ($threadsZero.Count -gt 0) {
    Write-Host "`n❌ COLLECTIONS AVEC THREADS=0 (À CORRIGER):" -ForegroundColor Red
    $threadsZero | Format-Table -AutoSize Name, Threads, @{L="Points";E={$_.Points.ToString("N0")}}, Segments
}

if ($threadsOther.Count -gt 0) {
    Write-Host "`n⚠️  COLLECTIONS AVEC THREADS DIFFÉRENT DE 16:" -ForegroundColor Yellow
    $threadsOther | Format-Table -AutoSize Name, Threads, @{L="Points";E={$_.Points.ToString("N0")}}, Segments
}

# TOP 10 collections corrigées (par volumétrie)
if ($threads16.Count -gt 0) {
    Write-Host "`n✅ TOP 10 COLLECTIONS CORRIGÉES (par volumétrie):" -ForegroundColor Green
    $threads16 | Sort-Object Points -Descending | Select-Object -First 10 | Format-Table -AutoSize Name, Threads, @{L="Points";E={$_.Points.ToString("N0")}}, Segments
}

# Verdict final
Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
if ($threadsZero.Count -eq 0 -and $threadsOther.Count -eq 0) {
    Write-Host "✅ SUCCÈS: Toutes les collections sont à threads=16" -ForegroundColor Green
    Write-Host "Recommandation: Redémarrer Qdrant pour optimisation complète" -ForegroundColor Cyan
    exit 0
}
else {
    Write-Host "❌ ÉCHEC: Des collections nécessitent encore une correction" -ForegroundColor Red
    Write-Host "Collections problématiques: $($threadsZero.Count + $threadsOther.Count)" -ForegroundColor Red
    exit 1
}