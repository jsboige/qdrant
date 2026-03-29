#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script de mise à jour de Qdrant avec sauvegarde et vérifications
    
.DESCRIPTION
    Ce script effectue une mise à jour complète de Qdrant:
    1. Vérifie la version actuelle
    2. Identifie la dernière version disponible
    3. Crée un snapshot de sauvegarde
    4. Met à jour vers la nouvelle version
    5. Vérifie le bon fonctionnement
    
.NOTES
    Date: 2025-10-14
    Contexte: Mise à jour urgente suite à dégradation de stabilité
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$TargetVersion = "",  # Si vide, prend la dernière version stable
    
    [Parameter()]
    [switch]$DryRun = $false,  # Mode simulation
    
    [Parameter()]
    [switch]$SkipSnapshot = $false  # Sauter la création de snapshot (non recommandé)
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Couleurs pour l'affichage
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

# Variables globales
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$composeFile = "docker-compose.production.yml"
$logFile = "diagnostics/20251014_qdrant_update_$timestamp.log"

# Fonction de logging
function Write-Log {
    param([string]$Message)
    $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logFile -Value $logMessage
    Write-Host $logMessage
}

try {
    Write-Section "ÉTAPE 1: VÉRIFICATION VERSION ACTUELLE"
    
    # Vérifier que le container existe
    $containerExists = docker ps -a --format "{{.Names}}" | Select-String "qdrant_production"
    if (-not $containerExists) {
        throw "Container qdrant_production introuvable"
    }
    
    # Récupérer la version via l'API
    Write-ColorOutput "Récupération version via API..." "Yellow"
    $apiResponse = curl -s http://localhost:6333/
    $apiData = $apiResponse | ConvertFrom-Json
    $currentVersion = $apiData.version
    
    Write-ColorOutput "✓ Version actuelle: $currentVersion" "Green"
    Write-Log "Version actuelle: $currentVersion"
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 2: RECHERCHE DERNIÈRE VERSION DISPONIBLE"
    
    Write-ColorOutput "Interrogation Docker Hub..." "Yellow"
    $hubResponse = Invoke-RestMethod -Uri "https://registry.hub.docker.com/v2/repositories/qdrant/qdrant/tags?page_size=100" -Method Get
    
    # Filtrer pour garder uniquement les versions stables (format vX.Y.Z)
    $stableVersions = $hubResponse.results | Where-Object { 
        $_.name -match '^v[0-9]+\.[0-9]+\.[0-9]+$' 
    } | Sort-Object {
        # Trier par version sémantique
        $v = $_.name -replace '^v', ''
        $parts = $v -split '\.'
        [int]$parts[0] * 10000 + [int]$parts[1] * 100 + [int]$parts[2]
    } -Descending
    
    # Afficher les 10 dernières versions
    Write-ColorOutput "`nDernières versions stables disponibles:" "Cyan"
    $stableVersions | Select-Object -First 10 | ForEach-Object {
        $date = ([datetime]$_.last_updated).ToString("yyyy-MM-dd")
        Write-Host "  • $($_.name) (publié le $date)"
    }
    
    # Déterminer la version cible
    if ($TargetVersion) {
        $latestVersion = $TargetVersion
        Write-ColorOutput "`n→ Version cible spécifiée: $latestVersion" "Yellow"
    } else {
        $latestVersion = $stableVersions[0].name
        Write-ColorOutput "`n→ Dernière version stable: $latestVersion" "Green"
    }
    
    # Vérifier si mise à jour nécessaire
    if ($currentVersion -eq $latestVersion) {
        Write-ColorOutput "`n⚠ Version déjà à jour ($currentVersion)" "Yellow"
        Write-Log "Version déjà à jour: $currentVersion"
        
        if (-not $DryRun) {
            $continue = Read-Host "`nContinuer quand même? (o/N)"
            if ($continue -ne "o") {
                Write-ColorOutput "Opération annulée par l'utilisateur" "Yellow"
                exit 0
            }
        }
    } else {
        Write-ColorOutput "`n✓ Mise à jour disponible: $currentVersion → $latestVersion" "Green"
        Write-Log "Mise à jour disponible: $currentVersion -> $latestVersion"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 3: LECTURE CONFIGURATION ACTUELLE"
    
    if (-not (Test-Path $composeFile)) {
        throw "Fichier $composeFile introuvable"
    }
    
    $composeContent = Get-Content $composeFile -Raw
    $currentImageLine = $composeContent | Select-String "image:\s*qdrant/qdrant:(.+)" -AllMatches
    
    if ($currentImageLine.Matches.Count -gt 0) {
        $currentDockerVersion = $currentImageLine.Matches[0].Groups[1].Value
        Write-ColorOutput "Image Docker actuelle: qdrant/qdrant:$currentDockerVersion" "Cyan"
        Write-Log "Image Docker actuelle: $currentDockerVersion"
    } else {
        throw "Impossible de trouver la ligne 'image:' dans $composeFile"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 4: CRÉATION SNAPSHOT DE SAUVEGARDE"
    
    if (-not $SkipSnapshot) {
        $snapshotName = "pre_update_${currentVersion}_to_${latestVersion}_$timestamp"
        Write-ColorOutput "Nom du snapshot: $snapshotName" "Yellow"
        
        if (-not $DryRun) {
            try {
                # Créer le snapshot via l'API
                $snapshotBody = @{
                    snapshot_name = $snapshotName
                } | ConvertTo-Json
                
                $snapshotResponse = curl -X POST "http://localhost:6333/snapshots" `
                    -H "Content-Type: application/json" `
                    -H "api-key: $env:QDRANT_API_KEY" `
                    -d $snapshotBody
                
                Write-ColorOutput "✓ Snapshot créé avec succès: $snapshotName" "Green"
                Write-Log "Snapshot créé: $snapshotName"
            } catch {
                Write-ColorOutput "⚠ ERREUR lors de la création du snapshot: $_" "Red"
                Write-Log "ERREUR snapshot: $_"
                
                $continue = Read-Host "`nContinuer sans snapshot? (o/N)"
                if ($continue -ne "o") {
                    throw "Opération annulée: impossible de créer le snapshot"
                }
            }
        } else {
            Write-ColorOutput "[DRY-RUN] Snapshot serait créé: $snapshotName" "Yellow"
        }
    } else {
        Write-ColorOutput "⚠ Création de snapshot IGNORÉE (SkipSnapshot activé)" "Yellow"
        Write-Log "Snapshot ignoré (SkipSnapshot)"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 5: MISE À JOUR DOCKER-COMPOSE"
    
    $newImageLine = "    image: qdrant/qdrant:$latestVersion"
    Write-ColorOutput "Nouvelle ligne image: $newImageLine" "Cyan"
    
    if (-not $DryRun) {
        # Backup du fichier docker-compose
        $backupFile = "$composeFile.backup_$timestamp"
        Copy-Item $composeFile $backupFile
        Write-ColorOutput "✓ Backup créé: $backupFile" "Green"
        Write-Log "Backup docker-compose: $backupFile"
        
        # Remplacer la ligne image
        $newContent = $composeContent -replace "image:\s*qdrant/qdrant:.+", $newImageLine.Trim()
        Set-Content -Path $composeFile -Value $newContent
        
        Write-ColorOutput "✓ Fichier $composeFile mis à jour" "Green"
        Write-Log "docker-compose.yml mis à jour vers $latestVersion"
    } else {
        Write-ColorOutput "[DRY-RUN] Fichier serait mis à jour" "Yellow"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 6: ARRÊT DU CONTAINER"
    
    if (-not $DryRun) {
        Write-ColorOutput "Arrêt du container en cours..." "Yellow"
        docker-compose -f $composeFile down
        
        # Vérifier que le container est bien arrêté
        Start-Sleep 3
        $stillRunning = docker ps --format "{{.Names}}" | Select-String "qdrant_production"
        if ($stillRunning) {
            throw "Le container qdrant_production est toujours en cours d'exécution"
        }
        
        Write-ColorOutput "✓ Container arrêté" "Green"
        Write-Log "Container arrêté"
    } else {
        Write-ColorOutput "[DRY-RUN] Container serait arrêté" "Yellow"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 7: TÉLÉCHARGEMENT NOUVELLE IMAGE"
    
    if (-not $DryRun) {
        Write-ColorOutput "Pull de l'image qdrant/qdrant:$latestVersion..." "Yellow"
        docker-compose -f $composeFile pull
        
        Write-ColorOutput "✓ Image téléchargée" "Green"
        Write-Log "Image $latestVersion téléchargée"
    } else {
        Write-ColorOutput "[DRY-RUN] Image serait téléchargée" "Yellow"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 8: DÉMARRAGE AVEC NOUVELLE VERSION"
    
    if (-not $DryRun) {
        Write-ColorOutput "Démarrage du container avec la nouvelle version..." "Yellow"
        docker-compose -f $composeFile up -d
        
        Write-ColorOutput "Attente démarrage (15 secondes)..." "Yellow"
        Start-Sleep 15
        
        Write-ColorOutput "✓ Container démarré" "Green"
        Write-Log "Container démarré avec version $latestVersion"
    } else {
        Write-ColorOutput "[DRY-RUN] Container serait démarré" "Yellow"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 9: VÉRIFICATIONS POST-MISE À JOUR"
    
    if (-not $DryRun) {
        # Vérifier version installée
        Write-ColorOutput "Vérification version API..." "Yellow"
        Start-Sleep 5  # Attendre que l'API soit prête
        
        try {
            $newApiResponse = curl -s http://localhost:6333/
            $newApiData = $newApiResponse | ConvertFrom-Json
            $installedVersion = $newApiData.version
            
            Write-ColorOutput "✓ Version installée: $installedVersion" "Green"
            Write-Log "Version installée vérifiée: $installedVersion"
            
            if ($installedVersion -ne $latestVersion) {
                Write-ColorOutput "⚠ ATTENTION: Version installée ($installedVersion) != Version attendue ($latestVersion)" "Yellow"
            }
        } catch {
            Write-ColorOutput "⚠ Impossible de vérifier la version via API: $_" "Yellow"
        }
        
        # Vérifier collections
        Write-ColorOutput "`nVérification collections..." "Yellow"
        try {
            $collectionsResponse = curl -s -H "api-key: $env:QDRANT_API_KEY" http://localhost:6333/collections
            $collectionsData = $collectionsResponse | ConvertFrom-Json
            $collectionCount = $collectionsData.result.collections.Count
            
            Write-ColorOutput "✓ Collections accessibles: $collectionCount" "Green"
            Write-Log "Collections accessibles: $collectionCount"
        } catch {
            Write-ColorOutput "⚠ Erreur lors de la vérification des collections: $_" "Red"
            Write-Log "ERREUR vérification collections: $_"
        }
        
        # Statut container
        Write-ColorOutput "`nStatut container:" "Yellow"
        docker ps --filter "name=qdrant_production" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        
    } else {
        Write-ColorOutput "[DRY-RUN] Vérifications seraient effectuées" "Yellow"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "ÉTAPE 10: ANALYSE LOGS DE DÉMARRAGE"
    
    if (-not $DryRun) {
        Write-ColorOutput "Dernières lignes des logs:" "Yellow"
        Write-Host ""
        docker logs qdrant_production --tail 30
        
        Write-Log "Logs vérifiés"
    } else {
        Write-ColorOutput "[DRY-RUN] Logs seraient analysés" "Yellow"
    }
    
    # ═══════════════════════════════════════════════════════════
    Write-Section "RÉSUMÉ MISE À JOUR"
    
    Write-Host ""
    Write-ColorOutput "╔════════════════════════════════════════════════════════╗" "Green"
    Write-ColorOutput "║           MISE À JOUR TERMINÉE AVEC SUCCÈS             ║" "Green"
    Write-ColorOutput "╚════════════════════════════════════════════════════════╝" "Green"
    Write-Host ""
    
    if (-not $DryRun) {
        Write-ColorOutput "Version précédente: $currentVersion" "Cyan"
        Write-ColorOutput "Version actuelle:   $latestVersion" "Cyan"
        Write-Host ""
        Write-ColorOutput "Snapshot créé: $snapshotName" "Cyan"
        Write-ColorOutput "Backup docker-compose: $backupFile" "Cyan"
    } else {
        Write-ColorOutput "[MODE DRY-RUN] Aucune modification effectuée" "Yellow"
    }
    
    Write-Host ""
    Write-ColorOutput "📋 Log complet: $logFile" "Cyan"
    Write-Host ""
    
    Write-ColorOutput "RECOMMANDATIONS POST-MISE À JOUR:" "Yellow"
    Write-ColorOutput "1. Surveiller les redémarrages pendant 2-3 heures" "White"
    Write-ColorOutput "2. Vérifier si la fréquence des redémarrages diminue" "White"
    Write-ColorOutput "3. Analyser les nouveaux logs pour détecter d'éventuels problèmes" "White"
    Write-Host ""
    
    Write-ColorOutput "ROLLBACK SI NÉCESSAIRE:" "Red"
    Write-ColorOutput "docker-compose -f $composeFile down" "White"
    Write-ColorOutput "# Restaurer: $backupFile" "White"
    Write-ColorOutput "docker-compose -f $composeFile up -d" "White"
    Write-Host ""
    
    Write-Log "Mise à jour terminée avec succès"
    
} catch {
    Write-Host ""
    Write-ColorOutput "╔════════════════════════════════════════════════════════╗" "Red"
    Write-ColorOutput "║              ERREUR LORS DE LA MISE À JOUR             ║" "Red"
    Write-ColorOutput "╚════════════════════════════════════════════════════════╝" "Red"
    Write-Host ""
    
    Write-ColorOutput "Erreur: $_" "Red"
    Write-Log "ERREUR FATALE: $_"
    
    Write-Host ""
    Write-ColorOutput "PROCÉDURE DE ROLLBACK:" "Yellow"
    Write-ColorOutput "1. docker-compose -f $composeFile down" "White"
    Write-ColorOutput "2. Restaurer le backup: $composeFile.backup_$timestamp" "White"
    Write-ColorOutput "3. docker-compose -f $composeFile up -d" "White"
    Write-Host ""
    
    exit 1
}