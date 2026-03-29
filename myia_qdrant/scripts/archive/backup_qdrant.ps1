# Script de Sauvegarde Unifié Qdrant
# Date: 2025-10-13
# Usage: Sauvegarde complète de Qdrant avec snapshots et configuration
#
# EXEMPLES:
#   .\backup_qdrant.ps1                                              # Backup instance production par défaut
#   .\backup_qdrant.ps1 -EnvFile ".env.students" -Port 6335          # Backup instance Students
#   .\backup_qdrant.ps1 -Collections "col1","col2"                   # Backup collections spécifiques
#   .\backup_qdrant.ps1 -SkipSnapshot                                # Backup config seulement
#   .\backup_qdrant.ps1 -BackupDir "backups/custom"                  # Répertoire personnalisé

[CmdletBinding()]
param(
    [string]$EnvFile = ".env.production",                # Fichier .env à utiliser
    [int]$Port = 6333,                                   # Port Qdrant
    [string]$ContainerName = "qdrant_production",        # Nom du container Docker
    [string[]]$Collections = @(),                        # Collections spécifiques (vide = toutes)
    [string]$BackupDir = "backups/production",           # Répertoire de sauvegarde
    [switch]$SkipSnapshot = $false,                      # Ne pas créer de snapshots
    [switch]$SkipConfig = $false,                        # Ne pas sauvegarder la config
    [switch]$CompressBackup = $false                     # Compresser le backup
)

$ErrorActionPreference = "Stop"
$QdrantUrl = "http://localhost:$Port"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDirFull = "$BackupDir/$Timestamp"
$LogFile = "$BackupDirFull/backup.log"

# Créer le répertoire de backup
New-Item -ItemType Directory -Force -Path $BackupDirFull | Out-Null

# Fonction de logging
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Afficher dans la console avec couleur
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    
    Write-Host $logMessage -ForegroundColor $color
    
    # Écrire dans le fichier de log
    Add-Content -Path $LogFile -Value $logMessage
}

# Fonction pour récupérer l'API key
function Get-ApiKey {
    param([string]$EnvPath)
    
    if (-not (Test-Path $EnvPath)) {
        throw "Fichier .env introuvable: $EnvPath"
    }
    
    $envContent = Get-Content $EnvPath
    foreach ($line in $envContent) {
        if ($line -match "^QDRANT.*API_KEY=(.+)$") {
            return $matches[1]
        }
    }
    
    throw "Impossible de récupérer l'API key depuis $EnvPath"
}

# Fonction pour vérifier le service
function Test-QdrantService {
    param([string]$Url, [string]$ApiKey)
    
    try {
        $headers = @{ 'api-key' = $ApiKey }
        $response = Invoke-RestMethod -Uri "$Url/healthz" -Headers $headers -Method Get -TimeoutSec 5
        return $true
    }
    catch {
        return $false
    }
}

# Fonction pour récupérer les collections
function Get-QdrantCollections {
    param([string]$Url, [string]$ApiKey)
    
    $headers = @{
        'api-key' = $ApiKey
        'Content-Type' = 'application/json'
    }
    
    try {
        $response = Invoke-RestMethod -Uri "$Url/collections" -Headers $headers -Method Get
        return $response.result.collections.name
    }
    catch {
        throw "Échec de récupération des collections: $($_.Exception.Message)"
    }
}

# Fonction pour créer un snapshot
function New-CollectionSnapshot {
    param(
        [string]$Url,
        [string]$ApiKey,
        [string]$CollectionName
    )
    
    $headers = @{
        'api-key' = $ApiKey
        'Content-Type' = 'application/json'
    }
    
    $snapshotUrl = "$Url/collections/$CollectionName/snapshots"
    
    try {
        $response = Invoke-RestMethod -Uri $snapshotUrl -Headers $headers -Method Post -Body "{}"
        
        if ($response.status -eq 'ok') {
            return @{
                Success = $true
                SnapshotName = $response.result.name
                Message = "Snapshot créé avec succès"
            }
        }
        else {
            return @{
                Success = $false
                Message = "Échec de création du snapshot (statut: $($response.status))"
            }
        }
    }
    catch {
        return @{
            Success = $false
            Message = "Erreur: $($_.Exception.Message)"
        }
    }
}

# Fonction pour sauvegarder la configuration
function Backup-Configuration {
    param([string]$BackupPath)
    
    Write-Log "Sauvegarde de la configuration..." "INFO"
    
    $configFiles = @(
        $EnvFile,
        "docker-compose.yml",
        "docker-compose.production.yml",
        "docker-compose.production.optimized.yml",
        "config/*.yaml"
    )
    
    $savedFiles = @()
    
    foreach ($pattern in $configFiles) {
        $files = Get-ChildItem $pattern -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $destPath = Join-Path $BackupPath "config/$($file.Name)"
            New-Item -ItemType Directory -Force -Path (Split-Path $destPath) | Out-Null
            Copy-Item $file.FullName -Destination $destPath -Force
            $savedFiles += $file.Name
            Write-Log "  ✓ $($file.Name)" "SUCCESS"
        }
    }
    
    return $savedFiles
}

# Fonction pour sauvegarder les métadonnées des collections
function Backup-CollectionsMetadata {
    param(
        [string]$Url,
        [string]$ApiKey,
        [string[]]$CollectionNames,
        [string]$BackupPath
    )
    
    $headers = @{
        'api-key' = $ApiKey
        'Content-Type' = 'application/json'
    }
    
    $metadata = @{
        Timestamp = Get-Date -Format 'o'
        QdrantUrl = $Url
        Collections = @()
    }
    
    foreach ($colName in $CollectionNames) {
        try {
            $colInfo = Invoke-RestMethod -Uri "$Url/collections/$colName" -Headers $headers -Method Get
            $metadata.Collections += @{
                Name = $colName
                Status = $colInfo.result.status
                VectorsCount = $colInfo.result.vectors_count
                PointsCount = $colInfo.result.points_count
                Config = $colInfo.result.config
            }
        }
        catch {
            Write-Log "  ⚠ Impossible de récupérer les métadonnées de $colName" "WARNING"
        }
    }
    
    $metadataPath = Join-Path $BackupPath "collections_metadata.json"
    $metadata | ConvertTo-Json -Depth 10 | Out-File $metadataPath
    
    return $metadataPath
}

# DÉBUT DU SCRIPT PRINCIPAL
Write-Log "═══════════════════════════════════════════════════════" "INFO"
Write-Log "  Qdrant Backup Script" "INFO"
Write-Log "═══════════════════════════════════════════════════════" "INFO"
Write-Log ""
Write-Log "Configuration:" "INFO"
Write-Log "  Environment: $EnvFile" "INFO"
Write-Log "  Port: $Port" "INFO"
Write-Log "  Container: $ContainerName" "INFO"
Write-Log "  Backup Directory: $BackupDirFull" "INFO"
Write-Log ""

try {
    # 1. Récupérer l'API key
    Write-Log "Récupération de l'API key..." "INFO"
    $apiKey = Get-ApiKey -EnvPath $EnvFile
    Write-Log "✓ API key récupérée" "SUCCESS"
    
    # 2. Vérifier que le service est accessible
    Write-Log "Vérification du service Qdrant..." "INFO"
    if (-not (Test-QdrantService -Url $QdrantUrl -ApiKey $apiKey)) {
        throw "Le service Qdrant n'est pas accessible sur $QdrantUrl"
    }
    Write-Log "✓ Service Qdrant accessible" "SUCCESS"
    
    # 3. Récupérer la liste des collections
    Write-Log "Récupération de la liste des collections..." "INFO"
    $allCollections = Get-QdrantCollections -Url $QdrantUrl -ApiKey $apiKey
    
    # Filtrer les collections si spécifié
    $collectionsToBackup = if ($Collections.Count -gt 0) {
        $allCollections | Where-Object { $Collections -contains $_ }
    } else {
        $allCollections
    }
    
    Write-Log "Collections à sauvegarder: $($collectionsToBackup -join ', ')" "INFO"
    Write-Log ""
    
    # 4. Créer les snapshots
    if (-not $SkipSnapshot) {
        Write-Log "Création des snapshots..." "INFO"
        $snapshotResults = @()
        
        foreach ($colName in $collectionsToBackup) {
            Write-Log "  Collection: $colName" "INFO"
            $result = New-CollectionSnapshot -Url $QdrantUrl -ApiKey $apiKey -CollectionName $colName
            
            if ($result.Success) {
                Write-Log "    ✓ $($result.SnapshotName)" "SUCCESS"
                $snapshotResults += @{
                    Collection = $colName
                    Success = $true
                    Snapshot = $result.SnapshotName
                }
            }
            else {
                Write-Log "    ✗ $($result.Message)" "ERROR"
                $snapshotResults += @{
                    Collection = $colName
                    Success = $false
                    Error = $result.Message
                }
            }
        }
        
        # Sauvegarder le résumé des snapshots
        $snapshotResults | ConvertTo-Json -Depth 10 | Out-File "$BackupDirFull/snapshots_summary.json"
    }
    else {
        Write-Log "Création de snapshots ignorée (SkipSnapshot)" "WARNING"
    }
    
    Write-Log ""
    
    # 5. Sauvegarder la configuration
    if (-not $SkipConfig) {
        Write-Log "Sauvegarde de la configuration..." "INFO"
        $configFiles = Backup-Configuration -BackupPath $BackupDirFull
        Write-Log "✓ $($configFiles.Count) fichiers de configuration sauvegardés" "SUCCESS"
    }
    else {
        Write-Log "Sauvegarde de configuration ignorée (SkipConfig)" "WARNING"
    }
    
    Write-Log ""
    
    # 6. Sauvegarder les métadonnées des collections
    Write-Log "Sauvegarde des métadonnées des collections..." "INFO"
    $metadataPath = Backup-CollectionsMetadata -Url $QdrantUrl -ApiKey $apiKey -CollectionNames $collectionsToBackup -BackupPath $BackupDirFull
    Write-Log "✓ Métadonnées sauvegardées: $metadataPath" "SUCCESS"
    
    # 7. Compression (optionnelle)
    if ($CompressBackup) {
        Write-Log ""
        Write-Log "Compression du backup..." "INFO"
        $zipPath = "$BackupDir/backup_$Timestamp.zip"
        Compress-Archive -Path "$BackupDirFull/*" -DestinationPath $zipPath -Force
        Write-Log "✓ Backup compressé: $zipPath" "SUCCESS"
    }
    
    # Résumé final
    Write-Log ""
    Write-Log "═══════════════════════════════════════════════════════" "INFO"
    Write-Log "  Backup terminé avec succès!" "SUCCESS"
    Write-Log "═══════════════════════════════════════════════════════" "INFO"
    Write-Log "Emplacement du backup: $BackupDirFull" "INFO"
    Write-Log "Log complet: $LogFile" "INFO"
    
}
catch {
    Write-Log ""
    Write-Log "ERREUR FATALE: $($_.Exception.Message)" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}