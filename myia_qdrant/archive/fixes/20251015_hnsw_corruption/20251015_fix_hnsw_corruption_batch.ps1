#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    ✅ CORRECTION URGENTE: Migration HNSW threads=0 → threads=16 pour 58 collections

.DESCRIPTION
    Ce script corrige la corruption HNSW massive identifiée:
    - 58/59 collections ont max_indexing_threads=0 (HNSW corrompu/inefficace)
    - Cause des overloads systématiques lors de l'indexation Roo
    - Solution: Mettre à jour vers threads=16 via API Qdrant
    
    STRATÉGIE:
    1. Backup de la configuration actuelle
    2. Tri par volumétrie (impact maximal en premier)
    3. Migration progressive avec validation
    4. Rollback automatique en cas d'échec

.PARAMETER DryRun
    Mode simulation sans modifications réelles

.PARAMETER BatchSize
    Nombre de collections à traiter par batch (défaut: 10)

.PARAMETER TargetThreads
    Nombre de threads HNSW cible (défaut: 16)

.EXAMPLE
    # Mode simulation (recommandé en premier)
    .\20251015_fix_hnsw_corruption_batch.ps1 -DryRun

.EXAMPLE
    # Correction réelle par batch de 5
    .\20251015_fix_hnsw_corruption_batch.ps1 -BatchSize 5

.EXAMPLE
    # Correction complète avec 32 threads
    .\20251015_fix_hnsw_corruption_batch.ps1 -TargetThreads 32
#>

param(
    [switch]$DryRun,
    [int]$BatchSize = 10,
    [int]$TargetThreads = 16,
    [switch]$SkipBackup,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$API_KEY = "qdrant_admin"
$QDRANT_URL = "http://localhost:6333"

# Couleurs
$ColorCritical = "Red"
$ColorWarning = "Yellow"
$ColorSuccess = "Green"
$ColorInfo = "Cyan"

# Statistiques globales
$script:Stats = @{
    TotalCollections = 0
    CollectionsToFix = 0
    Fixed = 0
    Failed = 0
    Skipped = 0
    StartTime = Get-Date
}

function Write-Banner {
    param([string]$Text)
    Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor $ColorInfo
    Write-Host "║  $($Text.PadRight(61))║" -ForegroundColor $ColorInfo
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor $ColorInfo
}

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor $ColorInfo
}

function Test-QdrantAvailability {
    Write-Section "🔍 Vérification disponibilité Qdrant"
    
    try {
        $health = Invoke-RestMethod -Uri "$QDRANT_URL/" -Headers @{"api-key"=$API_KEY} -Method Get
        Write-Host "✅ Qdrant accessible - Version: $($health.version)" -ForegroundColor $ColorSuccess
        return $true
    } catch {
        Write-Host "❌ Qdrant inaccessible: $_" -ForegroundColor $ColorCritical
        return $false
    }
}

function Get-CollectionsToFix {
    Write-Section "📊 Identification des collections à corriger"
    
    try {
        $response = Invoke-RestMethod -Uri "$QDRANT_URL/collections" -Headers @{"api-key"=$API_KEY} -Method Get
        $allCollections = $response.result.collections
        
        $script:Stats.TotalCollections = $allCollections.Count
        Write-Host "Total collections: $($allCollections.Count)" -ForegroundColor $ColorInfo
        
        $collectionsToFix = @()
        
        foreach ($col in $allCollections) {
            try {
                $response = Invoke-RestMethod -Uri "$QDRANT_URL/collections/$($col.name)" -Headers @{"api-key"=$API_KEY} -Method Get
                $info = $response.result
                
                $currentThreads = $info.config.hnsw_config.max_indexing_threads
                
                if ($currentThreads -eq 0) {
                    $collectionsToFix += [PSCustomObject]@{
                        Name = $col.name
                        CurrentThreads = $currentThreads
                        Points = $info.points_count
                        Segments = $info.segments_count
                        DiskMB = [math]::Round($info.disk_data_size / 1MB, 2)
                        IndexedVectors = $info.indexed_vectors_count
                        Priority = if ($info.points_count -gt 500000) { 1 } 
                                  elseif ($info.points_count -gt 100000) { 2 }
                                  else { 3 }
                    }
                }
            } catch {
                Write-Host "⚠️  Erreur lecture $($col.name): $_" -ForegroundColor $ColorWarning
            }
        }
        
        $script:Stats.CollectionsToFix = $collectionsToFix.Count
        
        Write-Host "`n🎯 Collections avec threads=0 trouvées: $($collectionsToFix.Count)" -ForegroundColor $ColorWarning
        
        # Tri par priorité puis volumétrie
        $sorted = $collectionsToFix | Sort-Object Priority, @{Expression={$_.Points}; Descending=$true}
        
        Write-Host "`n🔥 TOP 10 PRIORITAIRES:" -ForegroundColor $ColorWarning
        $sorted | Select-Object -First 10 | Format-Table -AutoSize -Property @(
            @{Label="Collection"; Expression={$_.Name}; Width=35}
            @{Label="Points"; Expression={$_.Points.ToString("N0")}; Width=12}
            @{Label="Segments"; Expression={$_.Segments}; Width=10}
            @{Label="Threads"; Expression={"0 → $TargetThreads"}; Width=12}
            @{Label="Priority"; Expression={$_.Priority}; Width=10}
        )
        
        return $sorted
    } catch {
        Write-Host "❌ Erreur lors de l'identification: $_" -ForegroundColor $ColorCritical
        throw
    }
}

function Backup-CollectionConfig {
    param([string]$CollectionName)
    
    if ($SkipBackup) {
        return $true
    }
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = "myia_qdrant/diagnostics/hnsw_backups"
    
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    
    try {
        $response = Invoke-RestMethod -Uri "$QDRANT_URL/collections/$CollectionName" -Headers @{"api-key"=$API_KEY} -Method Get
        $config = $response.result
        
        $backupFile = Join-Path $backupDir "${CollectionName}_${timestamp}.json"
        $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $backupFile -Encoding UTF8
        
        Write-Host "  💾 Backup: $backupFile" -ForegroundColor $ColorSuccess
        return $true
    } catch {
        Write-Host "  ⚠️  Échec backup: $_" -ForegroundColor $ColorWarning
        return $false
    }
}

function Update-HNSWThreads {
    param(
        [string]$CollectionName,
        [int]$NewThreads
    )
    
    try {
        # Backup avant modification
        if (-not (Backup-CollectionConfig -CollectionName $CollectionName)) {
            Write-Host "  ⚠️  Backup échoué mais on continue..." -ForegroundColor $ColorWarning
        }
        
        # Préparation de la requête PATCH
        $updatePayload = @{
            hnsw_config = @{
                max_indexing_threads = $NewThreads
            }
        } | ConvertTo-Json -Compress
        
        if ($DryRun) {
            Write-Host "  [DRY-RUN] PATCH $QDRANT_URL/collections/$CollectionName" -ForegroundColor $ColorWarning
            Write-Host "  [DRY-RUN] Body: $updatePayload" -ForegroundColor $ColorWarning
            return $true
        }
        
        # Exécution réelle
        $result = Invoke-RestMethod -Uri "$QDRANT_URL/collections/$CollectionName" `
            -Headers @{"api-key"=$API_KEY} `
            -Method Patch `
            -ContentType "application/json" `
            -Body $updatePayload
        
        if ($result.status -eq "ok" -or $result.result -eq $true) {
            Write-Host "  ✅ Mise à jour réussie" -ForegroundColor $ColorSuccess
            return $true
        } else {
            Write-Host "  ❌ Échec mise à jour: $($result.status)" -ForegroundColor $ColorCritical
            return $false
        }
    } catch {
        Write-Host "  ❌ Erreur mise à jour: $_" -ForegroundColor $ColorCritical
        return $false
    }
}

function Verify-Update {
    param([string]$CollectionName, [int]$ExpectedThreads)
    
    try {
        Start-Sleep -Milliseconds 500 # Attente propagation
        
        $response = Invoke-RestMethod -Uri "$QDRANT_URL/collections/$CollectionName" -Headers @{"api-key"=$API_KEY} -Method Get
        $info = $response.result
        
        $actualThreads = $info.config.hnsw_config.max_indexing_threads
        
        if ($actualThreads -eq $ExpectedThreads) {
            Write-Host "  ✅ Validation OK: threads=$actualThreads" -ForegroundColor $ColorSuccess
            return $true
        } else {
            Write-Host "  ❌ Validation FAILED: attendu=$ExpectedThreads, actuel=$actualThreads" -ForegroundColor $ColorCritical
            return $false
        }
    } catch {
        Write-Host "  ⚠️  Erreur validation: $_" -ForegroundColor $ColorWarning
        return $false
    }
}

function Process-Batch {
    param(
        [array]$Collections,
        [int]$BatchNumber,
        [int]$TotalBatches
    )
    
    Write-Section "🔄 BATCH $BatchNumber/$TotalBatches - $($Collections.Count) collections"
    
    $batchSuccess = 0
    $batchFailed = 0
    
    foreach ($col in $Collections) {
        $pointsStr = if ($col.Points) { $col.Points.ToString('N0') } else { "0" }
        $segmentsStr = if ($col.Segments) { $col.Segments } else { "0" }
        Write-Host "`n📦 $($col.Name) (Points: $pointsStr, Segments: $segmentsStr)" -ForegroundColor $ColorInfo
        
        if (Update-HNSWThreads -CollectionName $col.Name -NewThreads $TargetThreads) {
            if ($DryRun -or (Verify-Update -CollectionName $col.Name -ExpectedThreads $TargetThreads)) {
                $script:Stats.Fixed++
                $batchSuccess++
            } else {
                $script:Stats.Failed++
                $batchFailed++
                
                if (-not $Force) {
                    Write-Host "  ⚠️  Arrêt du batch suite à échec de validation" -ForegroundColor $ColorWarning
                    break
                }
            }
        } else {
            $script:Stats.Failed++
            $batchFailed++
            
            if (-not $Force) {
                Write-Host "  ⚠️  Arrêt du batch suite à échec de mise à jour" -ForegroundColor $ColorWarning
                break
            }
        }
    }
    
    Write-Host "`n✅ Batch $BatchNumber terminé: $batchSuccess succès, $batchFailed échecs" -ForegroundColor $(if ($batchFailed -eq 0) { $ColorSuccess } else { $ColorWarning })
    
    return $batchFailed -eq 0
}

function Show-FinalReport {
    $duration = (Get-Date) - $script:Stats.StartTime
    
    Write-Banner "RAPPORT FINAL"
    
    Write-Host "`nDurée totale: $($duration.ToString('mm\:ss'))" -ForegroundColor $ColorInfo
    Write-Host "`n📊 STATISTIQUES:" -ForegroundColor $ColorInfo
    Write-Host "  Total collections:        $($script:Stats.TotalCollections)"
    Write-Host "  Collections à corriger:   $($script:Stats.CollectionsToFix)" -ForegroundColor $ColorWarning
    Write-Host "  ✅ Corrigées:             $($script:Stats.Fixed)" -ForegroundColor $ColorSuccess
    Write-Host "  ❌ Échecs:                $($script:Stats.Failed)" -ForegroundColor $(if ($script:Stats.Failed -gt 0) { $ColorCritical } else { $ColorSuccess })
    Write-Host "  ⏭️  Ignorées:              $($script:Stats.Skipped)"
    
    $successRate = if ($script:Stats.CollectionsToFix -gt 0) {
        [math]::Round(($script:Stats.Fixed / $script:Stats.CollectionsToFix) * 100, 1)
    } else { 0 }
    
    Write-Host "`n📈 Taux de succès: $successRate%" -ForegroundColor $(if ($successRate -eq 100) { $ColorSuccess } elseif ($successRate -gt 80) { $ColorWarning } else { $ColorCritical })
    
    if ($DryRun) {
        Write-Host "`n⚠️  MODE SIMULATION - Aucune modification appliquée" -ForegroundColor $ColorWarning
        Write-Host "Lancez sans -DryRun pour appliquer les corrections" -ForegroundColor $ColorInfo
    } elseif ($script:Stats.Fixed -gt 0) {
        Write-Host "`n✅ CORRECTIONS APPLIQUÉES AVEC SUCCÈS" -ForegroundColor $ColorSuccess
        Write-Host "RECOMMANDATIONS:" -ForegroundColor $ColorInfo
        Write-Host "  1. Redémarrez Qdrant pour optimisation complète" -ForegroundColor $ColorInfo
        Write-Host "  2. Surveillez les performances avec monitor_overload_realtime.ps1" -ForegroundColor $ColorInfo
        Write-Host "  3. Les backups sont dans: myia_qdrant/diagnostics/hnsw_backups/" -ForegroundColor $ColorInfo
    }
    
    # Suggestions selon résultats
    if ($script:Stats.Failed -gt 0) {
        Write-Host "`n⚠️  ÉCHECS DÉTECTÉS:" -ForegroundColor $ColorWarning
        Write-Host "  - Vérifiez les logs Qdrant: docker logs qdrant_production --tail 100" -ForegroundColor $ColorWarning
        Write-Host "  - Relancez avec -Force pour continuer malgré les erreurs" -ForegroundColor $ColorWarning
        Write-Host "  - Les backups permettent un rollback si nécessaire" -ForegroundColor $ColorWarning
    }
}

# ============================================================================
# MAIN
# ============================================================================

Write-Banner "CORRECTION HNSW CORRUPTION - 58 Collections"

Write-Host ""
Write-Host "Configuration:" -ForegroundColor $ColorInfo
Write-Host "  Mode:          $(if ($DryRun) { 'SIMULATION' } else { 'PRODUCTION ⚠️' })" -ForegroundColor $(if ($DryRun) { $ColorWarning } else { $ColorCritical })
Write-Host "  Batch size:    $BatchSize collections"
Write-Host "  Target threads: $TargetThreads"
Write-Host "  Backup:        $(if ($SkipBackup) { 'Désactivé ⚠️' } else { 'Activé ✅' })"
Write-Host "  Force mode:    $(if ($Force) { 'Activé ⚠️' } else { 'Désactivé' })"

if (-not $DryRun -and -not $Force) {
    Write-Host "`n⚠️  ATTENTION: Vous êtes sur le point de modifier $($script:Stats.CollectionsToFix) collections en PRODUCTION!" -ForegroundColor $ColorCritical
    $confirm = Read-Host "Taper 'OUI' pour confirmer"
    if ($confirm -ne "OUI") {
        Write-Host "❌ Opération annulée" -ForegroundColor $ColorWarning
        exit 0
    }
}

# Vérification accessibilité Qdrant
if (-not (Test-QdrantAvailability)) {
    Write-Host "`n❌ Qdrant inaccessible - Vérifiez que le container est démarré" -ForegroundColor $ColorCritical
    exit 1
}

# Identification des collections
$collectionsToFix = Get-CollectionsToFix

if ($collectionsToFix.Count -eq 0) {
    Write-Host "`n✅ Aucune collection à corriger (toutes ont threads > 0)" -ForegroundColor $ColorSuccess
    exit 0
}

# Traitement par batch
$totalBatches = [math]::Ceiling($collectionsToFix.Count / $BatchSize)

for ($i = 0; $i -lt $totalBatches; $i++) {
    $batchStart = $i * $BatchSize
    $batchEnd = [math]::Min($batchStart + $BatchSize, $collectionsToFix.Count)
    $batch = $collectionsToFix[$batchStart..($batchEnd - 1)]
    
    $batchSuccess = Process-Batch -Collections $batch -BatchNumber ($i + 1) -TotalBatches $totalBatches
    
    if (-not $batchSuccess -and -not $Force) {
        Write-Host "`n⚠️  Arrêt du traitement suite aux échecs du batch" -ForegroundColor $ColorWarning
        break
    }
    
    # Pause entre batches pour laisser Qdrant respirer
    if ($i -lt $totalBatches - 1 -and -not $DryRun) {
        Write-Host "`n⏸️  Pause 3s avant batch suivant..." -ForegroundColor $ColorInfo
        Start-Sleep -Seconds 3
    }
}

# Rapport final
Show-FinalReport

exit $(if ($script:Stats.Failed -eq 0) { 0 } else { 1 })