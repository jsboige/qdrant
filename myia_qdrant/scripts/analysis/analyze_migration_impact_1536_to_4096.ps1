# Script d'Analyse d'Impact de Migration 1536→4096 Dimensions
# Date: 2025-11-04
# Objectif: Analyser l'impact réel de la migration OpenAI→Qwen3 sur les collections Qdrant

param(
    [Parameter(Mandatory=$false)]
    [string]$QdrantEndpoint = "http://localhost:6333",
    
    [Parameter(Mandatory=$false)]
    [string]$ApiKey = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$Verbose
)

# Configuration
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Couleurs pour l'affichage
$ColorSuccess = "Green"
$ColorError = "Red"
$ColorWarning = "Yellow"
$ColorInfo = "Cyan"
$ColorHeader = "White"

Write-Host "📊 ANALYSE D'IMPACT MIGRATION 1536→4096" -ForegroundColor $ColorHeader
Write-Host "=========================================" -ForegroundColor $ColorHeader
Write-Host ""

# Fonction pour calculer l'impact mémoire
function Get-MemoryImpact {
    param(
        [int]$CurrentPoints,
        [int]$CurrentDimensions,
        [int]$NewDimensions
    )
    
    # Calculer la taille d'un vecteur (float32 = 4 bytes par dimension)
    $currentVectorSize = $CurrentDimensions * 4
    $newVectorSize = $NewDimensions * 4
    
    # Calculer l'impact mémoire
    $memoryIncreasePerVector = $newVectorSize - $currentVectorSize
    $totalMemoryIncrease = $CurrentPoints * $memoryIncreasePerVector
    $memoryIncreasePercent = ($memoryIncreasePerVector / $currentVectorSize) * 100
    
    return @{
        CurrentVectorSize = $currentVectorSize
        NewVectorSize = $newVectorSize
        MemoryIncreasePerVector = $memoryIncreasePerVector
        TotalMemoryIncrease = $totalMemoryIncrease
        MemoryIncreasePercent = $memoryIncreasePercent
        CurrentTotalMemory = $CurrentPoints * $currentVectorSize
        NewTotalMemory = $CurrentPoints * $newVectorSize
    }
}

# Fonction pour calculer l'impact stockage
function Get-StorageImpact {
    param(
        [int]$CurrentPoints,
        [int]$CurrentDimensions,
        [int]$NewDimensions
    )
    
    $currentStoragePerVector = $CurrentDimensions * 4  # float32
    $newStoragePerVector = $NewDimensions * 4
    
    $storageIncreasePerVector = $newStoragePerVector - $currentStoragePerVector
    $totalStorageIncrease = $CurrentPoints * $storageIncreasePerVector
    $storageIncreasePercent = ($storageIncreasePerVector / $currentStoragePerVector) * 100
    
    return @{
        CurrentStoragePerVector = $currentStoragePerVector
        NewStoragePerVector = $newStoragePerVector
        StorageIncreasePerVector = $storageIncreasePerVector
        TotalStorageIncrease = $totalStorageIncrease
        StorageIncreasePercent = $storageIncreasePercent
        CurrentTotalStorage = $CurrentPoints * $currentStoragePerVector
        NewTotalStorage = $CurrentPoints * $newStoragePerVector
    }
}

# Fonction pour calculer l'impact performance HNSW
function Get-HNSWPerformanceImpact {
    param(
        [int]$CurrentDimensions,
        [int]$NewDimensions
    )
    
    # Impact théorique sur HNSW (basé sur la documentation Qdrant)
    # Plus de dimensions = plus de calculs, plus de mémoire, plus de temps de construction
    $dimensionRatio = $NewDimensions / $CurrentDimensions
    $constructionTimeIncrease = [Math]::Log($dimensionRatio) * 100  # Estimation
    $searchTimeIncrease = [Math]::Sqrt($dimensionRatio) * 100 - 100  # Estimation
    
    return @{
        DimensionRatio = $dimensionRatio
        ConstructionTimeIncrease = $constructionTimeIncrease
        SearchTimeIncrease = $searchTimeIncrease
        MemoryUsageIncrease = ($dimensionRatio - 1) * 100
    }
}

# Fonction pour récupérer les informations des collections
function Get-CollectionsInfo {
    param([string]$Endpoint, [string]$ApiKey)
    
    Write-Host "📋 Récupération des informations des collections..." -ForegroundColor $ColorInfo
    
    try {
        $headers = @{}
        if ($ApiKey) {
            $headers["api-key"] = $ApiKey
        }
        
        $response = Invoke-RestMethod -Uri "$Endpoint/collections" -Method Get -Headers $headers -TimeoutSec 10
        $collections = $response.result.collections
        
        Write-Host "   ✅ $($collections.Count) collections trouvées" -ForegroundColor $ColorSuccess
        
        $collectionsInfo = @()
        
        foreach ($collection in $collections) {
            try {
                $detailResponse = Invoke-RestMethod -Uri "$Endpoint/collections/$($collection.name)" -Method Get -Headers $headers -TimeoutSec 5
                $detail = $detailResponse.result
                
                $collectionsInfo += @{
                    Name = $collection.name
                    Points = $detail.points_count
                    Vectors = $detail.vectors.size
                    Status = $detail.status
                    Distance = $detail.vectors.distance
                    DiskUsage = $detail.disk_usage_bytes
                    IndexedVectors = $detail.indexed_vectors_count
                    IndexingThreshold = $detail.config.optimizer_config.indexing_threshold
                }
                
                if ($Verbose) {
                    Write-Host "      📁 $($collection.name): $($detail.points_count) points, $($detail.vectors.size) dimensions" -ForegroundColor $ColorInfo
                }
            }
            catch {
                Write-Host "   ⚠️ Erreur récupération détails pour $($collection.name): $($_.Exception.Message)" -ForegroundColor $ColorWarning
            }
        }
        
        return $collectionsInfo
    }
    catch {
        Write-Host "   ❌ Erreur récupération collections: $($_.Exception.Message)" -ForegroundColor $ColorError
        return @()
    }
}

# Fonction pour analyser une collection
function Analyze-Collection {
    param(
        [hashtable]$Collection,
        [int]$TargetDimensions
    )
    
    $name = $Collection.Name
    $currentPoints = $Collection.Points
    $currentDimensions = $Collection.Vectors
    
    Write-Host "🔍 Analyse de la collection: $name" -ForegroundColor $ColorInfo
    Write-Host "   Points actuels: $currentPoints" -ForegroundColor $ColorInfo
    Write-Host "   Dimensions actuelles: $currentDimensions" -ForegroundColor $ColorInfo
    Write-Host "   Dimensions cibles: $TargetDimensions" -ForegroundColor $ColorInfo
    
    # Calculer les impacts
    $memoryImpact = Get-MemoryImpact -CurrentPoints $currentPoints -CurrentDimensions $currentDimensions -NewDimensions $TargetDimensions
    $storageImpact = Get-StorageImpact -CurrentPoints $currentPoints -CurrentDimensions $currentDimensions -NewDimensions $TargetDimensions
    $hnswImpact = Get-HNSWPerformanceImpact -CurrentDimensions $currentDimensions -NewDimensions $TargetDimensions
    
    # Afficher les résultats
    Write-Host ""
    Write-Host "   💾 IMPACT MÉMOIRE:" -ForegroundColor $ColorHeader
    Write-Host "      Taille vecteur actuelle: $($memoryImpact.CurrentVectorSize) bytes" -ForegroundColor $ColorInfo
    Write-Host "      Taille vecteur cible: $($memoryImpact.NewVectorSize) bytes" -ForegroundColor $ColorInfo
    Write-Host "      Augmentation par vecteur: $($memoryImpact.MemoryIncreasePerVector) bytes (+$("{0:F1}" -f $memoryImpact.MemoryIncreasePercent)%)" -ForegroundColor $ColorWarning
    Write-Host "      Total actuel: $("{0:N0}" -f $memoryImpact.CurrentTotalMemory) bytes ($("{0:N2}" -f ($memoryImpact.CurrentTotalMemory / 1MB))) MB" -ForegroundColor $ColorInfo
    Write-Host "      Total cible: $("{0:N0}" -f $memoryImpact.NewTotalMemory) bytes ($("{0:N2}" -f ($memoryImpact.NewTotalMemory / 1MB))) MB" -ForegroundColor $ColorInfo
    Write-Host "      Augmentation totale: $("{0:N0}" -f $memoryImpact.TotalMemoryIncrease) bytes ($("{0:N2}" -f ($memoryImpact.TotalMemoryIncrease / 1MB))) MB" -ForegroundColor $ColorWarning
    
    Write-Host ""
    Write-Host "   💿 IMPACT STOCKAGE:" -ForegroundColor $ColorHeader
    Write-Host "      Stockage actuel: $("{0:N2}" -f ($storageImpact.CurrentTotalStorage / 1GB))) GB" -ForegroundColor $ColorInfo
    Write-Host "      Stockage cible: $("{0:N2}" -f ($storageImpact.NewTotalStorage / 1GB))) GB" -ForegroundColor $ColorInfo
    Write-Host "      Augmentation: $("{0:N2}" -f ($storageImpact.TotalStorageIncrease / 1GB))) GB (+$("{0:F1}" -f $storageImpact.StorageIncreasePercent)%)" -ForegroundColor $ColorWarning
    
    Write-Host ""
    Write-Host "   ⚡ IMPACT PERFORMANCE HNSW:" -ForegroundColor $ColorHeader
    Write-Host "      Ratio dimensions: $("{0:F2}" -f $hnswImpact.DimensionRatio)x" -ForegroundColor $ColorInfo
    Write-Host "      Temps construction: +$("{0:F1}" -f $hnswImpact.ConstructionTimeIncrease)%" -ForegroundColor $ColorWarning
    Write-Host "      Temps recherche: +$("{0:F1}" -f $hnswImpact.SearchTimeIncrease)%" -ForegroundColor $ColorWarning
    Write-Host "      Usage mémoire: +$("{0:F1}" -f $hnswImpact.MemoryUsageIncrease)%" -ForegroundColor $ColorWarning
    
    # Recommandations spécifiques
    Write-Host ""
    Write-Host "   💡 RECOMMANDATIONS POUR CETTE COLLECTION:" -ForegroundColor $ColorHeader
    
    if ($currentPoints -gt 100000) {
        Write-Host "      ⚠️ Grande collection ($currentPoints points):" -ForegroundColor $ColorWarning
        Write-Host "         • Prévoir augmentation RAM significative" -ForegroundColor $ColorInfo
        Write-Host "         • Considérer quantization (int8)" -ForegroundColor $ColorInfo
        Write-Host "         • Planifier migration par lots" -ForegroundColor $ColorInfo
    }
    
    if ($currentDimensions -eq 1536) {
        Write-Host "      ✅ Migration OpenAI→Qwen3:" -ForegroundColor $ColorSuccess
        Write-Host "         • Recréer collection avec 4096 dimensions" -ForegroundColor $ColorInfo
        Write-Host "         • Mettre à jour configuration client" -ForegroundColor $ColorInfo
        Write-Host "         • Tester avec quelques points d'abord" -ForegroundColor $ColorInfo
    }
    
    if ($Collection.IndexingThreshold -lt 10000) {
        Write-Host "      🔧 Optimisation HNSW:" -ForegroundColor $ColorInfo
        Write-Host "         • Augmenter indexing_threshold à 20000-30000" -ForegroundColor $ColorInfo
        Write-Host "         • Configurer max_indexing_threads: 2-4" -ForegroundColor $ColorInfo
        Write-Host "         • Activer on_disk: true" -ForegroundColor $ColorInfo
    }
    
    return @{
        Collection = $Collection
        MemoryImpact = $memoryImpact
        StorageImpact = $storageImpact
        HNSWImpact = $hnswImpact
    }
}

# Programme principal
function Main {
    Write-Host "🔧 Configuration:" -ForegroundColor $ColorHeader
    Write-Host "   Endpoint Qdrant: $QdrantEndpoint" -ForegroundColor $ColorInfo
    Write-Host "   API Key: $(if ($ApiKey) { '***' + $ApiKey.Substring($ApiKey.Length-4) } else { 'Non fournie' })" -ForegroundColor $ColorInfo
    Write-Host "   Dimensions cibles: 4096 (Qwen3 8B)" -ForegroundColor $ColorInfo
    Write-Host "   Verbose: $Verbose" -ForegroundColor $ColorInfo
    Write-Host ""
    
    # Récupérer les informations des collections
    $collections = Get-CollectionsInfo -Endpoint $QdrantEndpoint -ApiKey $ApiKey
    
    if ($collections.Count -eq 0) {
        Write-Host "❌ Aucune collection trouvée. Arrêt." -ForegroundColor $ColorError
        exit 1
    }
    
    Write-Host ""
    Write-Host "📈 ANALYSE DÉTAILLÉE PAR COLLECTION" -ForegroundColor $ColorHeader
    Write-Host "=====================================" -ForegroundColor $ColorHeader
    Write-Host ""
    
    $allAnalyses = @()
    $totalMemoryIncrease = 0
    $totalStorageIncrease = 0
    $totalPoints = 0
    
    # Analyser chaque collection
    foreach ($collection in $collections) {
        $analysis = Analyze-Collection -Collection $collection -TargetDimensions 4096
        $allAnalyses += $analysis
        $totalMemoryIncrease += $analysis.MemoryImpact.TotalMemoryIncrease
        $totalStorageIncrease += $analysis.StorageImpact.TotalStorageIncrease
        $totalPoints += $collection.Points
    }
    
    # Résumé global
    Write-Host ""
    Write-Host "🌍 RÉSUMÉ GLOBAL DE LA MIGRATION" -ForegroundColor $ColorHeader
    Write-Host "=================================" -ForegroundColor $ColorHeader
    Write-Host ""
    
    Write-Host "📊 STATISTIQUES:" -ForegroundColor $ColorInfo
    Write-Host "   Collections analysées: $($collections.Count)" -ForegroundColor $ColorInfo
    Write-Host "   Points totaux: $("{0:N0}" -f $totalPoints)" -ForegroundColor $ColorInfo
    Write-Host "   Collections nécessitant migration: $($allAnalyses.Count)" -ForegroundColor $ColorWarning
    
    Write-Host ""
    Write-Host "💾 IMPACT MÉMOIRE TOTAL:" -ForegroundColor $ColorHeader
    Write-Host "   Augmentation totale: $("{0:N2}" -f ($totalMemoryIncrease / 1MB))) MB" -ForegroundColor $ColorWarning
    Write-Host "   Par collection moyenne: $("{0:N2}" -f (($totalMemoryIncrease / $allAnalyses.Count) / 1MB))) MB" -ForegroundColor $ColorInfo
    
    Write-Host ""
    Write-Host "💿 IMPACT STOCKAGE TOTAL:" -ForegroundColor $ColorHeader
    Write-Host "   Augmentation totale: $("{0:N2}" -f ($totalStorageIncrease / 1GB))) GB" -ForegroundColor $ColorWarning
    Write-Host "   Par collection moyenne: $("{0:N2}" -f (($totalStorageIncrease / $allAnalyses.Count) / 1GB))) GB" -ForegroundColor $ColorInfo
    
    # Identifier les collections critiques
    Write-Host ""
    Write-Host "⚠️ COLLECTIONS CRITIQUES (impact > 100MB):" -ForegroundColor $ColorWarning
    $criticalCollections = $allAnalyses | Where-Object { $_.MemoryImpact.TotalMemoryIncrease -gt (100MB) }
    
    foreach ($analysis in $criticalCollections) {
        $collection = $analysis.Collection
        $increaseMB = $analysis.MemoryImpact.TotalMemoryIncrease / 1MB
        Write-Host "   🚨 $($collection.Name): +$("{0:N1}" -f $increaseMB) MB ($collection.Points points)" -ForegroundColor $ColorError
    }
    
    if ($criticalCollections.Count -eq 0) {
        Write-Host "   ✅ Aucune collection critique (toutes < 100MB d'augmentation)" -ForegroundColor $ColorSuccess
    }
    
    # Recommandations générales
    Write-Host ""
    Write-Host "💡 RECOMMANDATIONS GÉNÉRALES:" -ForegroundColor $ColorHeader
    Write-Host "   1. 🔄 MIGRATION GRADUELLE:" -ForegroundColor $ColorInfo
    Write-Host "      • Traiter les collections par ordre de taille croissante" -ForegroundColor $ColorInfo
    Write-Host "      • Tester sur une collection petite d'abord" -ForegroundColor $ColorInfo
    Write-Host "      • Valider avant de passer aux plus grandes" -ForegroundColor $ColorInfo
    
    Write-Host ""
    Write-Host "   2. 💾 RESSOURCES:" -ForegroundColor $ColorInfo
    Write-Host "      • Prévoir 2-3x plus de RAM par collection" -ForegroundColor $ColorInfo
    Write-Host "      • Surveiller l'utilisation mémoire pendant migration" -ForegroundColor $ColorInfo
    Write-Host "      • Avoir un plan de rollback prêt" -ForegroundColor $ColorInfo
    
    Write-Host ""
    Write-Host "   3. 🔧 CONFIGURATION QDRANT:" -ForegroundColor $ColorInfo
    Write-Host "      • indexing_threshold: 20000-30000 (pour 4096 dimensions)" -ForegroundColor $ColorInfo
    Write-Host "      • max_indexing_threads: 2-4 (limité par CPU)" -ForegroundColor $ColorInfo
    Write-Host "      • hnsw_config.on_disk: true (économie RAM)" -ForegroundColor $ColorInfo
    Write-Host "      • quantization_config: int8 (si mémoire limitée)" -ForegroundColor $ColorInfo
    
    Write-Host ""
    Write-Host "   4. 🧪 TESTS:" -ForegroundColor $ColorInfo
    Write-Host "      • Valider dimensions avec Qwen3 avant migration" -ForegroundColor $ColorInfo
    Write-Host "      • Tester performance post-migration" -ForegroundColor $ColorInfo
    Write-Host "      • Vérifier compatibilité avec applications existantes" -ForegroundColor $ColorInfo
    
    # Générer le rapport
    $report = @{
        GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Collections = $collections.Count
        TotalPoints = $totalPoints
        TargetDimensions = 4096
        TotalMemoryIncreaseMB = [math]::Round($totalMemoryIncrease / 1MB, 2)
        TotalStorageIncreaseGB = [math]::Round($totalStorageIncrease / 1GB, 2)
        CriticalCollections = $criticalCollections.Count
        Analyses = $allAnalyses
    }
    
    $reportPath = "myia_qdrant/reports/migration_impact_1536_to_4096_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $report | ConvertTo-Json -Depth 4 | Out-File -FilePath $reportPath -Encoding UTF8
    
    Write-Host ""
    Write-Host "📄 Rapport généré: $reportPath" -ForegroundColor $ColorSuccess
    
    Write-Host ""
    Write-Host "✅ Analyse terminée. Prêt pour planification de la migration." -ForegroundColor $ColorSuccess
}

# Exécution principale
try {
    Main
}
catch {
    Write-Host "💥 Erreur inattendue: $($_.Exception.Message)" -ForegroundColor $ColorError
    Write-Host "📍 Stack trace: $($_.ScriptStackTrace)" -ForegroundColor $ColorWarning
    exit 99
}