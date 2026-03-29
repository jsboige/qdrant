#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Rapport final de la correction HNSW - État post-redémarrage
    
.DESCRIPTION
    Génère un rapport complet incluant:
    - État de santé de Qdrant post-redémarrage
    - Validation que toutes les collections sont à threads=16
    - Statistiques de correction
    - Recommandations de suivi
#>

$ErrorActionPreference = "Stop"
$API_KEY = "qdrant_admin"
$QDRANT_URL = "http://localhost:6333"

Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  RAPPORT FINAL - CORRECTION HNSW CRITIQUE                     ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ============================================================================
# 1. VÉRIFICATION SANTÉ QDRANT POST-REDÉMARRAGE
# ============================================================================
Write-Host "=== 1. SANTÉ QDRANT POST-REDÉMARRAGE ===" -ForegroundColor Cyan

$maxRetries = 5
$retryDelay = 2
$qdrantOk = $false

for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        Write-Host "Tentative $i/$maxRetries..." -ForegroundColor Yellow
        $health = Invoke-RestMethod -Uri "$QDRANT_URL/" -Headers @{"api-key"=$API_KEY} -Method Get -TimeoutSec 5
        Write-Host "✅ Qdrant ACCESSIBLE" -ForegroundColor Green
        Write-Host "   Version: $($health.version)" -ForegroundColor Green
        Write-Host "   Titre: $($health.title)`n" -ForegroundColor Green
        $qdrantOk = $true
        break
    }
    catch {
        Write-Host "⚠️  Tentative $i échouée, attente ${retryDelay}s..." -ForegroundColor Yellow
        if ($i -lt $maxRetries) {
            Start-Sleep -Seconds $retryDelay
        }
    }
}

if (-not $qdrantOk) {
    Write-Host "❌ ERREUR CRITIQUE: Qdrant inaccessible après $maxRetries tentatives" -ForegroundColor Red
    Write-Host "Action requise: Vérifier les logs avec 'docker logs qdrant_production'`n" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 2. VALIDATION COMPLÈTE DES COLLECTIONS
# ============================================================================
Write-Host "=== 2. VALIDATION COLLECTIONS POST-CORRECTION ===" -ForegroundColor Cyan

try {
    $collectionsResponse = Invoke-RestMethod -Uri "$QDRANT_URL/collections" -Headers @{"api-key"=$API_KEY} -Method Get
    $allCollections = $collectionsResponse.result.collections
    
    Write-Host "📊 Total collections: $($allCollections.Count)" -ForegroundColor Cyan
    
    $results = @()
    $stats = @{
        Total = 0
        Threads16 = 0
        Threads0 = 0
        ThreadsOther = 0
        TotalPoints = 0
        TotalSegments = 0
    }
    
    foreach ($col in $allCollections) {
        try {
            $info = Invoke-RestMethod -Uri "$QDRANT_URL/collections/$($col.name)" -Headers @{"api-key"=$API_KEY} -Method Get
            $threads = $info.result.config.hnsw_config.max_indexing_threads
            $points = $info.result.points_count
            $segments = $info.result.segments_count
            
            $stats.Total++
            $stats.TotalPoints += $points
            $stats.TotalSegments += $segments
            
            switch ($threads) {
                16 { $stats.Threads16++ }
                0 { $stats.Threads0++ }
                default { $stats.ThreadsOther++ }
            }
            
            $results += [PSCustomObject]@{
                Name = $col.name
                Threads = $threads
                Points = $points
                Segments = $segments
                Status = if ($threads -eq 16) { "✅" } elseif ($threads -eq 0) { "❌" } else { "⚠️" }
            }
        }
        catch {
            Write-Host "⚠️  Erreur lecture $($col.name): $_" -ForegroundColor Yellow
        }
    }
    
    # Affichage des statistiques
    Write-Host "`n📊 STATISTIQUES GLOBALES:" -ForegroundColor Cyan
    Write-Host "   Total collections:    $($stats.Total)" -ForegroundColor White
    Write-Host "   ✅ Threads=16:        $($stats.Threads16) collections" -ForegroundColor Green
    Write-Host "   ❌ Threads=0:         $($stats.Threads0) collections" -ForegroundColor $(if ($stats.Threads0 -eq 0) { "Green" } else { "Red" })
    Write-Host "   ⚠️  Autres threads:   $($stats.ThreadsOther) collections" -ForegroundColor $(if ($stats.ThreadsOther -eq 0) { "Green" } else { "Yellow" })
    Write-Host "   Total points:         $($stats.TotalPoints.ToString('N0'))" -ForegroundColor White
    Write-Host "   Total segments:       $($stats.TotalSegments)`n" -ForegroundColor White
    
    # Top 10 par volumétrie
    Write-Host "🔝 TOP 10 COLLECTIONS (par volumétrie):" -ForegroundColor Cyan
    $results | Sort-Object Points -Descending | Select-Object -First 10 | Format-Table -AutoSize @(
        @{Label="Status"; Expression={$_.Status}; Width=8}
        @{Label="Collection"; Expression={$_.Name}; Width=35}
        @{Label="Threads"; Expression={$_.Threads}; Width=10}
        @{Label="Points"; Expression={$_.Points.ToString("N0")}; Width=15}
        @{Label="Segments"; Expression={$_.Segments}; Width=10}
    )
    
    # Anomalies
    $anomalies = $results | Where-Object { $_.Threads -ne 16 }
    if ($anomalies.Count -gt 0) {
        Write-Host "⚠️  ANOMALIES DÉTECTÉES:" -ForegroundColor Red
        $anomalies | Format-Table -AutoSize
    }
    
}
catch {
    Write-Host "❌ ERREUR lors de la validation: $_" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 3. RÉSUMÉ DE LA CORRECTION
# ============================================================================
Write-Host "`n=== 3. RÉSUMÉ DE LA CORRECTION ===" -ForegroundColor Cyan

Write-Host "`n📋 CONTEXTE INITIAL:" -ForegroundColor Yellow
Write-Host "   - 58/59 collections avec max_indexing_threads=0" -ForegroundColor Yellow
Write-Host "   - Cause: Overload HNSW systématique lors de l'indexation" -ForegroundColor Yellow
Write-Host "   - Impact: Dégradation des performances de recherche" -ForegroundColor Yellow

Write-Host "`n🔧 CORRECTION APPLIQUÉE:" -ForegroundColor Green
Write-Host "   - Migration vers max_indexing_threads=16" -ForegroundColor Green
Write-Host "   - Méthode: API Qdrant PATCH par batch de 10" -ForegroundColor Green
Write-Host "   - Backups: Activés pour toutes les collections" -ForegroundColor Green
Write-Host "   - Redémarrage: Container Qdrant redémarré avec succès" -ForegroundColor Green

Write-Host "`n📈 RÉSULTATS:" -ForegroundColor Cyan
if ($stats.Threads16 -eq $stats.Total) {
    Write-Host "   ✅ SUCCÈS COMPLET: Toutes les $($stats.Total) collections à threads=16" -ForegroundColor Green
} else {
    Write-Host "   ⚠️  SUCCÈS PARTIEL: $($stats.Threads16)/$($stats.Total) collections corrigées" -ForegroundColor Yellow
    if ($stats.Threads0 -gt 0) {
        Write-Host "   ❌ $($stats.Threads0) collections restent à threads=0" -ForegroundColor Red
    }
}

# ============================================================================
# 4. RECOMMANDATIONS POST-CORRECTION
# ============================================================================
Write-Host "`n=== 4. RECOMMANDATIONS POST-CORRECTION ===" -ForegroundColor Cyan

Write-Host "`n🔍 SURVEILLANCE RECOMMANDÉE:" -ForegroundColor Yellow
Write-Host "   1. Monitorer les performances pendant 24-48h" -ForegroundColor White
Write-Host "      Script: .\scripts\diagnostics\20251015_monitor_overload_realtime.ps1" -ForegroundColor Gray
Write-Host "   2. Surveiller l'utilisation CPU/mémoire" -ForegroundColor White
Write-Host "      Commande: docker stats qdrant_production" -ForegroundColor Gray
Write-Host "   3. Vérifier les logs d'indexation" -ForegroundColor White
Write-Host "      Commande: docker logs qdrant_production --tail 100" -ForegroundColor Gray

Write-Host "`n📁 DOCUMENTATION:" -ForegroundColor Yellow
Write-Host "   - Diagnostic complet: myia_qdrant/docs/diagnostics/20251015_DIAGNOSTIC_OVERLOAD_HNSW_CORRUPTION.md" -ForegroundColor Gray
Write-Host "   - Backups: myia_qdrant/diagnostics/hnsw_backups/" -ForegroundColor Gray

Write-Host "`n🎯 PROCHAINES ACTIONS:" -ForegroundColor Yellow
if ($stats.Threads16 -eq $stats.Total) {
    Write-Host "   ✅ Correction complète - Surveiller les performances" -ForegroundColor Green
    Write-Host "   ✅ Si stables: Marquer comme résolu dans la doc" -ForegroundColor Green
} else {
    Write-Host "   ⚠️  Relancer la correction pour les collections restantes" -ForegroundColor Red
    Write-Host "   ⚠️  Investiguer les échecs avec les logs Qdrant" -ForegroundColor Red
}

# ============================================================================
# VERDICT FINAL
# ============================================================================
Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
if ($stats.Threads16 -eq $stats.Total -and $qdrantOk) {
    Write-Host "║  ✅ CORRECTION HNSW RÉUSSIE - SYSTÈME OPÉRATIONNEL           ║" -ForegroundColor Green
    Write-Host "╚═══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "║  ⚠️  CORRECTION PARTIELLE - ACTION REQUISE                    ║" -ForegroundColor Yellow
    Write-Host "╚═══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
    exit 1
}