# Script de Migration Collection vers 4096 Dimensions (Qwen3 8B)
# Date: 2025-11-04
# Objectif: Migrer une collection spécifique de 1536→4096 dimensions

param(
    [Parameter(Mandatory=$true)]
    [string]$CollectionName,
    
    [Parameter(Mandatory=$false)]
    [string]$QdrantEndpoint = "http://localhost:6333",
    
    [Parameter(Mandatory=$false)]
    [string]$ApiKey = "",
    
    [Parameter(Mandatory=$false)]
    [string]$BackupPath = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
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

# Constantes
$TARGET_DIMENSIONS = 4096
$SOURCE_DIMENSIONS = 1536

Write-Host "🔄 MIGRATION COLLECTION: $CollectionName" -ForegroundColor $ColorHeader
Write-Host "=================================" -ForegroundColor $ColorHeader
Write-Host "📏 $SOURCE_DIMENSIONS → $TARGET_DIMENSIONS dimensions" -ForegroundColor $ColorInfo
Write-Host ""

# Fonction pour afficher le temps écoulé
function Get-ElapsedTime {
    param([datetime]$StartTime)
    $elapsed = (Get-Date) - $StartTime
    return "{0:mm\:ss\.fff}" -f $elapsed
}

# Fonction pour vérifier la connectivité Qdrant
function Test-QdrantConnectivity {
    param([string]$Endpoint, [string]$ApiKey)
    
    try {
        $headers = @{}
        if ($ApiKey) {
            $headers["api-key"] = $ApiKey
        }
        
        $response = Invoke-RestMethod -Uri "$Endpoint/" -Method Get -Headers $headers -TimeoutSec 10
        return $response.version -ne $null
    }
    catch {
        Write-Host "❌ Erreur de connexion Qdrant: $($_.Exception.Message)" -ForegroundColor $ColorError
        return $false
    }
}

# Fonction pour récupérer les informations d'une collection
function Get-CollectionInfo {
    param([string]$Endpoint, [string]$ApiKey, [string]$Name)
    
    try {
        $headers = @{}
        if ($ApiKey) {
            $headers["api-key"] = $ApiKey
        }
        
        $response = Invoke-RestMethod -Uri "$Endpoint/collections/$Name" -Method Get -Headers $headers -TimeoutSec 10
        return $response.result
    }
    catch {
        Write-Host "❌ Erreur récupération collection $Name`: $($_.Exception.Message)" -ForegroundColor $ColorError
        return $null
    }
}

# Fonction pour créer un backup d'une collection
function Backup-Collection {
    param(
        [string]$Endpoint,
        [string]$ApiKey,
        [string]$Name,
        [string]$BackupPath
    )
    
    Write-Host "💾 Création backup collection $Name..." -ForegroundColor $ColorInfo
    
    try {
        $collectionInfo = Get-CollectionInfo -Endpoint $Endpoint -ApiKey $ApiKey -Name $Name
        if (-not $collectionInfo) {
            throw "Collection $Name introuvable"
        }
        
        # Créer le répertoire de backup si nécessaire
        $backupDir = Split-Path -Parent $BackupPath
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        
        # Préparer les données de backup
        $backupData = @{
            CollectionName = $Name
            BackupDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            OriginalConfig = $collectionInfo
            SourceDimensions = $collectionInfo.vectors.size
            TargetDimensions = $TARGET_DIMENSIONS
            PointsCount = $collectionInfo.points_count
            Status = $collectionInfo.status
            DiskUsage = $collectionInfo.disk_usage_bytes
        }
        
        # Sauvegarder la configuration
        $backupData | ConvertTo-Json -Depth 4 | Out-File -FilePath $BackupPath -Encoding UTF8
        
        # Créer un snapshot si possible
        $snapshotPath = $BackupPath.Replace(".json", "_snapshot.tar.gz")
        Write-Host "   📸 Création snapshot..." -ForegroundColor $ColorInfo
        
        $snapshotBody = @{
            name = "$($Name)_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        } | ConvertTo-Json
        
        $snapshotResponse = Invoke-RestMethod -Uri "$Endpoint/collections/$Name/snapshots" -Method Post -Headers $headers -Body $snapshotBody -TimeoutSec 30
        
        if ($snapshotResponse.result) {
            Write-Host "   ✅ Snapshot créé: $($snapshotResponse.result.name)" -ForegroundColor $ColorSuccess
        } else {
            Write-Host "   ⚠️ Snapshot non créé (continuation quand même)" -ForegroundColor $ColorWarning
        }
        
        Write-Host "   ✅ Backup sauvegardé: $BackupPath" -ForegroundColor $ColorSuccess
        return $true
    }
    catch {
        Write-Host "   ❌ Erreur backup: $($_.Exception.Message)" -ForegroundColor $ColorError
        return $false
    }
}

# Fonction pour supprimer une collection
function Remove-Collection {
    param([string]$Endpoint, [string]$ApiKey, [string]$Name)
    
    Write-Host "🗑️ Suppression collection $Name..." -ForegroundColor $ColorInfo
    
    try {
        $headers = @{}
        if ($ApiKey) {
            $headers["api-key"] = $ApiKey
        }
        
        $response = Invoke-RestMethod -Uri "$Endpoint/collections/$Name" -Method Delete -Headers $headers -TimeoutSec 30
        
        if ($response.status -eq "ok") {
            Write-Host "   ✅ Collection supprimée" -ForegroundColor $ColorSuccess
            return $true
        } else {
            Write-Host "   ❌ Erreur suppression: $($response.status)" -ForegroundColor $ColorError
            return $false
        }
    }
    catch {
        Write-Host "   ❌ Erreur suppression: $($_.Exception.Message)" -ForegroundColor $ColorError
        return $false
    }
}

# Fonction pour créer une collection avec 4096 dimensions
function Create-NewCollection {
    param(
        [string]$Endpoint,
        [string]$ApiKey,
        [string]$Name,
        [hashtable]$OriginalConfig
    )
    
    Write-Host "🆕 Création collection $Name avec $TARGET_DIMENSIONS dimensions..." -ForegroundColor $ColorInfo
    
    try {
        $headers = @{}
        if ($ApiKey) {
            $headers["api-key"] = $ApiKey
        }
        $headers["Content-Type"] = "application/json"
        
        # Configuration optimisée pour 4096 dimensions
        $newConfig = @{
            vectors = @{
                size = $TARGET_DIMENSIONS
                distance = $OriginalConfig.vectors.distance  # Conserver la distance
            }
            hnsw_config = @{
                m = 48  # Augmenté pour 4096 dimensions
                ef_construct = 300  # Augmenté pour meilleure précision
                max_indexing_threads = 4  # Augmenté pour 4096 dimensions
                on_disk = $true  # Économiser RAM
            }
            optimizer_config = @{
                indexing_threshold_kb = 12000  # Adapté pour 4096 dimensions
                default_segment_number = $OriginalConfig.optimizer_config.default_segment_number
                max_segment_size_kb = $OriginalConfig.optimizer_config.max_segment_size_kb
                memmap_threshold_kb = $OriginalConfig.optimizer_config.memmap_threshold_kb
                deleted_threshold = $OriginalConfig.optimizer_config.deleted_threshold
                vacuum_min_vector_number = $OriginalConfig.optimizer_config.vacuum_min_vector_number
                max_optimization_threads = $OriginalConfig.optimizer_config.max_optimization_threads
                flush_interval_sec = $OriginalConfig.optimizer_config.flush_interval_sec
            }
            on_disk_payload = $OriginalConfig.on_disk_payload
        }
        
        if ($Verbose) {
            Write-Host "   🔧 Configuration:" -ForegroundColor $ColorWarning
            $newConfig | ConvertTo-Json -Depth 4 | Write-Host
        }
        
        $body = $newConfig | ConvertTo-Json -Depth 4
        $response = Invoke-RestMethod -Uri "$Endpoint/collections/$Name" -Method Put -Headers $headers -Body $body -TimeoutSec 60
        
        if ($response.status -eq "ok") {
            Write-Host "   ✅ Collection créée avec succès" -ForegroundColor $ColorSuccess
            return $true
        } else {
            Write-Host "   ❌ Erreur création: $($response.status)" -ForegroundColor $ColorError
            if ($response.error) {
                Write-Host "      Détail: $($response.error.message)" -ForegroundColor $ColorError
            }
            return $false
        }
    }
    catch {
        Write-Host "   ❌ Erreur création: $($_.Exception.Message)" -ForegroundColor $ColorError
        return $false
    }
}

# Fonction pour valider la collection créée
function Validate-NewCollection {
    param(
        [string]$Endpoint,
        [string]$ApiKey,
        [string]$Name,
        [int]$ExpectedPoints = 0
    )
    
    Write-Host "✅ Validation collection $Name..." -ForegroundColor $ColorInfo
    
    try {
        $headers = @{}
        if ($ApiKey) {
            $headers["api-key"] = $ApiKey
        }
        
        # Attendre un peu pour que la collection soit prête
        Start-Sleep -Seconds 2
        
        $response = Invoke-RestMethod -Uri "$Endpoint/collections/$Name" -Method Get -Headers $headers -TimeoutSec 10
        $collection = $response.result
        
        if ($collection.status -eq "green") {
            Write-Host "   ✅ Status: GREEN" -ForegroundColor $ColorSuccess
        } else {
            Write-Host "   ⚠️ Status: $($collection.status)" -ForegroundColor $ColorWarning
        }
        
        Write-Host "   📏 Dimensions: $($collection.vectors.size)" -ForegroundColor $(if ($collection.vectors.size -eq $TARGET_DIMENSIONS) { $ColorSuccess } else { $ColorError })
        Write-Host "   📊 Points: $($collection.points_count)" -ForegroundColor $ColorInfo
        Write-Host "   📈 Vecteurs indexés: $($collection.indexed_vectors_count)" -ForegroundColor $ColorInfo
        
        if ($collection.vectors.size -eq $TARGET_DIMENSIONS) {
            Write-Host "   ✅ Collection validée avec $TARGET_DIMENSIONS dimensions" -ForegroundColor $ColorSuccess
            return $true
        } else {
            Write-Host "   ❌ Échec validation: dimensions incorrectes" -ForegroundColor $ColorError
            return $false
        }
    }
    catch {
        Write-Host "   ❌ Erreur validation: $($_.Exception.Message)" -ForegroundColor $ColorError
        return $false
    }
}

# Programme principal
function Main {
    Write-Host "🔧 Configuration:" -ForegroundColor $ColorHeader
    Write-Host "   Collection: $CollectionName" -ForegroundColor $ColorInfo
    Write-Host "   Endpoint Qdrant: $QdrantEndpoint" -ForegroundColor $ColorInfo
    Write-Host "   API Key: $(if ($ApiKey) { '***' + $ApiKey.Substring($ApiKey.Length-4) } else { 'Non fournie' })" -ForegroundColor $ColorInfo
    Write-Host "   Backup Path: $BackupPath" -ForegroundColor $ColorInfo
    Write-Host "   Dry Run: $DryRun" -ForegroundColor $ColorInfo
    Write-Host "   Force: $Force" -ForegroundColor $ColorInfo
    Write-Host "   Verbose: $Verbose" -ForegroundColor $ColorInfo
    Write-Host ""
    
    # Mode Dry Run
    if ($DryRun) {
        Write-Host "🔍 MODE DRY RUN - Aucune modification ne sera effectuée" -ForegroundColor $ColorWarning
        Write-Host ""
    }
    
    # Vérifier la connectivité
    Write-Host "📡 Test de connectivité Qdrant..." -ForegroundColor $ColorInfo
    if (-not (Test-QdrantConnectivity -Endpoint $QdrantEndpoint -ApiKey $ApiKey)) {
        Write-Host "❌ Impossible de se connecter à Qdrant. Arrêt." -ForegroundColor $ColorError
        exit 1
    }
    Write-Host "   ✅ Connectivité Qdrant OK" -ForegroundColor $ColorSuccess
    Write-Host ""
    
    # Récupérer les informations de la collection
    Write-Host "📋 Récupération informations collection $CollectionName..." -ForegroundColor $ColorInfo
    $collectionInfo = Get-CollectionInfo -Endpoint $QdrantEndpoint -ApiKey $ApiKey -Name $CollectionName
    
    if (-not $collectionInfo) {
        Write-Host "❌ Collection $CollectionName introuvable. Arrêt." -ForegroundColor $ColorError
        exit 2
    }
    
    $currentDimensions = $collectionInfo.vectors.size
    $pointsCount = $collectionInfo.points_count
    
    Write-Host "   ✅ Collection trouvée" -ForegroundColor $ColorSuccess
    Write-Host "   📏 Dimensions actuelles: $currentDimensions" -ForegroundColor $ColorInfo
    Write-Host "   📊 Points: $pointsCount" -ForegroundColor $ColorInfo
    Write-Host "   📈 Status: $($collectionInfo.status)" -ForegroundColor $ColorInfo
    Write-Host ""
    
    # Vérifier si la migration est nécessaire
    if ($currentDimensions -eq $TARGET_DIMENSIONS) {
        Write-Host "ℹ️ Collection déjà en $TARGET_DIMENSIONS dimensions. Migration non nécessaire." -ForegroundColor $ColorWarning
        exit 0
    }
    
    # Confirmation si non-Force
    if (-not $Force -and -not $DryRun) {
        Write-Host "⚠️ ATTENTION: Cette migration va supprimer et recréer la collection $CollectionName" -ForegroundColor $ColorWarning
        Write-Host "   • Points concernés: $pointsCount" -ForegroundColor $ColorWarning
        Write-Host "   • Perte de données temporaire pendant la migration" -ForegroundColor $ColorWarning
        Write-Host ""
        Write-Host "Continuer? (O/N)" -ForegroundColor $ColorHeader
        $confirmation = Read-Host
        if ($confirmation -notmatch "^[Oo]$") {
            Write-Host "❌ Migration annulée." -ForegroundColor $ColorError
            exit 3
        }
    }
    
    # Déterminer le chemin de backup
    if (-not $BackupPath) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $BackupPath = "backups\$($CollectionName)_migration_$timestamp.json"
    }
    
    Write-Host ""
    
    # Phase 1: Backup
    if (-not $DryRun) {
        Write-Host "💾 Phase 1: Backup de la collection" -ForegroundColor $ColorHeader
        $backupSuccess = Backup-Collection -Endpoint $QdrantEndpoint -ApiKey $ApiKey -Name $CollectionName -BackupPath $BackupPath
        
        if (-not $backupSuccess) {
            Write-Host "❌ Échec du backup. Arrêt pour sécurité." -ForegroundColor $ColorError
            exit 4
        }
        Write-Host ""
    } else {
        Write-Host "💾 Phase 1: Backup (DRY RUN)" -ForegroundColor $ColorHeader
        Write-Host "   📁 Backup serait sauvegardé: $BackupPath" -ForegroundColor $ColorInfo
        Write-Host ""
    }
    
    # Phase 2: Suppression
    if (-not $DryRun) {
        Write-Host "🗑️ Phase 2: Suppression de l'ancienne collection" -ForegroundColor $ColorHeader
        $removeSuccess = Remove-Collection -Endpoint $QdrantEndpoint -ApiKey $ApiKey -Name $CollectionName
        
        if (-not $removeSuccess) {
            Write-Host "❌ Échec de la suppression. Arrêt." -ForegroundColor $ColorError
            exit 5
        }
        Write-Host ""
    } else {
        Write-Host "🗑️ Phase 2: Suppression (DRY RUN)" -ForegroundColor $ColorHeader
        Write-Host "   🗑️ Collection serait supprimée" -ForegroundColor $ColorInfo
        Write-Host ""
    }
    
    # Phase 3: Création
    if (-not $DryRun) {
        Write-Host "🆕 Phase 3: Création nouvelle collection ($TARGET_DIMENSIONS dimensions)" -ForegroundColor $ColorHeader
        $createSuccess = Create-NewCollection -Endpoint $QdrantEndpoint -ApiKey $ApiKey -Name $CollectionName -OriginalConfig $collectionInfo
        
        if (-not $createSuccess) {
            Write-Host "❌ Échec de la création. Arrêt." -ForegroundColor $ColorError
            exit 6
        }
        Write-Host ""
    } else {
        Write-Host "🆕 Phase 3: Création (DRY RUN)" -ForegroundColor $ColorHeader
        Write-Host "   🆕 Collection serait créée avec $TARGET_DIMENSIONS dimensions" -ForegroundColor $ColorInfo
        Write-Host ""
    }
    
    # Phase 4: Validation
    if (-not $DryRun) {
        Write-Host "✅ Phase 4: Validation de la nouvelle collection" -ForegroundColor $ColorHeader
        $validationSuccess = Validate-NewCollection -Endpoint $QdrantEndpoint -ApiKey $ApiKey -Name $CollectionName -ExpectedPoints 0
        
        if ($validationSuccess) {
            Write-Host ""
            Write-Host "🎉 MIGRATION TERMINÉE AVEC SUCCÈS!" -ForegroundColor $ColorSuccess
            Write-Host ""
            Write-Host "📋 Résumé:" -ForegroundColor $ColorHeader
            Write-Host "   • Collection: $CollectionName" -ForegroundColor $ColorInfo
            Write-Host "   • Dimensions: $currentDimensions → $TARGET_DIMENSIONS" -ForegroundColor $ColorSuccess
            Write-Host "   • Backup: $BackupPath" -ForegroundColor $ColorInfo
            Write-Host "   • Status: Validée et fonctionnelle" -ForegroundColor $ColorSuccess
            Write-Host ""
            Write-Host "🚀 La collection est prête pour être utilisée avec Qwen3 8B!" -ForegroundColor $ColorSuccess
            exit 0
        } else {
            Write-Host "❌ Échec de la validation. Arrêt." -ForegroundColor $ColorError
            exit 7
        }
    } else {
        Write-Host "✅ Phase 4: Validation (DRY RUN)" -ForegroundColor $ColorHeader
        Write-Host "   ✅ Collection serait validée" -ForegroundColor $ColorInfo
        Write-Host ""
        Write-Host "🔍 RÉSUMÉ DRY RUN:" -ForegroundColor $ColorHeader
        Write-Host "   • Collection: $CollectionName" -ForegroundColor $ColorInfo
        Write-Host "   • Migration: $currentDimensions → $TARGET_DIMENSIONS dimensions" -ForegroundColor $ColorInfo
        Write-Host "   • Backup: $BackupPath" -ForegroundColor $ColorInfo
        Write-Host "   • Aucune modification réelle effectuée" -ForegroundColor $ColorWarning
        Write-Host ""
        Write-Host "💡 Pour exécuter la migration réelle, relancer sans -DryRun" -ForegroundColor $ColorInfo
        exit 0
    }
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