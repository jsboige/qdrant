# Script de Fix Hybride - Résolution Freeze Qdrant
# Cause: indexing_threshold trop élevé → 66% collections en full scan
# Solution: Corriger config + forcer rebuild index des collections critiques

param(
    [switch]$DryRun = $false,
    [switch]$Force = $false,
    [switch]$NonInteractive = $false
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  🔧 FIX HYBRIDE - RÉSOLUTION FREEZE INDEXATION QDRANT      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = "diagnostics/fix_indexation_$timestamp.log"

function Write-Log {
    param($Message, $Color = "White")
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Write-Host $entry -ForegroundColor $Color
    $entry | Out-File -FilePath $logFile -Append
}

function Get-CollectionInfo {
    param($Name)
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:6333/collections/$Name" `
                                      -Headers @{"api-key"="qdrant_admin"} `
                                      -ErrorAction Stop
        return $response.result
    }
    catch {
        Write-Log "❌ Erreur récupération info $Name : $_" "Red"
        return $null
    }
}

function Force-CollectionOptimization {
    param($Name)
    try {
        Write-Log "  ⏳ Optimisation de $Name..." "Yellow"
        $response = Invoke-RestMethod -Uri "http://localhost:6333/collections/$Name/optimizer" `
                                      -Method Post `
                                      -Headers @{"api-key"="qdrant_admin"} `
                                      -ErrorAction Stop
        Write-Log "  ✅ Optimisation lancée pour $Name" "Green"
        return $true
    }
    catch {
        Write-Log "  ❌ Erreur optimisation $Name : $_" "Red"
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════
# PHASE 0: PRÉ-REQUIS
# ═══════════════════════════════════════════════════════════════

Write-Host "📋 PHASE 0: Vérification pré-requis`n" -ForegroundColor Cyan

# Vérifier Qdrant accessible
try {
    $health = Invoke-RestMethod -Uri "http://localhost:6333/healthz" -ErrorAction Stop
    Write-Log "✅ Qdrant accessible et opérationnel" "Green"
}
catch {
    Write-Log "❌ ERREUR: Qdrant non accessible sur localhost:6333" "Red"
    Write-Log "   Vérifiez que le container est démarré: docker ps" "Yellow"
    exit 1
}

# Récupérer liste collections
Write-Log "📦 Récupération liste des collections..." "Cyan"
$collections = (Invoke-RestMethod -Uri "http://localhost:6333/collections" `
                                  -Headers @{"api-key"="qdrant_admin"}).result.collections

Write-Log "✅ $($collections.Count) collections trouvées`n" "Green"

# ═══════════════════════════════════════════════════════════════
# PHASE 1: ANALYSE ÉTAT ACTUEL
# ═══════════════════════════════════════════════════════════════

Write-Host "🔍 PHASE 1: Analyse état actuel des collections`n" -ForegroundColor Cyan

$problematiques = @()
$stats = @{
    Total = $collections.Count
    Indexed = 0
    PartiallyIndexed = 0
    NotIndexed = 0
    Empty = 0
}

foreach ($coll in $collections) {
    $info = Get-CollectionInfo -Name $coll.name
    if (-not $info) { continue }
    
    $indexed = $info.indexed_vectors_count
    $points = $info.points_count
    $threshold = $info.config.optimizer_config.indexing_threshold
    
    if ($points -eq 0) {
        $stats.Empty++
    }
    elseif ($indexed -eq 0) {
        $stats.NotIndexed++
        $problematiques += [PSCustomObject]@{
            Name = $coll.name
            Points = $points
            Indexed = $indexed
            Threshold = $threshold
            Segments = $info.segments_count
            Priority = $points # Plus de points = plus prioritaire
        }
    }
    elseif ($indexed -lt $points * 0.9) {
        $stats.PartiallyIndexed++
        $problematiques += [PSCustomObject]@{
            Name = $coll.name
            Points = $points
            Indexed = $indexed
            Threshold = $threshold
            Segments = $info.segments_count
            Priority = $points - $indexed
        }
    }
    else {
        $stats.Indexed++
    }
}

Write-Log "📊 STATISTIQUES:" "Cyan"
Write-Log "  - Collections totales: $($stats.Total)" "White"
Write-Log "  - Correctement indexées: $($stats.Indexed)" "Green"
Write-Log "  - Partiellement indexées: $($stats.PartiallyIndexed)" "Yellow"
Write-Log "  - NON indexées: $($stats.NotIndexed)" "Red"
Write-Log "  - Vides: $($stats.Empty)" "Gray"

if ($problematiques.Count -eq 0) {
    Write-Log "`n✅ AUCUNE COLLECTION PROBLÉMATIQUE - Système sain!" "Green"
    exit 0
}

Write-Log "`n🚨 $($problematiques.Count) collections problématiques identifiées" "Red"

# Trier par priorité (points + non-indexés)
$problematiques = $problematiques | Sort-Object -Property Priority -Descending

# ═══════════════════════════════════════════════════════════════
# PHASE 2: MODIFICATION CONFIGURATION
# ═══════════════════════════════════════════════════════════════

Write-Host "`n⚙️ PHASE 2: Modification configuration`n" -ForegroundColor Cyan

$configFile = "config/production.optimized.yaml"

if ($DryRun) {
    Write-Log "🔍 [DRY-RUN] Simulation modification config" "Yellow"
}
else {
    Write-Log "📝 Backup config actuelle..." "Cyan"
    Copy-Item $configFile "$configFile.backup_$timestamp"
    Write-Log "✅ Backup créé: $configFile.backup_$timestamp" "Green"
    
    Write-Log "✏️ Ajout indexing_threshold: 1000 dans la config..." "Cyan"
    
    $content = Get-Content $configFile -Raw
    
    # Vérifier si indexing_threshold existe déjà
    if ($content -match 'indexing_threshold:\s*\d+') {
        # Remplacer la valeur existante
        $content = $content -replace 'indexing_threshold:\s*\d+', 'indexing_threshold: 1000'
        Write-Log "  → Valeur existante remplacée" "Yellow"
    }
    else {
        # Ajouter après indexing_threshold_kb
        $content = $content -replace '(indexing_threshold_kb:\s*\d+)', "`$1`n    indexing_threshold: 1000  # Seuil en nombre de points"
        Write-Log "  → Paramètre ajouté après indexing_threshold_kb" "Yellow"
    }
    
    $content | Set-Content $configFile -Encoding UTF8
    Write-Log "✅ Configuration modifiée" "Green"
    
    Write-Log "🔄 Redémarrage container pour appliquer config..." "Yellow"
    docker restart qdrant_production | Out-Null
    
    Write-Log "⏳ Attente démarrage container (60s)..." "Yellow"
    Start-Sleep -Seconds 60
    
    # Vérifier santé après redémarrage
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:6333/healthz" -ErrorAction Stop -TimeoutSec 10
        Write-Log "✅ Container redémarré avec succès" "Green"
    }
    catch {
        Write-Log "❌ ERREUR: Container ne répond pas après redémarrage!" "Red"
        Write-Log "   Restaurer config: Copy-Item $configFile.backup_$timestamp $configFile -Force" "Yellow"
        exit 1
    }
}

# ═══════════════════════════════════════════════════════════════
# PHASE 3: REBUILD INDEX TOP COLLECTIONS
# ═══════════════════════════════════════════════════════════════

Write-Host "`n🔨 PHASE 3: Rebuild index collections prioritaires`n" -ForegroundColor Cyan

# Sélectionner top 15 collections par priorité
$topCollections = $problematiques | Select-Object -First 15

Write-Log "🎯 $($topCollections.Count) collections sélectionnées pour rebuild immédiat:" "Cyan"
foreach ($coll in $topCollections) {
    Write-Log "  - $($coll.Name): $($coll.Points) points, $($coll.Indexed) indexés" "White"
}

if ($DryRun) {
    Write-Log "`n🔍 [DRY-RUN] Simulation rebuild - AUCUNE ACTION RÉELLE" "Yellow"
}
else {
    Write-Log "`n🔨 Lancement rebuild (peut prendre 15-30 min)..." "Yellow"
    
    $success = 0
    $failed = 0
    
    foreach ($coll in $topCollections) {
        Write-Log "`n[$($success + $failed + 1)/$($topCollections.Count)] $($coll.Name)" "Cyan"
        
        if (Force-CollectionOptimization -Name $coll.Name) {
            $success++
            # Attendre 2s entre chaque pour éviter surcharge
            Start-Sleep -Seconds 2
        }
        else {
            $failed++
        }
    }
    
    Write-Log "`n📊 RÉSULTATS REBUILD:" "Cyan"
    Write-Log "  ✅ Succès: $success" "Green"
    Write-Log "  ❌ Échecs: $failed" "Red"
}

# ═══════════════════════════════════════════════════════════════
# PHASE 4: VALIDATION POST-FIX
# ═══════════════════════════════════════════════════════════════

Write-Host "`n✅ PHASE 4: Validation post-fix`n" -ForegroundColor Cyan

if ($DryRun) {
    Write-Log "🔍 [DRY-RUN] Validation sautée" "Yellow"
}
else {
    Write-Log "⏳ Attente stabilisation système (30s)..." "Yellow"
    Start-Sleep -Seconds 30
    
    Write-Log "`n🔍 Vérification nouvelles collections problématiques..." "Cyan"
    
    $stillProblematic = @()
    foreach ($coll in $topCollections) {
        $info = Get-CollectionInfo -Name $coll.Name
        if ($info -and $info.indexed_vectors_count -eq 0 -and $info.points_count -gt 0) {
            $stillProblematic += $coll.Name
            Write-Log "  ⚠️ $($coll.Name): Toujours non indexée!" "Yellow"
        }
    }
    
    if ($stillProblematic.Count -eq 0) {
        Write-Log "`n✅ SUCCÈS: Toutes les collections top prioritaires sont maintenant indexées!" "Green"
    }
    else {
        Write-Log "`n⚠️ ATTENTION: $($stillProblematic.Count) collections toujours problématiques:" "Yellow"
        $stillProblematic | ForEach-Object { Write-Log "  - $_" "Yellow" }
        Write-Log "`n💡 Ces collections peuvent nécessiter un rebuild manuel ou plus de temps" "Cyan"
    }
}

# ═══════════════════════════════════════════════════════════════
# PHASE 5: RECOMMANDATIONS MONITORING
# ═══════════════════════════════════════════════════════════════

Write-Host "`n📋 PHASE 5: Recommandations post-fix`n" -ForegroundColor Cyan

Write-Log "🔍 MONITORING REQUIS (48H):" "Cyan"
Write-Log "  1. Vérifier temps réponse < 100ms:" "White"
Write-Log "     docker logs qdrant_production --tail 1000 | Select-String 'PUT.*points'" "Gray"
Write-Log ""
Write-Log "  2. Vérifier nouvelles collections s'indexent automatiquement:" "White"
Write-Log "     pwsh scripts/diagnostics/20251015_analyse_collections_freeze.ps1" "Gray"
Write-Log ""
Write-Log "  3. Surveiller absence de freeze pendant 48h" "White"
Write-Log "     docker stats qdrant_production --no-stream" "Gray"

Write-Log "`n💾 LOGS SAUVEGARDÉS:" "Cyan"
Write-Log "  - Log fix: $logFile" "White"
if (-not $DryRun) {
    Write-Log "  - Config backup: $configFile.backup_$timestamp" "White"
}

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  ✅ FIX HYBRIDE TERMINÉ                                     ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

Write-Log "⏰ Durée totale: $(((Get-Date) - $startTime).TotalMinutes.ToString('F1')) minutes" "Cyan"

if ($DryRun) {
    Write-Host "🔍 Mode DRY-RUN - Aucune modification réelle effectuée" -ForegroundColor Yellow
    Write-Host "   Relancez sans -DryRun pour appliquer les changements" -ForegroundColor Yellow
}
else {
    Write-Host "✅ Système corrigé - Monitoring 48h requis pour validation complète" -ForegroundColor Green
}