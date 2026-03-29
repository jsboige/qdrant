<#
.SYNOPSIS
    Script de test de charge Qdrant pour identifier les seuils de saturation

.DESCRIPTION
    Teste la capacité du container Qdrant en envoyant des requêtes de recherche
    avec une charge croissante pour identifier:
    - Temps de réponse moyen par niveau de charge
    - Utilisation CPU/RAM par niveau de charge
    - Point de saturation (quand le container freeze)
    - Limites pratiques du système
    
    IMPORTANT: Ce test utilise l'API REST directement, pas le MCP
    (évite le problème ESM du MCP)

.PARAMETER StartLoad
    Charge initiale (nombre de requêtes parallèles, défaut: 10)

.PARAMETER MaxLoad
    Charge maximale à tester (défaut: 200)

.PARAMETER LoadStep
    Incrément de charge entre tests (défaut: 20)

.PARAMETER RequestsPerLoad
    Nombre de requêtes par niveau de charge (défaut: 50)

.PARAMETER CollectionName
    Nom de la collection à tester (défaut: auto-detect)

.PARAMETER OutputPath
    Chemin du rapport de résultats (défaut: ./diagnostics)

.EXAMPLE
    .\stress_test_qdrant.ps1
    # Test par défaut: 10 à 200 requêtes par palier de 20

.EXAMPLE
    .\stress_test_qdrant.ps1 -StartLoad 5 -MaxLoad 100 -LoadStep 10
    # Test léger: 5 à 100 par palier de 10

.EXAMPLE
    .\stress_test_qdrant.ps1 -CollectionName "my_collection" -RequestsPerLoad 100
    # Test sur collection spécifique avec 100 requêtes par niveau

.NOTES
    Date: 2025-10-15
    Version: 1.0
    Auteur: Infrastructure Team
#>

param(
    [int]$StartLoad = 10,
    [int]$MaxLoad = 200,
    [int]$LoadStep = 20,
    [int]$RequestsPerLoad = 50,
    [string]$CollectionName = "",
    [string]$OutputPath = "diagnostics"
)

# Configuration
$QdrantHost = "http://localhost:6333"
$ContainerName = "qdrant_production"

# Couleurs
$ColorSuccess = "Green"
$ColorWarning = "Yellow"
$ColorError = "Red"
$ColorInfo = "Cyan"

# Résultats
$Results = @()
$StartTime = Get-Date

# Créer répertoire output
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$ReportFile = Join-Path $OutputPath "stress_test_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$ReportMd = Join-Path $OutputPath "stress_test_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"

function Write-ColorLog {
    param(
        [string]$Message,
        [string]$Color = $ColorInfo
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-RandomCollection {
    <#
    .SYNOPSIS
        Récupère une collection aléatoire avec des vecteurs
    #>
    try {
        $Response = Invoke-RestMethod -Uri "$QdrantHost/collections" -Method Get -ErrorAction Stop
        
        $Collections = $Response.result.collections | Where-Object { $_.vectors_count -gt 0 }
        
        if ($Collections.Count -eq 0) {
            throw "Aucune collection avec vecteurs trouvée"
        }
        
        $Selected = $Collections | Get-Random
        return @{
            name = $Selected.name
            vectorsCount = $Selected.vectors_count
            vectorSize = $Selected.config.params.vectors.size
        }
    } catch {
        throw "Erreur récupération collection: $($_.Exception.Message)"
    }
}

function Get-ContainerStats {
    <#
    .SYNOPSIS
        Récupère statistiques container (CPU, RAM)
    #>
    try {
        $Stats = docker stats $ContainerName --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}" 2>$null
        
        if ($Stats) {
            $Parts = $Stats -split ","
            return @{
                cpu = $Parts[0] -replace '%', ''
                memory = $Parts[1]
                memoryPercent = $Parts[2] -replace '%', ''
            }
        }
        
        return @{ cpu = "N/A"; memory = "N/A"; memoryPercent = "N/A" }
    } catch {
        return @{ cpu = "N/A"; memory = "N/A"; memoryPercent = "N/A" }
    }
}

function Test-SearchQuery {
    <#
    .SYNOPSIS
        Exécute une requête de recherche et mesure le temps
    #>
    param(
        [string]$Collection,
        [array]$Vector,
        [int]$Limit = 10
    )
    
    $Body = @{
        vector = $Vector
        limit = $Limit
        with_payload = $false
        with_vector = $false
    } | ConvertTo-Json -Depth 10
    
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $Response = Invoke-RestMethod `
            -Uri "$QdrantHost/collections/$Collection/points/search" `
            -Method Post `
            -Body $Body `
            -ContentType "application/json" `
            -TimeoutSec 30 `
            -ErrorAction Stop
        
        $Stopwatch.Stop()
        
        return @{
            success = $true
            responseTime = $Stopwatch.ElapsedMilliseconds
            resultsCount = $Response.result.Count
        }
    } catch {
        $Stopwatch.Stop()
        return @{
            success = $false
            responseTime = $Stopwatch.ElapsedMilliseconds
            error = $_.Exception.Message
        }
    }
}

function Invoke-LoadTest {
    <#
    .SYNOPSIS
        Exécute un test de charge avec N requêtes parallèles
    #>
    param(
        [string]$Collection,
        [array]$Vector,
        [int]$ParallelRequests,
        [int]$TotalRequests
    )
    
    Write-ColorLog "  🔄 Exécution $TotalRequests requêtes ($ParallelRequests parallèles)..." $ColorInfo
    
    $Jobs = @()
    $SuccessCount = 0
    $FailureCount = 0
    $ResponseTimes = @()
    
    $StatsStart = Get-ContainerStats
    $TestStart = Get-Date
    
    # Créer jobs parallèles
    1..$TotalRequests | ForEach-Object {
        $Jobs += Start-Job -ScriptBlock {
            param($Host, $Collection, $Vector, $Limit)
            
            $Body = @{
                vector = $Vector
                limit = $Limit
                with_payload = $false
                with_vector = $false
            } | ConvertTo-Json -Depth 10
            
            $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            try {
                $Response = Invoke-RestMethod `
                    -Uri "$Host/collections/$Collection/points/search" `
                    -Method Post `
                    -Body $Body `
                    -ContentType "application/json" `
                    -TimeoutSec 30 `
                    -ErrorAction Stop
                
                $Stopwatch.Stop()
                
                return @{
                    success = $true
                    ms = $Stopwatch.ElapsedMilliseconds
                }
            } catch {
                $Stopwatch.Stop()
                return @{
                    success = $false
                    ms = $Stopwatch.ElapsedMilliseconds
                    error = $_.Exception.Message
                }
            }
        } -ArgumentList $QdrantHost, $Collection, $Vector, 10
        
        # Limiter jobs parallèles
        while ((Get-Job -State Running).Count -ge $ParallelRequests) {
            Start-Sleep -Milliseconds 100
        }
    }
    
    # Attendre completion
    Write-ColorLog "  ⏳ Attente completion..." $ColorInfo
    $Jobs | Wait-Job | Out-Null
    
    # Collecter résultats
    $Jobs | ForEach-Object {
        $Result = Receive-Job -Job $_
        
        if ($Result.success) {
            $SuccessCount++
            $ResponseTimes += $Result.ms
        } else {
            $FailureCount++
        }
        
        Remove-Job -Job $_ -Force
    }
    
    $TestEnd = Get-Date
    $StatsEnd = Get-ContainerStats
    
    $TotalTime = ($TestEnd - $TestStart).TotalSeconds
    
    return @{
        parallelRequests = $ParallelRequests
        totalRequests = $TotalRequests
        successCount = $SuccessCount
        failureCount = $FailureCount
        totalTime = [math]::Round($TotalTime, 2)
        throughput = [math]::Round($TotalRequests / $TotalTime, 2)
        avgResponseTime = if ($ResponseTimes.Count -gt 0) { [math]::Round(($ResponseTimes | Measure-Object -Average).Average, 2) } else { 0 }
        minResponseTime = if ($ResponseTimes.Count -gt 0) { ($ResponseTimes | Measure-Object -Minimum).Minimum } else { 0 }
        maxResponseTime = if ($ResponseTimes.Count -gt 0) { ($ResponseTimes | Measure-Object -Maximum).Maximum } else { 0 }
        p95ResponseTime = if ($ResponseTimes.Count -gt 0) { $ResponseTimes | Sort-Object | Select-Object -Index ([int]($ResponseTimes.Count * 0.95)) } else { 0 }
        cpuStart = $StatsStart.cpu
        cpuEnd = $StatsEnd.cpu
        memoryStart = $StatsStart.memory
        memoryEnd = $StatsEnd.memory
        memoryPercentStart = $StatsStart.memoryPercent
        memoryPercentEnd = $StatsEnd.memoryPercent
    }
}

# ============================================
# EXÉCUTION DU TEST
# ============================================

Write-ColorLog "========================================" $ColorInfo
Write-ColorLog "🧪 TEST DE CHARGE QDRANT" $ColorSuccess
Write-ColorLog "========================================" $ColorInfo
Write-ColorLog "Hôte: $QdrantHost" $ColorInfo
Write-ColorLog "Container: $ContainerName" $ColorInfo
Write-ColorLog "Charge: $StartLoad → $MaxLoad (step: $LoadStep)" $ColorInfo
Write-ColorLog "Requêtes/niveau: $RequestsPerLoad" $ColorInfo
Write-ColorLog "========================================`n" $ColorInfo

try {
    # 1. Sélectionner collection
    Write-ColorLog "📊 Étape 1: Sélection collection" $ColorSuccess
    
    if ($CollectionName -eq "") {
        $Collection = Get-RandomCollection
        Write-ColorLog "  ✅ Collection auto-détectée: $($Collection.name)" $ColorSuccess
    } else {
        $Response = Invoke-RestMethod -Uri "$QdrantHost/collections/$CollectionName" -Method Get
        $Collection = @{
            name = $CollectionName
            vectorsCount = $Response.result.vectors_count
            vectorSize = $Response.result.config.params.vectors.size
        }
        Write-ColorLog "  ✅ Collection spécifiée: $CollectionName" $ColorSuccess
    }
    
    Write-ColorLog "  📈 Vecteurs: $($Collection.vectorsCount)" $ColorInfo
    Write-ColorLog "  📏 Dimension: $($Collection.vectorSize)`n" $ColorInfo
    
    # 2. Créer vecteur de test (aléatoire normalisé)
    Write-ColorLog "🎲 Étape 2: Génération vecteur test" $ColorSuccess
    $TestVector = 1..$Collection.vectorSize | ForEach-Object { Get-Random -Minimum -1.0 -Maximum 1.0 }
    Write-ColorLog "  ✅ Vecteur généré: $($Collection.vectorSize) dimensions`n" $ColorSuccess
    
    # 3. Test baseline (santé)
    Write-ColorLog "🏥 Étape 3: Test baseline (santé)" $ColorSuccess
    $Baseline = Test-SearchQuery -Collection $Collection.name -Vector $TestVector
    
    if ($Baseline.success) {
        Write-ColorLog "  ✅ Baseline OK: $($Baseline.responseTime)ms`n" $ColorSuccess
    } else {
        throw "❌ Baseline échoué: $($Baseline.error)"
    }
    
    # 4. Tests de charge progressifs
    Write-ColorLog "⚡ Étape 4: Tests de charge progressifs`n" $ColorSuccess
    
    for ($Load = $StartLoad; $Load -le $MaxLoad; $Load += $LoadStep) {
        Write-ColorLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" $ColorInfo
        Write-ColorLog "📊 TEST CHARGE: $Load requêtes parallèles" $ColorWarning
        Write-ColorLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" $ColorInfo
        
        $LoadResult = Invoke-LoadTest `
            -Collection $Collection.name `
            -Vector $TestVector `
            -ParallelRequests $Load `
            -TotalRequests $RequestsPerLoad
        
        $Results += $LoadResult
        
        # Afficher résultats
        Write-ColorLog "`n  📈 RÉSULTATS:" $ColorSuccess
        Write-ColorLog "  ├─ Succès: $($LoadResult.successCount)/$($LoadResult.totalRequests)" $(if ($LoadResult.failureCount -eq 0) { $ColorSuccess } else { $ColorError })
        Write-ColorLog "  ├─ Temps total: $($LoadResult.totalTime)s" $ColorInfo
        Write-ColorLog "  ├─ Débit: $($LoadResult.throughput) req/s" $ColorInfo
        Write-ColorLog "  ├─ Réponse moyenne: $($LoadResult.avgResponseTime)ms" $(if ($LoadResult.avgResponseTime -lt 1000) { $ColorSuccess } else { $ColorWarning })
        Write-ColorLog "  ├─ Réponse P95: $($LoadResult.p95ResponseTime)ms" $(if ($LoadResult.p95ResponseTime -lt 2000) { $ColorSuccess } else { $ColorWarning })
        Write-ColorLog "  ├─ Min/Max: $($LoadResult.minResponseTime)ms / $($LoadResult.maxResponseTime)ms" $ColorInfo
        Write-ColorLog "  ├─ CPU: $($LoadResult.cpuStart)% → $($LoadResult.cpuEnd)%" $(if ([double]$LoadResult.cpuEnd -lt 80) { $ColorSuccess } else { $ColorWarning })
        Write-ColorLog "  └─ RAM: $($LoadResult.memoryPercentStart)% → $($LoadResult.memoryPercentEnd)%`n" $(if ([double]$LoadResult.memoryPercentEnd -lt 80) { $ColorSuccess } else { $ColorWarning })
        
        # Vérifier si saturation atteinte
        if ($LoadResult.failureCount -gt ($RequestsPerLoad * 0.1)) {
            Write-ColorLog "⚠️ SEUIL DE SATURATION ATTEINT (>10% échecs)" $ColorError
            Write-ColorLog "  Arrêt des tests pour préserver la stabilité`n" $ColorWarning
            break
        }
        
        if ([double]$LoadResult.avgResponseTime -gt 5000) {
            Write-ColorLog "⚠️ TEMPS DE RÉPONSE CRITIQUE (>5s)" $ColorError
            Write-ColorLog "  Recommandé: Arrêt des tests`n" $ColorWarning
            break
        }
        
        # Pause entre tests
        Write-ColorLog "  ⏸️ Pause 5s avant prochain test..." $ColorInfo
        Start-Sleep -Seconds 5
    }
    
    # 5. Génération rapport
    Write-ColorLog "`n========================================" $ColorInfo
    Write-ColorLog "📝 GÉNÉRATION RAPPORT" $ColorSuccess
    Write-ColorLog "========================================`n" $ColorInfo
    
    $EndTime = Get-Date
    $Duration = $EndTime - $StartTime
    
    # Rapport JSON
    $Report = @{
        timestamp = $StartTime.ToString("o")
        duration = $Duration.TotalMinutes
        collection = $Collection
        configuration = @{
            startLoad = $StartLoad
            maxLoad = $MaxLoad
            loadStep = $LoadStep
            requestsPerLoad = $RequestsPerLoad
        }
        results = $Results
        summary = @{
            totalTests = $Results.Count
            totalRequests = ($Results | Measure-Object -Property totalRequests -Sum).Sum
            totalSuccess = ($Results | Measure-Object -Property successCount -Sum).Sum
            totalFailures = ($Results | Measure-Object -Property failureCount -Sum).Sum
            maxThroughput = ($Results | Measure-Object -Property throughput -Maximum).Maximum
            maxLoad = ($Results | Sort-Object -Property parallelRequests -Descending | Select-Object -First 1).parallelRequests
        }
    }
    
    $Report | ConvertTo-Json -Depth 10 | Out-File $ReportFile -Encoding UTF8
    Write-ColorLog "  ✅ Rapport JSON: $ReportFile" $ColorSuccess
    
    # Rapport Markdown
    $Markdown = @"
# 🧪 Rapport Test de Charge Qdrant

**Date**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Durée**: $([math]::Round($Duration.TotalMinutes, 2)) minutes
**Collection**: $($Collection.name) ($($Collection.vectorsCount) vecteurs, dim=$($Collection.vectorSize))

## 📊 Résumé

- **Tests effectués**: $($Results.Count)
- **Requêtes totales**: $($Report.summary.totalRequests)
- **Succès**: $($Report.summary.totalSuccess)
- **Échecs**: $($Report.summary.totalFailures)
- **Débit max**: $($Report.summary.maxThroughput) req/s
- **Charge max testée**: $($Report.summary.maxLoad) requêtes parallèles

## 📈 Résultats par Niveau de Charge

| Charge | Succès | Temps (s) | Débit (req/s) | Moy (ms) | P95 (ms) | Max (ms) | CPU | RAM (%) |
|--------|--------|-----------|---------------|----------|----------|----------|-----|---------|
$(
    $Results | ForEach-Object {
        "| $($_.parallelRequests) | $($_.successCount)/$($_.totalRequests) | $($_.totalTime) | $($_.throughput) | $($_.avgResponseTime) | $($_.p95ResponseTime) | $($_.maxResponseTime) | $($_.cpuEnd) | $($_.memoryPercentEnd) |"
    }
)

## 🎯 Recommandations

$( 
    $MaxSuccessLoad = ($Results | Where-Object { $_.failureCount -eq 0 } | Sort-Object -Property parallelRequests -Descending | Select-Object -First 1)
    if ($MaxSuccessLoad) {
        "✅ **Charge recommandée**: $($MaxSuccessLoad.parallelRequests) requêtes parallèles (0% échecs, $($MaxSuccessLoad.avgResponseTime)ms moy)"
    } else {
        "⚠️ Tous les tests ont échoué - revoir configuration"
    }
)

$( 
    $FastLoad = ($Results | Where-Object { $_.avgResponseTime -lt 1000 } | Sort-Object -Property parallelRequests -Descending | Select-Object -First 1)
    if ($FastLoad) {
        "⚡ **Charge optimale (<1s)**: $($FastLoad.parallelRequests) requêtes parallèles ($($FastLoad.avgResponseTime)ms moy)"
    }
)

$( 
    $HighCPU = $Results | Where-Object { [double]$_.cpuEnd -gt 80 }
    if ($HighCPU) {
        "⚠️ **CPU >80%** détecté à partir de $(($HighCPU | Select-Object -First 1).parallelRequests) requêtes parallèles"
    }
)

$( 
    $HighRAM = $Results | Where-Object { [double]$_.memoryPercentEnd -gt 80 }
    if ($HighRAM) {
        "⚠️ **RAM >80%** détecté à partir de $(($HighRAM | Select-Object -First 1).parallelRequests) requêtes parallèles"
    }
)

## 🔧 Configuration Testée

- **Hôte**: $QdrantHost
- **Container**: $ContainerName
- **Charge**: $StartLoad → $MaxLoad (step: $LoadStep)
- **Requêtes/niveau**: $RequestsPerLoad

---
*Généré par stress_test_qdrant.ps1 - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")*
"@
    
    $Markdown | Out-File $ReportMd -Encoding UTF8
    Write-ColorLog "  ✅ Rapport Markdown: $ReportMd`n" $ColorSuccess
    
    Write-ColorLog "========================================" $ColorSuccess
    Write-ColorLog "✅ TEST DE CHARGE TERMINÉ" $ColorSuccess
    Write-ColorLog "========================================" $ColorSuccess
    
} catch {
    Write-ColorLog "`n❌ ERREUR: $($_.Exception.Message)" $ColorError
    throw
}