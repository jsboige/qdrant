#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Monitoring temps réel pour identifier l'overload causé par HNSW corrompu

.DESCRIPTION
    Ce script capture les métriques système pendant l'overload pour confirmer:
    - Saturation CPU/RAM lors de requêtes sur collections corrompues (threads=0)
    - Fragmentation excessive (segments multiples)
    - Requêtes lentes sur collections volumineuses

.EXAMPLE
    .\20251015_monitor_overload_realtime.ps1
    .\20251015_monitor_overload_realtime.ps1 -ContinuousMode -IntervalSeconds 10
#>

param(
    [switch]$ContinuousMode,
    [int]$IntervalSeconds = 5,
    [int]$Iterations = 3
)

$ErrorActionPreference = "Continue"
$API_KEY = "qdrant_admin"
$QDRANT_URL = "http://localhost:6333"

# Couleurs
$ColorCritical = "Red"
$ColorWarning = "Yellow"
$ColorSuccess = "Green"
$ColorInfo = "Cyan"

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor $ColorInfo
}

function Get-DockerStats {
    Write-Section "📊 DOCKER STATS"
    
    $stats = docker stats qdrant_production --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}"
    
    if ($stats) {
        $parts = $stats -split '\|'
        Write-Host "CPU Usage:    $($parts[0])" -ForegroundColor $(if ([double]($parts[0] -replace '%','') -gt 80) { $ColorCritical } else { $ColorSuccess })
        Write-Host "Memory:       $($parts[1]) ($($parts[2]))" -ForegroundColor $(if ([double]($parts[2] -replace '%','') -gt 80) { $ColorCritical } else { $ColorSuccess })
        Write-Host "Network I/O:  $($parts[3])"
        Write-Host "Block I/O:    $($parts[4])"
        
        return @{
            CPU = [double]($parts[0] -replace '%','')
            MemPercent = [double]($parts[2] -replace '%','')
            MemUsage = $parts[1]
            NetIO = $parts[3]
            BlockIO = $parts[4]
        }
    }
}

function Get-CollectionFragmentation {
    Write-Section "🔥 TOP 10 COLLECTIONS PAR FRAGMENTATION"
    
    try {
        $collections = curl -s -H "api-key: $API_KEY" "$QDRANT_URL/collections" | ConvertFrom-Json | Select-Object -ExpandProperty result | Select-Object -ExpandProperty collections
        
        $collectionDetails = @()
        
        foreach ($col in $collections) {
            try {
                $info = curl -s -H "api-key: $API_KEY" "$QDRANT_URL/collections/$($col.name)" | ConvertFrom-Json | Select-Object -ExpandProperty result
                
                $collectionDetails += [PSCustomObject]@{
                    Name = $col.name
                    Segments = $info.segments_count
                    Points = $info.points_count
                    Threads = $info.config.hnsw_config.max_indexing_threads
                    DiskMB = [math]::Round($info.disk_data_size / 1MB, 2)
                    IndexedVectors = $info.indexed_vectors_count
                }
            } catch {
                Write-Host "⚠️  Erreur lecture collection $($col.name)" -ForegroundColor $ColorWarning
            }
        }
        
        $top10 = $collectionDetails | Sort-Object Segments -Descending | Select-Object -First 10
        
        $top10 | Format-Table -AutoSize -Property @(
            @{Label="Collection"; Expression={$_.Name}; Width=30}
            @{Label="Segments"; Expression={$_.Segments}; Width=10}
            @{Label="Points"; Expression={$_.Points.ToString("N0")}; Width=12}
            @{Label="Threads"; Expression={
                if ($_.Threads -eq 0) { 
                    $host.UI.RawUI.ForegroundColor = $ColorCritical
                    "0 ⚠️"
                } else { 
                    $_.Threads 
                }
            }; Width=10}
            @{Label="Disk(MB)"; Expression={$_.DiskMB}; Width=10}
        )
        
        $threadsZero = ($collectionDetails | Where-Object { $_.Threads -eq 0 }).Count
        $totalCollections = $collectionDetails.Count
        
        Write-Host "`n⚠️  COLLECTIONS AVEC THREADS=0: $threadsZero / $totalCollections" -ForegroundColor $(if ($threadsZero -gt 10) { $ColorCritical } else { $ColorWarning })
        
        return $collectionDetails
    } catch {
        Write-Host "❌ Erreur lors de la récupération des collections: $_" -ForegroundColor $ColorCritical
    }
}

function Get-ClusterInfo {
    Write-Section "📡 CLUSTER STATUS"
    
    try {
        $cluster = curl -s -H "api-key: $API_KEY" "$QDRANT_URL/cluster" | ConvertFrom-Json | Select-Object -ExpandProperty result
        
        Write-Host "Status:       $($cluster.status)"
        Write-Host "Peer ID:      $($cluster.peer_id)"
        Write-Host "Raft Term:    $($cluster.raft_info.term)"
        Write-Host "Commit:       $($cluster.raft_info.commit)"
        Write-Host "Pending:      $($cluster.raft_info.pending_operations)"
    } catch {
        Write-Host "⚠️  Cluster info non disponible (mode single node?)" -ForegroundColor $ColorWarning
    }
}

function Get-ProcessInfo {
    Write-Section "🔍 PROCESSUS DOCKER"
    
    $processes = docker top qdrant_production
    Write-Host $processes
}

function Get-RecentLogs {
    Write-Section "📋 LOGS RÉCENTS (30 dernières lignes)"
    
    docker logs --tail 30 qdrant_production 2>&1 | Select-String -Pattern "error|warn|panic|timeout|overload" -Context 0,1
}

function Export-Snapshot {
    param([hashtable]$DockerStats, [array]$Collections)
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $snapshotFile = "myia_qdrant/diagnostics/overload_snapshot_$timestamp.json"
    
    $snapshot = @{
        Timestamp = Get-Date -Format "o"
        DockerStats = $DockerStats
        Collections = $Collections | Select-Object -First 20
        CriticalCollections = $Collections | Where-Object { $_.Threads -eq 0 -and $_.Points -gt 100000 }
    }
    
    $snapshot | ConvertTo-Json -Depth 5 | Out-File -FilePath $snapshotFile -Encoding UTF8
    Write-Host "`n💾 Snapshot sauvegardé: $snapshotFile" -ForegroundColor $ColorSuccess
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor $ColorInfo
Write-Host "║  MONITORING OVERLOAD QDRANT - Diagnostic HNSW Corruption     ║" -ForegroundColor $ColorInfo
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor $ColorInfo

if ($ContinuousMode) {
    Write-Host "`n🔄 Mode continu activé (Ctrl+C pour arrêter)" -ForegroundColor $ColorWarning
    Write-Host "Intervalle: $IntervalSeconds secondes`n"
    
    $iteration = 0
    while ($true) {
        $iteration++
        Write-Host "`n╔═══ ITERATION #$iteration - $(Get-Date -Format 'HH:mm:ss') ═══╗" -ForegroundColor $ColorInfo
        
        $stats = Get-DockerStats
        $collections = Get-CollectionFragmentation
        
        if ($stats.CPU -gt 90 -or $stats.MemPercent -gt 90) {
            Write-Host "`n🚨 ALERTE OVERLOAD DÉTECTÉ!" -ForegroundColor $ColorCritical
            Export-Snapshot -DockerStats $stats -Collections $collections
        }
        
        Start-Sleep -Seconds $IntervalSeconds
    }
} else {
    # Mode snapshot unique ou itérations limitées
    for ($i = 1; $i -le $Iterations; $i++) {
        Write-Host "`n╔═══ SNAPSHOT #$i/$Iterations - $(Get-Date -Format 'HH:mm:ss') ═══╗" -ForegroundColor $ColorInfo
        
        $stats = Get-DockerStats
        $collections = Get-CollectionFragmentation
        Get-ClusterInfo
        
        if ($i -lt $Iterations) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    
    Get-ProcessInfo
    Get-RecentLogs
    
    # Export final
    Export-Snapshot -DockerStats $stats -Collections $collections
}

Write-Host "`n✅ Monitoring terminé" -ForegroundColor $ColorSuccess
Write-Host "
╔══════════════════════════════════════════════════════════════════╗
║  PROCHAINE ÉTAPE: Analyser les résultats                        ║
║  Si CPU/RAM élevés + Threads=0 confirmé → Migration HNSW urgente║
╚══════════════════════════════════════════════════════════════════╝
" -ForegroundColor $ColorInfo