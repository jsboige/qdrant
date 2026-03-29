#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    🚨 CORRECTION URGENTE IMMÉDIATE - Exécution complète automatisée

.DESCRIPTION
    Script wrapper qui exécute la correction HNSW complète en mode automatique:
    1. Validation rapide de l'accessibilité Qdrant
    2. Simulation DryRun express (skip si confiance)
    3. Correction réelle des 58 collections
    4. Redémarrage Qdrant
    5. Validation finale

.PARAMETER SkipDryRun
    Ignore la simulation et lance directement la correction (DANGEREUX)

.PARAMETER SmallBatch
    Utilise des petits batch (5 au lieu de 10) pour plus de stabilité

.EXAMPLE
    .\20251015_URGENCE_fix_now.ps1
    .\20251015_URGENCE_fix_now.ps1 -SkipDryRun -SmallBatch
#>

param(
    [switch]$SkipDryRun,
    [switch]$SmallBatch
)

$ErrorActionPreference = "Continue"
$ColorCritical = "Red"
$ColorWarning = "Yellow"
$ColorSuccess = "Green"
$ColorInfo = "Cyan"

$BATCH_SIZE = if ($SmallBatch) { 5 } else { 10 }

function Write-Banner {
    param([string]$Text, [string]$Color = $ColorInfo)
    Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor $Color
    Write-Host "║  $($Text.PadRight(61))║" -ForegroundColor $Color
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor $Color
}

Write-Banner "🚨 CORRECTION URGENTE HNSW - MODE AUTOMATIQUE" $ColorCritical

Write-Host "`n⚠️  Ce script va:" -ForegroundColor $ColorWarning
Write-Host "  1. Corriger 58 collections (threads: 0 → 16)"
Write-Host "  2. Redémarrer Qdrant automatiquement"
Write-Host "  3. Valider la correction"
Write-Host ""

$startTime = Get-Date

# ============================================================================
# ÉTAPE 1: Validation initiale
# ============================================================================

Write-Banner "ÉTAPE 1/5: Validation Qdrant" $ColorInfo

$qdrantUp = $false
try {
    $null = curl -s -H "api-key: qdrant_admin" http://localhost:6333/ 2>&1
    $qdrantUp = $LASTEXITCODE -eq 0
} catch {
    $qdrantUp = $false
}

if (-not $qdrantUp) {
    Write-Host "❌ Qdrant inaccessible - Démarrage du container..." -ForegroundColor $ColorCritical
    docker-compose -f docker-compose.production.yml up -d
    Start-Sleep -Seconds 10
    
    try {
        $null = curl -s -H "api-key: qdrant_admin" http://localhost:6333/ 2>&1
        $qdrantUp = $LASTEXITCODE -eq 0
    } catch {
        $qdrantUp = $false
    }
    
    if (-not $qdrantUp) {
        Write-Host "❌ ÉCHEC: Container ne démarre pas" -ForegroundColor $ColorCritical
        exit 1
    }
}

Write-Host "✅ Qdrant accessible" -ForegroundColor $ColorSuccess

# ============================================================================
# ÉTAPE 2: Simulation (optionnelle)
# ============================================================================

if (-not $SkipDryRun) {
    Write-Banner "ÉTAPE 2/5: Simulation DryRun (rapide)" $ColorInfo
    
    Write-Host "Lancement simulation..." -ForegroundColor $ColorInfo
    $dryRunResult = & ".\scripts\diagnostics\20251015_fix_hnsw_corruption_batch.ps1" -DryRun -BatchSize $BATCH_SIZE
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "⚠️  Simulation a rencontré des avertissements" -ForegroundColor $ColorWarning
        Write-Host "Voulez-vous continuer quand même? (OUI/non)" -ForegroundColor $ColorWarning
        $response = Read-Host
        if ($response -ne "OUI") {
            Write-Host "❌ Annulé par l'utilisateur" -ForegroundColor $ColorCritical
            exit 1
        }
    } else {
        Write-Host "✅ Simulation réussie" -ForegroundColor $ColorSuccess
    }
} else {
    Write-Host "⚠️  SIMULATION IGNORÉE (SkipDryRun activé)" -ForegroundColor $ColorWarning
}

# ============================================================================
# ÉTAPE 3: Correction réelle
# ============================================================================

Write-Banner "ÉTAPE 3/5: CORRECTION RÉELLE (Production)" $ColorCritical

Write-Host "⚠️  DERNIÈRE CHANCE D'ANNULER" -ForegroundColor $ColorCritical
Write-Host "Appuyez sur ENTRÉE pour continuer ou Ctrl+C pour annuler..." -ForegroundColor $ColorWarning
$null = Read-Host

Write-Host "`nLancement correction..." -ForegroundColor $ColorInfo
& ".\scripts\diagnostics\20251015_fix_hnsw_corruption_batch.ps1" -BatchSize $BATCH_SIZE -Force

$fixExitCode = $LASTEXITCODE

if ($fixExitCode -ne 0) {
    Write-Host "⚠️  Correction terminée avec des avertissements (code: $fixExitCode)" -ForegroundColor $ColorWarning
    Write-Host "Voulez-vous continuer avec le redémarrage? (OUI/non)" -ForegroundColor $ColorWarning
    $response = Read-Host
    if ($response -ne "OUI") {
        Write-Host "❌ Arrêté avant redémarrage" -ForegroundColor $ColorWarning
        exit $fixExitCode
    }
} else {
    Write-Host "✅ Correction réussie" -ForegroundColor $ColorSuccess
}

# ============================================================================
# ÉTAPE 4: Redémarrage Qdrant
# ============================================================================

Write-Banner "ÉTAPE 4/5: Redémarrage Qdrant" $ColorInfo

Write-Host "Arrêt du container..." -ForegroundColor $ColorInfo
docker-compose -f docker-compose.production.yml stop

Write-Host "Démarrage du container..." -ForegroundColor $ColorInfo
docker-compose -f docker-compose.production.yml up -d

Write-Host "Attente stabilisation (15s)..." -ForegroundColor $ColorInfo
Start-Sleep -Seconds 15

# Vérification container démarré
$attempts = 0
$maxAttempts = 6
$started = $false

while ($attempts -lt $maxAttempts -and -not $started) {
    $attempts++
    Write-Host "  Vérification ($attempts/$maxAttempts)..." -ForegroundColor $ColorInfo
    
    try {
        $null = curl -s -H "api-key: qdrant_admin" http://localhost:6333/ 2>&1
        if ($LASTEXITCODE -eq 0) {
            $started = $true
        } else {
            Start-Sleep -Seconds 5
        }
    } catch {
        Start-Sleep -Seconds 5
    }
}

if (-not $started) {
    Write-Host "❌ Container ne redémarre pas correctement" -ForegroundColor $ColorCritical
    Write-Host "Vérifiez manuellement: docker logs qdrant_production --tail 50" -ForegroundColor $ColorWarning
    exit 1
}

Write-Host "✅ Container redémarré" -ForegroundColor $ColorSuccess

# ============================================================================
# ÉTAPE 5: Validation finale
# ============================================================================

Write-Banner "ÉTAPE 5/5: Validation Finale" $ColorInfo

Write-Host "Vérification configuration des collections..." -ForegroundColor $ColorInfo

try {
    $collections = curl -s -H "api-key: qdrant_admin" http://localhost:6333/collections | ConvertFrom-Json | Select-Object -ExpandProperty result | Select-Object -ExpandProperty collections
    
    $threadsZero = 0
    $threadsOk = 0
    $total = 0
    
    foreach ($col in $collections) {
        $total++
        try {
            $info = curl -s -H "api-key: qdrant_admin" "http://localhost:6333/collections/$($col.name)" | ConvertFrom-Json | Select-Object -ExpandProperty result
            
            if ($info.config.hnsw_config.max_indexing_threads -eq 0) {
                $threadsZero++
            } else {
                $threadsOk++
            }
        } catch {
            Write-Host "  ⚠️  Erreur lecture $($col.name)" -ForegroundColor $ColorWarning
        }
    }
    
    Write-Host "`n📊 RÉSULTATS:" -ForegroundColor $ColorInfo
    Write-Host "  Total collections:        $total"
    Write-Host "  ✅ threads > 0:           $threadsOk" -ForegroundColor $ColorSuccess
    Write-Host "  ❌ threads = 0 restants:  $threadsZero" -ForegroundColor $(if ($threadsZero -eq 0) { $ColorSuccess } else { $ColorCritical })
    
    if ($threadsZero -eq 0) {
        Write-Host "`n🎉 CORRECTION 100% RÉUSSIE!" -ForegroundColor $ColorSuccess
    } elseif ($threadsZero -lt 10) {
        Write-Host "`n✅ Correction majoritairement réussie ($([math]::Round($threadsOk/$total*100,1))%)" -ForegroundColor $ColorSuccess
        Write-Host "⚠️  $threadsZero collections nécessitent une correction manuelle" -ForegroundColor $ColorWarning
    } else {
        Write-Host "`n⚠️  Correction partielle uniquement" -ForegroundColor $ColorWarning
        Write-Host "❌ $threadsZero collections ont encore threads=0" -ForegroundColor $ColorCritical
    }
    
} catch {
    Write-Host "⚠️  Erreur validation: $_" -ForegroundColor $ColorWarning
}

# ============================================================================
# RAPPORT FINAL
# ============================================================================

$duration = (Get-Date) - $startTime

Write-Banner "RAPPORT FINAL" $ColorSuccess

Write-Host "`n⏱️  Durée totale: $($duration.ToString('mm\:ss'))" -ForegroundColor $ColorInfo

Write-Host "`n✅ PROCHAINES ACTIONS:" -ForegroundColor $ColorSuccess
Write-Host "  1. Testez l'indexation de plusieurs workspaces Roo"
Write-Host "  2. Surveillez les performances pendant 1h"
Write-Host "  3. Si toujours des problèmes, lancez le monitoring:"
Write-Host "     .\scripts\diagnostics\20251015_monitor_overload_realtime.ps1 -ContinuousMode"

Write-Host "`n📁 BACKUPS:" -ForegroundColor $ColorInfo
Write-Host "  Les backups de configuration sont dans:"
Write-Host "  myia_qdrant/diagnostics/hnsw_backups/"

Write-Host "`n📝 LOGS:" -ForegroundColor $ColorInfo
Write-Host "  Pour vérifier les logs Qdrant:"
Write-Host "  docker logs qdrant_production --tail 100 -f"

Write-Host ""
exit $(if ($threadsZero -lt 5) { 0 } else { 1 })