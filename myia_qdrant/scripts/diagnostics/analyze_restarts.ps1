<#
.SYNOPSIS
    Script consolidé d'analyse des redémarrages Qdrant post-fix

.DESCRIPTION
    Analyse les redémarrages du container Qdrant après le fix du 15/10 à 23h28.
    Génère un rapport complet incluant:
    - Classification des redémarrages (Manuel, OOM, Freeze, Crash, Timeout)
    - Progression de l'indexation vs baseline 24%
    - Mesures de performance (temps réponse moyen)
    - Comparaison avant/après fix
    - Recommandations d'action

.PARAMETER ContainerName
    Nom du container Docker (défaut: qdrant_production)

.PARAMETER SinceHours
    Période d'analyse en heures (défaut: 48)

.PARAMETER OutputDir
    Répertoire de sortie (défaut: diagnostics)

.PARAMETER IncludeIndexationCheck
    Active la vérification progression indexation

.PARAMETER IncludePerformanceTest
    Active les tests de performance

.PARAMETER DryRun
    Mode simulation sans modifications

.EXAMPLE
    .\analyze_restarts.ps1
    # Mode par défaut: analyse 48h, génère rapport complet

.EXAMPLE
    .\analyze_restarts.ps1 -IncludeIndexationCheck -IncludePerformanceTest
    # Analyse complète avec tous les checks

.EXAMPLE
    .\analyze_restarts.ps1 -SinceHours 72 -DryRun
    # Simulation analyse 72h

.NOTES
    Date: 2025-10-19
    Version: 1.0
    Auteur: Infrastructure Team
    Contexte: Analyse post-fix freeze Qdrant (15/10/2025)
#>

param(
    [string]$ContainerName = "qdrant_production",
    [int]$SinceHours = 48,
    [string]$OutputDir = "diagnostics",
    [switch]$IncludeIndexationCheck,
    [switch]$IncludePerformanceTest,
    [switch]$DryRun
)

# Configuration
$QdrantHost = "http://localhost:6333"
$BaselineIndexation = 24  # % indexation avant fix (12/50 collections)
$BaselineFreeze = "6-8h"  # Fréquence freeze avant fix
$FixTimestamp = [datetime]"2025-10-15T23:28:00"

# Couleurs
$ColorSuccess = "Green"
$ColorWarning = "Yellow"
$ColorError = "Red"
$ColorInfo = "Cyan"

# Initialisation
$ScriptStart = Get-Date
$LogFile = Join-Path $OutputDir "analyze_restarts_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ReportFile = Join-Path $OutputDir "20251019_ANALYSE_REDEMARRAGES.md"

# Créer répertoire output
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    # Écrire dans fichier
    Add-Content -Path $LogFile -Value $LogEntry
    
    # Afficher dans console avec couleur
    $Color = switch ($Level) {
        "SUCCESS" { $ColorSuccess }
        "WARNING" { $ColorWarning }
        "ERROR" { $ColorError }
        default { $ColorInfo }
    }
    Write-Host $LogEntry -ForegroundColor $Color
}

function Get-RestartHistory {
    <#
    .SYNOPSIS
        Extrait l'historique des redémarrages depuis les logs Docker
    .OUTPUTS
        Array de hashtables avec timestamp, type, cause
    #>
    param(
        [int]$Hours
    )
    
    Write-Log "📋 Extraction historique redémarrages (dernières ${Hours}h)..." "INFO"
    
    try {
        # Récupérer logs container
        $Since = (Get-Date).AddHours(-$Hours).ToString("yyyy-MM-ddTHH:mm:ss")
        $Logs = docker logs $ContainerName --since $Since 2>&1 | Out-String
        
        # Pattern redémarrage: début logs après arrêt
        $RestartPattern = '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)\s+INFO.*starting qdrant'
        $Restarts = @()
        
        $Matches = [regex]::Matches($Logs, $RestartPattern)
        
        foreach ($Match in $Matches) {
            $Timestamp = [datetime]::Parse($Match.Groups[1].Value)
            
            # Classer type redémarrage
            $Type = "Unknown"
            $Cause = "Non déterminée"
            
            # Analyser contexte avant redémarrage (500 lignes)
            $RestartIndex = $Match.Index
            $ContextStart = [Math]::Max(0, $RestartIndex - 10000)
            $Context = $Logs.Substring($ContextStart, $RestartIndex - $ContextStart)
            
            # Classification
            if ($Context -match "OOMKilled|out of memory") {
                $Type = "OOM"
                $Cause = "Mémoire saturée"
            }
            elseif ($Context -match "timeout|freeze|hang") {
                $Type = "Freeze"
                $Cause = "Timeout/Freeze détecté"
            }
            elseif ($Context -match "panic|fatal|crash") {
                $Type = "Crash"
                $Cause = "Erreur fatale/Panic"
            }
            elseif ($Context -match "shutdown|stop|sigterm") {
                $Type = "Manuel"
                $Cause = "Arrêt contrôlé"
            }
            else {
                $Type = "Indéterminé"
                $Cause = "Redémarrage sans cause claire"
            }
            
            $Restarts += @{
                Timestamp = $Timestamp
                Type = $Type
                Cause = $Cause
            }
        }
        
        Write-Log "✅ Trouvé $($Restarts.Count) redémarrage(s)" "SUCCESS"
        return $Restarts
        
    } catch {
        Write-Log "❌ Erreur extraction historique: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-ContainerOOMStatus {
    <#
    .SYNOPSIS
        Vérifie le statut OOMKilled du container
    .OUTPUTS
        Boolean: $true si OOMKilled, $false sinon
    #>
    
    Write-Log "🔍 Vérification statut OOMKilled..." "INFO"
    
    try {
        $InspectJson = docker inspect $ContainerName | ConvertFrom-Json
        $OOMKilled = $InspectJson[0].State.OOMKilled
        
        if ($OOMKilled) {
            Write-Log "⚠️ Container marqué OOMKilled=True" "WARNING"
        } else {
            Write-Log "✅ Container OOMKilled=False" "SUCCESS"
        }
        
        return $OOMKilled
        
    } catch {
        Write-Log "❌ Erreur vérification OOM: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Get-IndexationProgress {
    <#
    .SYNOPSIS
        Calcule le % de progression indexation des collections
    .OUTPUTS
        Hashtable avec indexed, total, percentage
    #>
    
    Write-Log "📊 Calcul progression indexation..." "INFO"
    
    try {
        $Response = Invoke-RestMethod -Uri "$QdrantHost/collections" -Method Get -ErrorAction Stop
        
        $TotalCollections = $Response.result.collections.Count
        $IndexedCollections = 0
        
        foreach ($Collection in $Response.result.collections) {
            # Vérifier si collection a index HNSW actif
            $CollectionDetail = Invoke-RestMethod -Uri "$QdrantHost/collections/$($Collection.name)" -Method Get
            
            $HasHNSW = $false
            if ($CollectionDetail.result.config.params.vectors.PSObject.Properties.Name -contains "hnsw_config") {
                $HasHNSW = $true
            }
            
            # Si vecteurs > 0 et HNSW actif = indexé
            if ($Collection.vectors_count -gt 0 -and $HasHNSW) {
                $IndexedCollections++
            }
        }
        
        $Percentage = if ($TotalCollections -gt 0) {
            [math]::Round(($IndexedCollections / $TotalCollections) * 100, 1)
        } else { 0 }
        
        Write-Log "✅ Indexation: $IndexedCollections/$TotalCollections collections ($Percentage%)" "SUCCESS"
        
        return @{
            indexed = $IndexedCollections
            total = $TotalCollections
            percentage = $Percentage
        }
        
    } catch {
        Write-Log "❌ Erreur calcul indexation: $($_.Exception.Message)" "ERROR"
        return @{ indexed = 0; total = 0; percentage = 0 }
    }
}

function Get-PerformanceMetrics {
    <#
    .SYNOPSIS
        Mesure les temps de réponse moyens sur échantillon collections
    .OUTPUTS
        Hashtable avec avgResponseTime, minResponseTime, maxResponseTime
    #>
    
    Write-Log "⚡ Mesure performance (5 requêtes test)..." "INFO"
    
    try {
        # Récupérer collections avec vecteurs
        $Response = Invoke-RestMethod -Uri "$QdrantHost/collections" -Method Get
        $CollectionsWithVectors = $Response.result.collections | Where-Object { $_.vectors_count -gt 0 } | Select-Object -First 5
        
        if ($CollectionsWithVectors.Count -eq 0) {
            Write-Log "⚠️ Aucune collection avec vecteurs pour test" "WARNING"
            return @{ avgResponseTime = 0; minResponseTime = 0; maxResponseTime = 0 }
        }
        
        $ResponseTimes = @()
        
        foreach ($Collection in $CollectionsWithVectors) {
            # Créer vecteur test aléatoire
            $VectorSize = $Collection.config.params.vectors.size
            $TestVector = 1..$VectorSize | ForEach-Object { Get-Random -Minimum -1.0 -Maximum 1.0 }
            
            $Body = @{
                vector = $TestVector
                limit = 10
                with_payload = $false
                with_vector = $false
            } | ConvertTo-Json -Depth 10
            
            $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            try {
                $SearchResult = Invoke-RestMethod `
                    -Uri "$QdrantHost/collections/$($Collection.name)/points/search" `
                    -Method Post `
                    -Body $Body `
                    -ContentType "application/json" `
                    -TimeoutSec 10 `
                    -ErrorAction Stop
                
                $Stopwatch.Stop()
                $ResponseTimes += $Stopwatch.ElapsedMilliseconds
                
            } catch {
                $Stopwatch.Stop()
                Write-Log "⚠️ Échec recherche sur $($Collection.name): $($_.Exception.Message)" "WARNING"
            }
        }
        
        if ($ResponseTimes.Count -eq 0) {
            Write-Log "⚠️ Aucune requête réussie" "WARNING"
            return @{ avgResponseTime = 0; minResponseTime = 0; maxResponseTime = 0 }
        }
        
        $Avg = [math]::Round(($ResponseTimes | Measure-Object -Average).Average, 2)
        $Min = ($ResponseTimes | Measure-Object -Minimum).Minimum
        $Max = ($ResponseTimes | Measure-Object -Maximum).Maximum
        
        Write-Log "✅ Performance: Moy=$Avg ms, Min=$Min ms, Max=$Max ms" "SUCCESS"
        
        return @{
            avgResponseTime = $Avg
            minResponseTime = $Min
            maxResponseTime = $Max
            samplesCount = $ResponseTimes.Count
        }
        
    } catch {
        Write-Log "❌ Erreur mesure performance: $($_.Exception.Message)" "ERROR"
        return @{ avgResponseTime = 0; minResponseTime = 0; maxResponseTime = 0 }
    }
}

function Generate-Report {
    <#
    .SYNOPSIS
        Génère le rapport Markdown final
    #>
    param(
        [array]$Restarts,
        [bool]$OOMKilled,
        [hashtable]$Indexation,
        [hashtable]$Performance
    )
    
    Write-Log "📝 Génération rapport Markdown..." "INFO"
    
    $Duration = (Get-Date) - $ScriptStart
    
    # Calculer amélioration
    $RestartsSinceFixCount = ($Restarts | Where-Object { $_.Timestamp -gt $FixTimestamp }).Count
    $HoursSinceFix = ((Get-Date) - $FixTimestamp).TotalHours
    $AvgFrequency = if ($RestartsSinceFixCount -gt 0) {
        [math]::Round($HoursSinceFix / $RestartsSinceFixCount, 1)
    } else {
        "Aucun redémarrage"
    }
    
    # Déterminer recommandation
    $Recommendation = ""
    if ($RestartsSinceFixCount -eq 0) {
        $Recommendation = "✅ **EXCELLENT**: Aucun redémarrage depuis le fix. Continuer le monitoring."
    }
    elseif ($AvgFrequency -is [string] -or $AvgFrequency -gt 12) {
        $Recommendation = "✅ **BON**: Amélioration significative vs baseline (6-8h). Attendre 24h supplémentaires pour confirmation."
    }
    elseif ($AvgFrequency -gt 8) {
        $Recommendation = "⚠️ **MOYEN**: Légère amélioration. Surveiller 24h et envisager optimisations supplémentaires."
    }
    else {
        $Recommendation = "❌ **CRITIQUE**: Redémarrages encore fréquents. Analyse approfondie requise et rebuild forcé à envisager."
    }
    
    # Progression indexation
    $IndexationDelta = $Indexation.percentage - $BaselineIndexation
    $IndexationStatus = if ($IndexationDelta -gt 0) {
        "✅ **+$IndexationDelta%** vs baseline"
    } elseif ($IndexationDelta -eq 0) {
        "➖ **Stable** (=$BaselineIndexation%)"
    } else {
        "⚠️ **$IndexationDelta%** vs baseline"
    }
    
    $Markdown = @"
# 🔍 Rapport Analyse Redémarrages Qdrant - Post-Fix 15/10

**Date analyse**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Durée**: $([math]::Round($Duration.TotalMinutes, 1)) minutes
**Période analysée**: Dernières ${SinceHours}h (depuis $(Get-Date).AddHours(-$SinceHours))
**Container**: $ContainerName

---

## 📊 Résumé Exécutif

### Contexte Fix
- **Date fix**: $($FixTimestamp.ToString("yyyy-MM-dd HH:mm"))
- **Problème avant fix**: Freeze container toutes les ${BaselineFreeze}
- **Indexation avant fix**: $BaselineIndexation% (12/50 collections)

### Résultats Post-Fix
- **Redémarrages détectés**: $($Restarts.Count) au total ($RestartsSinceFixCount depuis le fix)
- **Fréquence moyenne**: $AvgFrequency
- **État OOMKilled**: $(if ($OOMKilled) { "⚠️ TRUE" } else { "✅ FALSE" })
- **Indexation actuelle**: $($Indexation.percentage)% ($($Indexation.indexed)/$($Indexation.total) collections) - $IndexationStatus
- **Performance moyenne**: $($Performance.avgResponseTime) ms (min: $($Performance.minResponseTime) ms, max: $($Performance.maxResponseTime) ms)

---

## 🔄 Détail des Redémarrages

$( 
    if ($Restarts.Count -eq 0) {
        "✅ **Aucun redémarrage détecté** dans la période analysée."
    } else {
        "| # | Timestamp | Type | Cause | Depuis Fix |`n" +
        "|---|-----------|------|-------|------------|`n" +
        ($Restarts | ForEach-Object -Begin { $i = 1 } -Process {
            $SinceFix = if ($_.Timestamp -gt $FixTimestamp) { "✅ Oui" } else { "➖ Non" }
            "| $i | $($_.Timestamp.ToString('yyyy-MM-dd HH:mm:ss')) | $($_.Type) | $($_.Cause) | $SinceFix |"
            $i++
        } | Out-String)
    }
)

### Classification des Types
$(
    $TypeCounts = $Restarts | Group-Object -Property Type | Sort-Object Count -Descending
    if ($TypeCounts) {
        $TypeCounts | ForEach-Object {
            "- **$($_.Name)**: $($_.Count) occurrence(s)"
        } | Out-String
    } else {
        "- Aucune classification disponible"
    }
)

---

## 📈 Progression Indexation

**Baseline (15/10)**: $BaselineIndexation% (12/50 collections)
**Actuel (19/10)**: $($Indexation.percentage)% ($($Indexation.indexed)/$($Indexation.total) collections)
**Évolution**: $IndexationDelta%

$(
    if ($IndexationDelta -gt 0) {
        "✅ **Amélioration détectée**: L'indexation progresse normalement post-fix."
    } elseif ($IndexationDelta -eq 0) {
        "➖ **Stable**: Pas de progression depuis le fix. Vérifier si rebuild en cours."
    } else {
        "⚠️ **Régression détectée**: L'indexation a diminué. Investigation requise."
    }
)

---

## ⚡ Performance Mesurée

**Tests effectués**: $($Performance.samplesCount) requêtes sur collections réelles
- **Temps réponse moyen**: $($Performance.avgResponseTime) ms
- **Temps réponse minimum**: $($Performance.minResponseTime) ms
- **Temps réponse maximum**: $($Performance.maxResponseTime) ms

$(
    if ($Performance.avgResponseTime -lt 100) {
        "✅ **EXCELLENT**: Temps réponse <100ms, performance optimale."
    } elseif ($Performance.avgResponseTime -lt 500) {
        "✅ **BON**: Temps réponse <500ms, acceptable pour production."
    } elseif ($Performance.avgResponseTime -lt 1000) {
        "⚠️ **MOYEN**: Temps réponse <1s, à surveiller."
    } else {
        "❌ **CRITIQUE**: Temps réponse >1s, optimisations requises."
    }
)

---

## 📊 Comparaison Avant/Après Fix

| Métrique | Avant Fix (15/10) | Après Fix (19/10) | Amélioration |
|----------|-------------------|-------------------|--------------|
| Fréquence freeze | Toutes les ${BaselineFreeze} | $AvgFrequency | $(if ($AvgFrequency -is [string]) { "✅ 100%" } elseif ($AvgFrequency -gt 8) { "✅ +" + [math]::Round((($AvgFrequency - 7) / 7) * 100, 0) + "%" } else { "➖ Insuffisant" }) |
| Indexation | $BaselineIndexation% | $($Indexation.percentage)% | $IndexationStatus |
| Performance | Non mesurée | $($Performance.avgResponseTime) ms | N/A |
| État container | Freeze fréquents | OOMKilled=$OOMKilled | $(if (-not $OOMKilled) { "✅ Stable" } else { "⚠️ À surveiller" }) |

---

## 🎯 Recommandations

### Action Recommandée
$Recommendation

### Détails
$(
    if ($RestartsSinceFixCount -eq 0) {
        @"
1. **Continuer monitoring** pendant 24-48h supplémentaires
2. **Valider** que l'indexation progresse normalement
3. **Documenter** le fix comme succès si stabilité confirmée
"@
    } elseif ($AvgFrequency -is [string] -or $AvgFrequency -gt 12) {
        @"
1. **Attendre 24h** supplémentaires pour confirmation stabilité
2. **Vérifier progression indexation** (devrait atteindre 100% en ~48h)
3. **Planifier validation finale** après indexation complète
"@
    } elseif ($AvgFrequency -gt 8) {
        @"
1. **Analyser logs détaillés** des redémarrages récents
2. **Optimiser configuration** si patterns identifiés
3. **Attendre 12h** avant décision rebuild forcé
"@
    } else {
        @"
1. **URGENT**: Analyser cause racine immédiatement
2. **Considérer rebuild forcé** avec:
   - Arrêt container
   - Suppression index HNSW corrompus
   - Reconstruction complète
3. **Escalader** si problème persiste
"@
    }
)

---

## 🔧 Configuration Analysée

- **Container**: $ContainerName
- **Hôte Qdrant**: $QdrantHost
- **Période analyse**: ${SinceHours}h
- **Mode**: $(if ($DryRun) { "🔍 DryRun (lecture seule)" } else { "✅ Production" })
- **Checks indexation**: $(if ($IncludeIndexationCheck) { "✅ Activé" } else { "➖ Désactivé" })
- **Tests performance**: $(if ($IncludePerformanceTest) { "✅ Activé" } else { "➖ Désactivé" })

---

## 📁 Fichiers Référence

- **Logs extraits**: [20251016_logs_2_restarts.txt](myia_qdrant/diagnostics/20251016_logs_2_restarts.txt)
- **Patterns erreurs**: [20251016_errors_pattern.txt](myia_qdrant/diagnostics/20251016_errors_pattern.txt)
- **Script monitoring**: [continuous_health_check.ps1](myia_qdrant/scripts/monitoring/continuous_health_check.ps1)
- **Script performance**: [stress_test_qdrant.ps1](myia_qdrant/scripts/diagnostics/stress_test_qdrant.ps1)

---

*Généré par analyze_restarts.ps1 v1.0 - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")*
*Durée analyse: $([math]::Round($Duration.TotalSeconds, 1))s*
"@
    
    if (-not $DryRun) {
        $Markdown | Out-File $ReportFile -Encoding UTF8
        Write-Log "✅ Rapport sauvegardé: $ReportFile" "SUCCESS"
    } else {
        Write-Log "🔍 [DryRun] Rapport généré (non sauvegardé)" "INFO"
    }
    
    return $Markdown
}

# ============================================
# EXÉCUTION PRINCIPALE
# ============================================

Write-Log "========================================" "INFO"
Write-Log "🔍 ANALYSE REDÉMARRAGES QDRANT POST-FIX" "SUCCESS"
Write-Log "========================================" "INFO"
Write-Log "Container: $ContainerName" "INFO"
Write-Log "Période: Dernières ${SinceHours}h" "INFO"
Write-Log "Mode: $(if ($DryRun) { 'DryRun (lecture seule)' } else { 'Production' })" "INFO"
Write-Log "========================================`n" "INFO"

try {
    # 1. Extraction historique redémarrages
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "INFO"
    Write-Log "📋 ÉTAPE 1: Extraction historique redémarrages" "SUCCESS"
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" "INFO"
    
    $Restarts = Get-RestartHistory -Hours $SinceHours
    
    # 2. Vérification statut OOMKilled
    Write-Log "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "INFO"
    Write-Log "🔍 ÉTAPE 2: Vérification statut OOMKilled" "SUCCESS"
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" "INFO"
    
    $OOMKilled = Get-ContainerOOMStatus
    
    # 3. Progression indexation (si demandé)
    $Indexation = @{ indexed = 0; total = 0; percentage = 0 }
    if ($IncludeIndexationCheck) {
        Write-Log "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "INFO"
        Write-Log "📊 ÉTAPE 3: Calcul progression indexation" "SUCCESS"
        Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" "INFO"
        
        $Indexation = Get-IndexationProgress
    } else {
        Write-Log "`n⏭️ ÉTAPE 3: Check indexation désactivé (utiliser -IncludeIndexationCheck)" "WARNING"
    }
    
    # 4. Tests performance (si demandé)
    $Performance = @{ avgResponseTime = 0; minResponseTime = 0; maxResponseTime = 0; samplesCount = 0 }
    if ($IncludePerformanceTest) {
        Write-Log "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "INFO"
        Write-Log "⚡ ÉTAPE 4: Mesure performance" "SUCCESS"
        Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" "INFO"
        
        $Performance = Get-PerformanceMetrics
    } else {
        Write-Log "`n⏭️ ÉTAPE 4: Tests performance désactivés (utiliser -IncludePerformanceTest)" "WARNING"
    }
    
    # 5. Génération rapport
    Write-Log "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "INFO"
    Write-Log "📝 ÉTAPE 5: Génération rapport final" "SUCCESS"
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" "INFO"
    
    $Report = Generate-Report `
        -Restarts $Restarts `
        -OOMKilled $OOMKilled `
        -Indexation $Indexation `
        -Performance $Performance
    
    # Afficher résumé
    Write-Log "`n========================================" "SUCCESS"
    Write-Log "✅ ANALYSE TERMINÉE" "SUCCESS"
    Write-Log "========================================" "SUCCESS"
    Write-Log "Redémarrages: $($Restarts.Count)" "INFO"
    Write-Log "OOMKilled: $OOMKilled" "INFO"
    if ($IncludeIndexationCheck) {
        Write-Log "Indexation: $($Indexation.percentage)%" "INFO"
    }
    if ($IncludePerformanceTest) {
        Write-Log "Performance: $($Performance.avgResponseTime) ms" "INFO"
    }
    Write-Log "Rapport: $ReportFile" "INFO"
    Write-Log "Logs: $LogFile" "INFO"
    Write-Log "========================================`n" "SUCCESS"
    
} catch {
    Write-Log "`n❌ ERREUR CRITIQUE: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    throw
}