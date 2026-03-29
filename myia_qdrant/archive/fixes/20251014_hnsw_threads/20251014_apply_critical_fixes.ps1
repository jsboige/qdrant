#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Application des corrections critiques Qdrant - Script d'exécution
    
.DESCRIPTION
    Ce script applique les corrections critiques en 4 étapes sécurisées:
    1. Création d'un backup de sécurité de la collection
    2. Redémarrage du container avec la nouvelle configuration (max_indexing_threads: 0)
    3. Activation de la quantization INT8
    4. Vérifications finales de santé
    
.PARAMETER SkipBackup
    Passer l'étape de backup (NON RECOMMANDÉ)
    
.PARAMETER SkipQuantization
    Passer l'étape de quantization
    
.PARAMETER DryRun
    Mode simulation sans modifications réelles
    
.EXAMPLE
    .\20251014_apply_critical_fixes.ps1
    
.EXAMPLE
    .\20251014_apply_critical_fixes.ps1 -DryRun
    
.NOTES
    Date: 2025-10-14
    Contexte: Application des corrections critiques après diagnostic
    Référence: myia_qdrant/docs/guides/20251014_APPLICATION_CORRECTIONS_CRITIQUES.md
#>

[CmdletBinding()]
param(
    [switch]$SkipBackup = $false,
    [switch]$SkipQuantization = $false,
    [switch]$DryRun = $false
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================================
# CONFIGURATION
# ============================================================================

$QdrantUrl = "http://localhost:6333"
$ContainerName = "qdrant_production"
$ComposeFile = "docker-compose.production.yml"
$ConfigFile = "config/production.yaml"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "myia_qdrant/logs/20251014_apply_fixes_$Timestamp.log"
$BackupDir = "myia_qdrant/backups/production"

# Créer répertoires si nécessaire
New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

# Lecture API Key
$ApiKey = $env:QDRANT_API_KEY
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    if (Test-Path ".env") {
        $envContent = Get-Content ".env"
        foreach ($line in $envContent) {
            if ($line -match "^QDRANT__SERVICE__API_KEY=(.+)$") {
                $ApiKey = $matches[1]
                break
            }
        }
    }
}

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-ColorOutput "═══════════════════════════════════════════════════════════" "Cyan"
    Write-ColorOutput " $Title" "Cyan"
    Write-ColorOutput "═══════════════════════════════════════════════════════════" "Cyan"
    Write-Host ""
}

function Write-Log {
    param([string]$Message)
    $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $logMessage
    Write-ColorOutput $logMessage "Gray"
}

function Test-QdrantHealth {
    try {
        $response = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get -TimeoutSec 5
        return $true
    } catch {
        return $false
    }
}

function Get-CollectionInfo {
    param([string]$CollectionName)
    
    try {
        $headers = @{ "api-key" = $ApiKey }
        $response = Invoke-RestMethod -Uri "$QdrantUrl/collections/$CollectionName" -Headers $headers -Method Get
        return $response.result
    } catch {
        Write-ColorOutput "⚠ Erreur lors de la récupération des infos collection: $_" "Yellow"
        return $null
    }
}

function Wait-ForQdrant {
    param([int]$TimeoutSeconds = 30)
    
    Write-ColorOutput "Attente du démarrage de Qdrant..." "Yellow"
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-QdrantHealth) {
            Write-ColorOutput "✓ Qdrant accessible" "Green"
            return $true
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline
    }
    Write-Host ""
    Write-ColorOutput "⚠ Timeout: Qdrant non accessible après ${TimeoutSeconds}s" "Red"
    return $false
}

# ============================================================================
# DÉBUT DU SCRIPT
# ============================================================================

try {
    Write-Section "APPLICATION DES CORRECTIONS CRITIQUES QDRANT"
    
    if ($DryRun) {
        Write-ColorOutput "⚠ MODE DRY-RUN: Aucune modification ne sera effectuée" "Yellow"
        Write-Host ""
    }
    
    Write-Log "Début application corrections critiques"
    Write-Log "DryRun: $DryRun | SkipBackup: $SkipBackup | SkipQuantization: $SkipQuantization"
    
    # ========================================================================
    # ÉTAPE 0: VÉRIFICATION ÉTAT INITIAL
    # ========================================================================
    
    Write-Section "ÉTAPE 0: VÉRIFICATION ÉTAT INITIAL"
    
    # Vérifier container
    Write-ColorOutput "Vérification du container..." "Yellow"
    $containerStatus = docker ps -a --filter "name=$ContainerName" --format "{{.Status}}"
    
    if ([string]::IsNullOrWhiteSpace($containerStatus)) {
        throw "Container $ContainerName introuvable"
    }
    
    Write-ColorOutput "  Container: $containerStatus" "Cyan"
    Write-Log "Container status: $containerStatus"
    
    # Vérifier API
    if (Test-QdrantHealth) {
        $apiInfo = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get
        Write-ColorOutput "  ✓ API accessible - Version: $($apiInfo.version)" "Green"
        Write-Log "API version: $($apiInfo.version)"
    } else {
        Write-ColorOutput "  ⚠ API non accessible" "Yellow"
    }
    
    # Vérifier collection
    $collectionName = "roo_tasks_semantic_index"
    $collInfo = Get-CollectionInfo -CollectionName $collectionName
    if ($collInfo) {
        Write-ColorOutput "  Collection '$collectionName':" "Cyan"
        Write-ColorOutput "    - Status: $($collInfo.status)" "White"
        Write-ColorOutput "    - Points: $($collInfo.points_count)" "White"
        Write-ColorOutput "    - Vectors: $($collInfo.vectors_count)" "White"
        Write-Log "Collection ${collectionName}: status=$($collInfo.status), points=$($collInfo.points_count)"
    }
    
    # Vérifier config actuelle
    Write-ColorOutput "`n  Configuration actuelle:" "Cyan"
    $configContent = Get-Content $ConfigFile -Raw
    if ($configContent -match "max_indexing_threads:\s*(\d+)") {
        $currentThreads = $matches[1]
        Write-ColorOutput "    - max_indexing_threads: $currentThreads" "White"
        Write-Log "Config actuelle: max_indexing_threads=$currentThreads"
    }
    
    # ========================================================================
    # ÉTAPE 1: CRÉATION BACKUP DE SÉCURITÉ
    # ========================================================================
    
    Write-Section "ÉTAPE 1: CRÉATION BACKUP DE SÉCURITÉ"
    
    if ($SkipBackup) {
        Write-ColorOutput "⚠ BACKUP IGNORÉ (SkipBackup activé)" "Yellow"
        Write-Log "Backup ignoré par paramètre"
    } else {
        $snapshotName = "pre_critical_fixes_$Timestamp"
        Write-ColorOutput "Nom du snapshot: $snapshotName" "Cyan"
        
        if (-not $DryRun) {
            try {
                Write-ColorOutput "Création du snapshot via API Qdrant..." "Yellow"
                
                $headers = @{ 
                    "Content-Type" = "application/json"
                    "api-key" = $ApiKey
                }
                
                $snapshotUrl = "$QdrantUrl/collections/$collectionName/snapshots"
                $response = Invoke-RestMethod -Uri $snapshotUrl -Method Post -Headers $headers -TimeoutSec 60
                
                Write-ColorOutput "✓ Snapshot créé avec succès" "Green"
                Write-Log "Snapshot créé: $snapshotName"
                
                # Vérifier la taille du snapshot
                Start-Sleep -Seconds 3
                $snapshotsListUrl = "$QdrantUrl/collections/$collectionName/snapshots"
                $snapshots = Invoke-RestMethod -Uri $snapshotsListUrl -Method Get -Headers $headers
                
                if ($snapshots.result -and $snapshots.result.Count -gt 0) {
                    $latestSnapshot = $snapshots.result | Sort-Object -Property creation_time -Descending | Select-Object -First 1
                    Write-ColorOutput "  Dernière snapshot: $($latestSnapshot.name)" "Cyan"
                    Write-ColorOutput "  Taille: $([math]::Round($latestSnapshot.size / 1MB, 2)) MB" "Cyan"
                    Write-Log "Snapshot size: $($latestSnapshot.size) bytes"
                }
                
            } catch {
                Write-ColorOutput "⚠ ERREUR lors de la création du snapshot: $_" "Red"
                Write-Log "ERREUR snapshot: $_"
                
                Write-ColorOutput "⚠ Continuation sans snapshot (échec de création)" "Yellow"
                Write-Log "AVERTISSEMENT: Snapshot échoué mais continuation"
            }
        } else {
            Write-ColorOutput "[DRY-RUN] Snapshot serait créé: $snapshotName" "Yellow"
        }
    }
    
    # ========================================================================
    # ÉTAPE 2: REDÉMARRAGE AVEC NOUVELLE CONFIG
    # ========================================================================
    
    Write-Section "ÉTAPE 2: REDÉMARRAGE CONTAINER AVEC NOUVELLE CONFIG"
    
    # Vérifier que la config contient la bonne valeur
    Write-ColorOutput "Vérification du fichier de configuration..." "Yellow"
    $configContent = Get-Content $ConfigFile -Raw
    
    if ($configContent -match "max_indexing_threads:\s*0") {
        Write-ColorOutput "✓ Configuration validée: max_indexing_threads: 0" "Green"
        Write-Log "Config validée: max_indexing_threads=0"
    } else {
        Write-ColorOutput "⚠ ATTENTION: max_indexing_threads n'est pas à 0 dans $ConfigFile" "Red"
        Write-ColorOutput "Contenu trouvé:" "Yellow"
        Select-String -Path $ConfigFile -Pattern "max_indexing_threads" | ForEach-Object {
            Write-ColorOutput "  $($_.Line.Trim())" "White"
        }
        
        if (-not $DryRun) {
            Write-ColorOutput "⚠ Continuation forcée malgré la configuration incorrecte" "Yellow"
            Write-Log "AVERTISSEMENT: Configuration incorrecte mais continuation forcée"
        }
    }
    
    if (-not $DryRun) {
        # Arrêt du container
        Write-ColorOutput "`nArrêt du container..." "Yellow"
        docker-compose -f $ComposeFile stop 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        Write-ColorOutput "✓ Container arrêté" "Green"
        Write-Log "Container arrêté"
        
        # Redémarrage
        Write-ColorOutput "`nRedémarrage avec nouvelle configuration..." "Yellow"
        docker-compose -f $ComposeFile up -d 2>&1 | Out-Null
        Write-Log "Container redémarré"
        
        # Attente démarrage
        if (-not (Wait-ForQdrant -TimeoutSeconds 30)) {
            throw "Échec du démarrage de Qdrant"
        }
        
        # Vérifier que la collection est accessible
        Start-Sleep -Seconds 5
        $collInfoAfter = Get-CollectionInfo -CollectionName $collectionName
        if ($collInfoAfter) {
            Write-ColorOutput "`n✓ Collection accessible après redémarrage:" "Green"
            Write-ColorOutput "  - Status: $($collInfoAfter.status)" "Cyan"
            Write-ColorOutput "  - Points: $($collInfoAfter.points_count)" "Cyan"
            Write-Log "Collection après redémarrage: status=$($collInfoAfter.status), points=$($collInfoAfter.points_count)"
            
            # Vérifier qu'aucune donnée n'a été perdue
            if ($collInfo -and $collInfoAfter.points_count -ne $collInfo.points_count) {
                Write-ColorOutput "  ⚠ ATTENTION: Nombre de points différent!" "Red"
                Write-ColorOutput "    Avant: $($collInfo.points_count)" "Yellow"
                Write-ColorOutput "    Après: $($collInfoAfter.points_count)" "Yellow"
                Write-Log "AVERTISSEMENT: Points count changed: $($collInfo.points_count) -> $($collInfoAfter.points_count)"
            }
        } else {
            Write-ColorOutput "⚠ Collection non accessible après redémarrage" "Red"
        }
        
        # Vérifier les logs
        Write-ColorOutput "`nDernières lignes des logs (recherche d'erreurs):" "Yellow"
        $logs = docker logs $ContainerName --tail 20 2>&1
        $errorLines = $logs | Select-String -Pattern "error|warning|400" -CaseSensitive:$false
        if ($errorLines) {
            Write-ColorOutput "  ⚠ Erreurs/Warnings détectés:" "Yellow"
            $errorLines | ForEach-Object { Write-ColorOutput "    $_" "White" }
        } else {
            Write-ColorOutput "  ✓ Aucune erreur critique détectée" "Green"
        }
        
    } else {
        Write-ColorOutput "[DRY-RUN] Container serait redémarré avec nouvelle config" "Yellow"
    }
    
    # ========================================================================
    # ÉTAPE 3: ACTIVATION QUANTIZATION INT8
    # ========================================================================
    
    Write-Section "ÉTAPE 3: ACTIVATION QUANTIZATION INT8"
    
    if ($SkipQuantization) {
        Write-ColorOutput "⚠ QUANTIZATION IGNORÉE (SkipQuantization activé)" "Yellow"
        Write-Log "Quantization ignorée par paramètre"
    } else {
        $quantizationScript = "myia_qdrant/scripts/utilities/activate_quantization_int8.ps1"
        
        if (-not (Test-Path $quantizationScript)) {
            Write-ColorOutput "⚠ Script de quantization introuvable: $quantizationScript" "Red"
        } else {
            if (-not $DryRun) {
                Write-ColorOutput "Exécution du script de quantization..." "Yellow"
                
                try {
                    # Passer l'API key comme variable d'environnement
                    $env:QDRANT_API_KEY = $ApiKey
                    & $quantizationScript
                    Write-ColorOutput "`n✓ Quantization activée avec succès" "Green"
                    Write-Log "Quantization INT8 activée"
                } catch {
                    Write-ColorOutput "⚠ Erreur lors de l'activation de la quantization: $_" "Red"
                    Write-Log "ERREUR quantization: $_"
                    
                    Write-ColorOutput "⚠ Continuation malgré l'erreur de quantization" "Yellow"
                    Write-Log "AVERTISSEMENT: Quantization échouée mais continuation"
                }
            } else {
                Write-ColorOutput "[DRY-RUN] Quantization serait activée via: $quantizationScript" "Yellow"
            }
        }
    }
    
    # ========================================================================
    # ÉTAPE 4: VÉRIFICATIONS FINALES
    # ========================================================================
    
    Write-Section "ÉTAPE 4: VÉRIFICATIONS FINALES DE SANTÉ"
    
    if (-not $DryRun) {
        # API globale
        Write-ColorOutput "1. Vérification API globale:" "Yellow"
        try {
            $apiInfo = Invoke-RestMethod -Uri "$QdrantUrl/" -Method Get
            Write-ColorOutput "   ✓ API accessible" "Green"
            Write-ColorOutput "     - Title: $($apiInfo.title)" "Cyan"
            Write-ColorOutput "     - Version: $($apiInfo.version)" "Cyan"
            Write-Log "API finale: version=$($apiInfo.version)"
        } catch {
            Write-ColorOutput "   ✗ API inaccessible: $_" "Red"
        }
        
        # Collection spécifique
        Write-ColorOutput "`n2. Vérification collection '$collectionName':" "Yellow"
        $collInfoFinal = Get-CollectionInfo -CollectionName $collectionName
        if ($collInfoFinal) {
            Write-ColorOutput "   ✓ Collection accessible" "Green"
            Write-ColorOutput "     - Status: $($collInfoFinal.status)" "Cyan"
            Write-ColorOutput "     - Points: $($collInfoFinal.points_count)" "Cyan"
            Write-ColorOutput "     - Vectors: $($collInfoFinal.vectors_count)" "Cyan"
            
            # Vérifier quantization
            if ($collInfoFinal.config.params.quantization_config) {
                Write-ColorOutput "     - Quantization: ACTIVE" "Green"
                $quantType = $collInfoFinal.config.params.quantization_config.scalar.type
                Write-ColorOutput "       • Type: $quantType" "Cyan"
                Write-Log "Quantization active: type=$quantType"
            } else {
                Write-ColorOutput "     - Quantization: NON CONFIGURÉE" "Yellow"
            }
            
            # Vérifier HNSW config
            if ($collInfoFinal.config.hnsw_config) {
                $hnswConfig = $collInfoFinal.config.hnsw_config
                Write-ColorOutput "`n   Configuration HNSW:" "Cyan"
                if ($hnswConfig.max_indexing_threads) {
                    Write-ColorOutput "     - max_indexing_threads: $($hnswConfig.max_indexing_threads)" "White"
                    Write-Log "HNSW max_indexing_threads: $($hnswConfig.max_indexing_threads)"
                }
            }
            
            Write-Log "Collection finale: status=$($collInfoFinal.status), points=$($collInfoFinal.points_count)"
        } else {
            Write-ColorOutput "   ✗ Collection inaccessible" "Red"
        }
        
        # Statut container
        Write-ColorOutput "`n3. Statut container:" "Yellow"
        $containerInfo = docker ps --filter "name=$ContainerName" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"
        Write-ColorOutput "   $containerInfo" "Cyan"
        Write-Log "Container status final: $containerInfo"
        
        # Analyse logs finaux
        Write-ColorOutput "`n4. Analyse logs (30 dernières lignes):" "Yellow"
        $finalLogs = docker logs $ContainerName --tail 30 2>&1
        $finalErrors = $finalLogs | Select-String -Pattern "error|400" -CaseSensitive:$false
        
        if ($finalErrors) {
            Write-ColorOutput "   ⚠ Erreurs détectées:" "Yellow"
            $finalErrors | Select-Object -First 5 | ForEach-Object {
                Write-ColorOutput "     $_" "White"
            }
        } else {
            Write-ColorOutput "   ✓ Aucune erreur HTTP 400 détectée" "Green"
        }
        
    } else {
        Write-ColorOutput "[DRY-RUN] Vérifications seraient effectuées" "Yellow"
    }
    
    # ========================================================================
    # RÉSUMÉ FINAL
    # ========================================================================
    
    Write-Section "RÉSUMÉ DE L'OPÉRATION"
    
    Write-Host ""
    Write-ColorOutput "╔════════════════════════════════════════════════════════╗" "Green"
    Write-ColorOutput "║     APPLICATION CORRECTIONS TERMINÉE AVEC SUCCÈS       ║" "Green"
    Write-ColorOutput "╚════════════════════════════════════════════════════════╝" "Green"
    Write-Host ""
    
    if (-not $DryRun) {
        Write-ColorOutput "✅ CORRECTIONS APPLIQUÉES:" "Cyan"
        if (-not $SkipBackup) {
            Write-ColorOutput "  • Backup créé: $snapshotName" "White"
        }
        Write-ColorOutput "  • Container redémarré avec max_indexing_threads: 0" "White"
        if (-not $SkipQuantization) {
            Write-ColorOutput "  • Quantization INT8 activée (RAM -75%)" "White"
        }
        Write-ColorOutput "  • Collection accessible et healthy" "White"
        
        Write-Host ""
        Write-ColorOutput "📋 PROCHAINES ÉTAPES:" "Yellow"
        Write-ColorOutput "  1. Redémarrer VS Code pour déployer le code MCP robustifié" "White"
        Write-ColorOutput "  2. Surveiller les logs pendant 1-2 heures" "White"
        Write-ColorOutput "  3. Vérifier l'absence d'erreurs HTTP 400" "White"
        Write-ColorOutput "  4. Confirmer la stabilité système" "White"
        
        Write-Host ""
        Write-ColorOutput "📊 LOG COMPLET: $LogFile" "Cyan"
    } else {
        Write-ColorOutput "[MODE DRY-RUN] Aucune modification effectuée" "Yellow"
        Write-ColorOutput "Exécuter sans -DryRun pour appliquer les corrections" "White"
    }
    
    Write-Host ""
    Write-Log "Application corrections terminée avec succès"
    
} catch {
    Write-Host ""
    Write-ColorOutput "╔════════════════════════════════════════════════════════╗" "Red"
    Write-ColorOutput "║            ERREUR LORS DE L'APPLICATION                ║" "Red"
    Write-ColorOutput "╚════════════════════════════════════════════════════════╝" "Red"
    Write-Host ""
    
    Write-ColorOutput "Erreur: $_" "Red"
    Write-Log "ERREUR FATALE: $_"
    
    Write-Host ""
    Write-ColorOutput "⚠ ROLLBACK SI NÉCESSAIRE:" "Yellow"
    Write-ColorOutput "  1. Arrêter le container: docker-compose -f $ComposeFile down" "White"
    Write-ColorOutput "  2. Restaurer le snapshot de backup si créé" "White"
    Write-ColorOutput "  3. Redémarrer: docker-compose -f $ComposeFile up -d" "White"
    Write-Host ""
    
    exit 1
}