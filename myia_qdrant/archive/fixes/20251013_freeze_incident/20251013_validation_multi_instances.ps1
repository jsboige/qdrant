# ===================================================================
# SCRIPT DE VALIDATION MULTI-INSTANCES - FIX HEAP MCP (4096 MB)
# ===================================================================
# Date: 2025-10-13
# Objectif: Valider l'efficacité du fix sous charge réelle (4 instances VS Code)
# ===================================================================

param(
    [int]$MonitoringDuration = 30,  # Durée du monitoring temps réel (secondes)
    [int]$PerformanceTests = 10     # Nombre de tests de performance
)

$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::UTF8

# Couleurs pour le rapport
function Write-Section {
    param([string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠️ $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

# ===================================================================
# PHASE 1: VÉRIFICATION INSTANCES MULTIPLES
# ===================================================================

Write-Section "PHASE 1: VÉRIFICATION INSTANCES MULTIPLES"

# 1.1 Compter les Instances VS Code Actives
Write-Host "1.1 Comptage instances VS Code..." -ForegroundColor Yellow
$vscodeProcesses = Get-Process Code -ErrorAction SilentlyContinue
$vscodeCount = $vscodeProcesses.Count
Write-Host "Nombre d'instances VS Code: $vscodeCount" -ForegroundColor $(if ($vscodeCount -ge 4) { 'Green' } else { 'Yellow' })
Write-Host ""
$vscodeProcesses | Select-Object Id, StartTime, @{Name='WorkingSet_MB';Expression={[math]::Round($_.WorkingSet64 / 1MB, 2)}} | Format-Table -AutoSize

# 1.2 Vérifier TOUS les Processus MCP roo-state-manager
Write-Host "`n1.2 Analyse processus MCP roo-state-manager..." -ForegroundColor Yellow
$mcpProcesses = Get-Process node -ErrorAction SilentlyContinue | Where-Object { 
    $_.Path -and (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like '*roo-state-manager*'
}

$mcpCount = $mcpProcesses.Count
Write-Host "Nombre de processus MCP: $mcpCount" -ForegroundColor $(if ($mcpCount -ge 4) { 'Green' } else { 'Yellow' })
Write-Host ""

$mcpWithHeap = 0
$mcpWithoutHeap = 0
$mcpDetails = @()

foreach ($proc in $mcpProcesses) {
    $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
    $hasHeapArg = $cmdLine -like '*--max-old-space-size=4096*'
    
    if ($hasHeapArg) {
        $mcpWithHeap++
        $status = "✅ HEAP 4096"
        $color = 'Green'
    } else {
        $mcpWithoutHeap++
        $status = "❌ PAS DE HEAP"
        $color = 'Red'
    }
    
    $memMB = [math]::Round($proc.WorkingSet64 / 1MB, 2)
    Write-Host "PID: $($proc.Id) | Mem: $memMB MB | $status" -ForegroundColor $color
    
    $mcpDetails += [PSCustomObject]@{
        PID = $proc.Id
        Memory_MB = $memMB
        HasHeapFix = $hasHeapArg
        StartTime = $proc.StartTime
    }
}

# 1.3 Détecter Processus MCP SANS Heap Fix (CRITIQUE)
Write-Host "`n1.3 Audit processus MCP sans fix..." -ForegroundColor Yellow
if ($mcpWithoutHeap -gt 0) {
    Write-Error "ATTENTION: $mcpWithoutHeap processus MCP SANS heap fix détectés"
    Write-Error "ACTION REQUISE: Certaines instances VS Code n'ont pas le fix heap"
} else {
    Write-Success "TOUS les processus MCP ont le heap fix (4096 MB)"
}

# ===================================================================
# PHASE 2: MONITORING SOUS CHARGE RÉELLE
# ===================================================================

Write-Section "PHASE 2: MONITORING SOUS CHARGE RÉELLE"

# 2.1 Baseline Erreurs HTTP 400
Write-Host "2.1 Baseline erreurs HTTP 400..." -ForegroundColor Yellow
Write-Host ""
Write-Host "Dernière 1h (avant relance complète):" -ForegroundColor Yellow
$errors1h = docker logs qdrant_production --since 1h --until '2025-10-13T23:53:00' 2>&1 | Select-String '400' | Measure-Object | Select-Object -ExpandProperty Count
Write-Host "Erreurs: $errors1h" -ForegroundColor $(if ($errors1h -eq 0) { 'Green' } else { 'Red' })

Write-Host ""
Write-Host "Dernières 5 minutes (après relance 4 instances):" -ForegroundColor Green
$errors5m = docker logs qdrant_production --since 5m 2>&1 | Select-String '400' | Measure-Object | Select-Object -ExpandProperty Count
Write-Host "Erreurs: $errors5m" -ForegroundColor $(if ($errors5m -eq 0) { 'Green' } else { 'Red' })

Write-Host ""
if ($errors5m -gt 0) {
    Write-Warning "Des erreurs 400 sont réapparues après relance des 4 instances"
    Write-Warning "Cela pourrait indiquer que certaines instances n'ont pas le heap fix"
} else {
    Write-Success "Aucune erreur 400 détectée sous charge 4 instances"
}

# 2.2 Monitoring Temps Réel
Write-Host "`n2.2 Monitoring temps réel ($MonitoringDuration secondes)..." -ForegroundColor Yellow
Write-Host "Surveillance erreurs HTTP 400 en temps réel..." -ForegroundColor Yellow
Write-Host ""

$startTime = Get-Date
$endTime = $startTime.AddSeconds($MonitoringDuration)
$errorCount = 0
$errorDetails = @()

while ((Get-Date) -lt $endTime) {
    $recentErrors = docker logs qdrant_production --since 5s 2>&1 | Select-String '400'
    if ($recentErrors) {
        $errorCount += ($recentErrors | Measure-Object).Count
        $timestamp = Get-Date -Format 'HH:mm:ss'
        Write-Host "[$timestamp] +$($recentErrors.Count) erreurs détectées" -ForegroundColor Red
        $recentErrors | ForEach-Object { 
            Write-Host "  $_" -ForegroundColor DarkRed
            $errorDetails += $_
        }
    }
    Start-Sleep 5
}

Write-Host ""
Write-Host "Total erreurs 400 en $MonitoringDuration secondes: $errorCount" -ForegroundColor $(if ($errorCount -eq 0) { 'Green' } else { 'Red' })
if ($errorCount -gt 0) {
    Write-Error "Le fix heap ne semble pas efficace avec 4 instances"
} else {
    Write-Success "Aucune erreur pendant ${MonitoringDuration}s avec 4 instances actives"
}

# 2.3 Performance Qdrant Sous Charge
Write-Host "`n2.3 Performance Qdrant sous charge ($PerformanceTests tests)..." -ForegroundColor Yellow
$measures = @()
$apiKey = $env:QDRANT_API_KEY

for ($i = 1; $i -le $PerformanceTests; $i++) {
    $elapsed = Measure-Command { 
        curl -s "http://localhost:6333/collections" -H "api-key: $apiKey" | Out-Null 
    }
    $measures += $elapsed.TotalMilliseconds
    Write-Host "Requête $i : $([math]::Round($elapsed.TotalMilliseconds, 2)) ms"
    Start-Sleep -Milliseconds 500
}

$avg = ($measures | Measure-Object -Average).Average
$max = ($measures | Measure-Object -Maximum).Maximum
$min = ($measures | Measure-Object -Minimum).Maximum

Write-Host ""
Write-Host "Moyenne: $([math]::Round($avg, 2)) ms" -ForegroundColor $(if ($avg -lt 100) { 'Green' } elseif ($avg -lt 500) { 'Yellow' } else { 'Red' })
Write-Host "Maximum: $([math]::Round($max, 2)) ms" -ForegroundColor $(if ($max -lt 200) { 'Green' } elseif ($max -lt 1000) { 'Yellow' } else { 'Red' })
Write-Host "Minimum: $([math]::Round($min, 2)) ms" -ForegroundColor Green

if ($avg -gt 500) {
    Write-Warning "Latence élevée détectée sous charge 4 instances"
}

# ===================================================================
# PHASE 3: ÉTAT COLLECTION SOUS CHARGE
# ===================================================================

Write-Section "PHASE 3: ÉTAT COLLECTION SOUS CHARGE"

# 3.1 Collection Status
Write-Host "3.1 Collection roo_tasks_semantic_index status..." -ForegroundColor Yellow
try {
    $result = curl -s -H "api-key: $apiKey" "http://localhost:6333/collections/roo_tasks_semantic_index" | ConvertFrom-Json | Select-Object -ExpandProperty result
    Write-Host "Status: $($result.status)" -ForegroundColor $(if ($result.status -eq 'green') { 'Green' } else { 'Red' })
    Write-Host "Points: $($result.points_count)" -ForegroundColor Green
    Write-Host "Indexed: $($result.indexed_vectors_count)" -ForegroundColor Green
    Write-Host "Segments: $($result.segments_count)" -ForegroundColor Green
    Write-Host "Max Indexing Threads: $($result.config.hnsw_config.max_indexing_threads)" -ForegroundColor Green
} catch {
    Write-Error "Impossible de récupérer le status de la collection: $_"
}

# 3.2 Activité d'Indexation Récente
Write-Host "`n3.2 Activité d'indexation récente..." -ForegroundColor Yellow
docker logs qdrant_production --since 5m 2>&1 | Select-String -Pattern 'roo_tasks_semantic_index|upsert|index' -CaseSensitive:$false | Select-Object -Last 10

# ===================================================================
# PHASE 4: VÉRIFICATION CONFIGURATION MULTI-INSTANCES
# ===================================================================

Write-Section "PHASE 4: VÉRIFICATION CONFIGURATION MULTI-INSTANCES"

# 4.1 Auditer mcp_settings.json
Write-Host "4.1 Audit configuration MCP..." -ForegroundColor Yellow
$configPath = 'C:\Users\MYIA\AppData\Roaming\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json'
if (Test-Path $configPath) {
    Write-Host "Configuration trouvée: $configPath" -ForegroundColor Green
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $heapArg = $config.mcpServers.'roo-state-manager'.args | Where-Object { $_ -like '*max-old-space-size*' }
        if ($heapArg) {
            Write-Success "Heap configuré: $heapArg"
        } else {
            Write-Error "Heap NON configuré dans mcp_settings.json"
        }
    } catch {
        Write-Error "Erreur lors de la lecture de mcp_settings.json: $_"
    }
} else {
    Write-Error "Fichier mcp_settings.json introuvable à: $configPath"
}

# ===================================================================
# RAPPORT FINAL
# ===================================================================

Write-Section "RAPPORT FINAL - VALIDATION MULTI-INSTANCES"

Write-Host "=== SECTION 1: VALIDATION INSTANCES MULTIPLES ===" -ForegroundColor Cyan
Write-Host "Instances VS Code actives: $vscodeCount"
Write-Host "Processus MCP roo-state-manager: $mcpCount"
Write-Host "Processus MCP avec heap fix (4096 MB): $mcpWithHeap" -ForegroundColor $(if ($mcpWithHeap -eq $mcpCount) { 'Green' } else { 'Red' })
Write-Host "Processus MCP sans heap fix (CRITIQUE): $mcpWithoutHeap" -ForegroundColor $(if ($mcpWithoutHeap -eq 0) { 'Green' } else { 'Red' })

Write-Host "`n=== SECTION 2: MONITORING SOUS CHARGE RÉELLE ===" -ForegroundColor Cyan
Write-Host "Erreurs HTTP 400 (dernière 1h): $errors1h"
Write-Host "Erreurs HTTP 400 (5 dernières minutes): $errors5m" -ForegroundColor $(if ($errors5m -eq 0) { 'Green' } else { 'Red' })
Write-Host "Erreurs monitoring temps réel (${MonitoringDuration}s): $errorCount" -ForegroundColor $(if ($errorCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "Performance Qdrant moyenne: $([math]::Round($avg, 2)) ms" -ForegroundColor $(if ($avg -lt 100) { 'Green' } elseif ($avg -lt 500) { 'Yellow' } else { 'Red' })
Write-Host "Performance Qdrant maximum: $([math]::Round($max, 2)) ms" -ForegroundColor $(if ($max -lt 200) { 'Green' } elseif ($max -lt 1000) { 'Yellow' } else { 'Red' })

Write-Host "`n=== SECTION 3: VERDICT FINAL ===" -ForegroundColor Cyan
$successCriteria = @{
    AllMcpWithHeap = $mcpWithoutHeap -eq 0
    NoErrors = $errorCount -eq 0 -and $errors5m -eq 0
    GoodPerformance = $avg -lt 100
    FourInstances = $vscodeCount -ge 4
}

$overallSuccess = $successCriteria.Values | Where-Object { $_ -eq $false } | Measure-Object | Select-Object -ExpandProperty Count

if ($overallSuccess -eq 0) {
    Write-Host "✅ FIX EFFICACE AVEC 4 INSTANCES" -ForegroundColor Green -BackgroundColor DarkGreen
    Write-Host "   - Aucune erreur détectée"
    Write-Host "   - Tous les processus MCP stables avec heap fix"
    Write-Host "   - Performance optimale (<100ms)"
} elseif ($overallSuccess -le 2) {
    Write-Host "⚠️ PROBLÈME PARTIEL" -ForegroundColor Yellow -BackgroundColor DarkYellow
    if (-not $successCriteria.AllMcpWithHeap) {
        Write-Host "   - Certains processus MCP sans heap fix"
    }
    if (-not $successCriteria.NoErrors) {
        Write-Host "   - Quelques erreurs détectées"
    }
    if (-not $successCriteria.GoodPerformance) {
        Write-Host "   - Performance dégradée"
    }
} else {
    Write-Host "❌ FIX INEFFICACE" -ForegroundColor Red -BackgroundColor DarkRed
    Write-Host "   - Erreurs massives ou processus instables"
    Write-Host "   - Performance très dégradée"
}

Write-Host "`n=== SECTION 4: ACTIONS CORRECTIVES ===" -ForegroundColor Cyan
if ($mcpWithoutHeap -gt 0 -or $errorCount -gt 0) {
    Write-Warning "Actions recommandées:"
    Write-Host "1. Identifier quelles instances VS Code n'ont pas le fix"
    Write-Host "2. Fermer et relancer ces instances spécifiques"
    Write-Host "3. Vérifier que mcp_settings.json est bien partagé entre instances"
    Write-Host "4. Surveiller les erreurs pendant 1 heure après correction"
} else {
    Write-Success "Aucune action corrective nécessaire"
}

Write-Host "`n=== SECTION 5: RECOMMANDATION ===" -ForegroundColor Cyan
Write-Host "Monitoring continu requis pour les prochaines 24 heures:" -ForegroundColor Yellow
Write-Host "- Validation progressive: 1h, 6h, 24h"
Write-Host "- Alerte immédiate si erreurs HTTP 400 réapparaissent"
Write-Host "- Surveillance mémoire des processus MCP"

# Résumé des critères de succès
Write-Host "`n=== CRITÈRES DE SUCCÈS SOUS CHARGE ===" -ForegroundColor Cyan
Write-Host "✓ 4 instances VS Code actives: $(if ($vscodeCount -ge 4) { 'OUI' } else { 'NON' })" -ForegroundColor $(if ($vscodeCount -ge 4) { 'Green' } else { 'Red' })
Write-Host "✓ Tous les processus MCP avec heap 4096 MB: $(if ($mcpWithoutHeap -eq 0) { 'OUI' } else { 'NON' })" -ForegroundColor $(if ($mcpWithoutHeap -eq 0) { 'Green' } else { 'Red' })
Write-Host "✓ 0 erreur HTTP 400 pendant monitoring: $(if ($errorCount -eq 0) { 'OUI' } else { 'NON' })" -ForegroundColor $(if ($errorCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "✓ Performance Qdrant <100 ms moyenne: $(if ($avg -lt 100) { 'OUI' } else { 'NON' })" -ForegroundColor $(if ($avg -lt 100) { 'Green' } else { 'Red' })

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FIN DU RAPPORT DE VALIDATION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan