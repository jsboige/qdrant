#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Diagnostic approfondi des ressources système (RAM/Disque) pour identifier les causes de redémarrages fréquents
    
.DESCRIPTION
    Ce script analyse:
    - RAM système Windows et WSL2
    - Processus consommateurs
    - Limites Docker et containers
    - Swap/Pagefile
    - Espace disque et logs
    - Memory leaks potentiels
    - Configuration WSL et Docker
    
.PARAMETER OutputPath
    Chemin du fichier de rapport (défaut: docs/diagnostics/20251014_DIAGNOSTIC_RESSOURCES_RAPPORT.md)
    
.EXAMPLE
    .\20251014_diagnostic_ressources_systeme.ps1
    .\20251014_diagnostic_ressources_systeme.ps1 -OutputPath "custom_report.md"
#>

param(
    [string]$OutputPath = "docs/diagnostics/20251014_DIAGNOSTIC_RESSOURCES_RAPPORT.md"
)

# Initialisation
$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$reportContent = @()

# En-tête du rapport
$reportContent += "# RAPPORT DIAGNOSTIC RESSOURCES SYSTÈME"
$reportContent += ""
$reportContent += "**Date**: $timestamp"
$reportContent += "**Objectif**: Identifier la cause racine des redémarrages fréquents (RAM/Disque/Memory Leaks)"
$reportContent += ""
$reportContent += "---"
$reportContent += ""

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "DIAGNOSTIC RESSOURCES SYSTÈME" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# PHASE 1: DIAGNOSTIC MÉMOIRE RAM
# ============================================================================

Write-Host "[PHASE 1] Diagnostic Mémoire RAM" -ForegroundColor Yellow
$reportContent += "## PHASE 1: DIAGNOSTIC MÉMOIRE RAM"
$reportContent += ""

# 1.1 RAM Système Windows
Write-Host "  [1.1] Analyse RAM système Windows..." -ForegroundColor Cyan
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedRAM = $totalRAM - $freeRAM
    $percentUsed = [math]::Round(($usedRAM / $totalRAM) * 100, 2)
    
    $ramStatus = if ($percentUsed -gt 90) { "🔴 CRITIQUE" } elseif ($percentUsed -gt 80) { "🟡 ATTENTION" } else { "🟢 OK" }
    
    Write-Host "    Total RAM: $totalRAM GB" -ForegroundColor White
    Write-Host "    RAM utilisée: $usedRAM GB ($percentUsed%)" -ForegroundColor $(if ($percentUsed -gt 90) { 'Red' } elseif ($percentUsed -gt 80) { 'Yellow' } else { 'Green' })
    Write-Host "    RAM libre: $freeRAM GB" -ForegroundColor $(if ($freeRAM -lt 2) { 'Red' } elseif ($freeRAM -lt 4) { 'Yellow' } else { 'Green' })
    
    $reportContent += "### 1.1 RAM Système Windows"
    $reportContent += ""
    $reportContent += "| Métrique | Valeur | Statut |"
    $reportContent += "|----------|--------|--------|"
    $reportContent += "| **Total RAM** | $totalRAM GB | - |"
    $reportContent += "| **RAM utilisée** | $usedRAM GB ($percentUsed%) | $ramStatus |"
    $reportContent += "| **RAM libre** | $freeRAM GB | $(if ($freeRAM -lt 2) { '🔴' } elseif ($freeRAM -lt 4) { '🟡' } else { '🟢' }) |"
    $reportContent += ""
    
    if ($percentUsed -gt 90) {
        Write-Host "    ❌ CRITIQUE: RAM système saturée à plus de 90%" -ForegroundColor Red
        $reportContent += "**⚠️ ALERTE CRITIQUE**: RAM système saturée (>90%), risque élevé d'OOM et crashs"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse RAM: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser la RAM système"
    $reportContent += ""
}

# 1.2 RAM WSL2
Write-Host "  [1.2] Analyse RAM WSL2..." -ForegroundColor Cyan
try {
    $wslProcesses = Get-Process | Where-Object { $_.Name -like '*wsl*' -or $_.Name -eq 'vmmem' }
    if ($wslProcesses) {
        $totalWSLMem = ($wslProcesses | Measure-Object WorkingSet64 -Sum).Sum / 1GB
        $wslStatus = if ($totalWSLMem -gt 8) { "🔴 CRITIQUE" } elseif ($totalWSLMem -gt 6) { "🟡 ATTENTION" } else { "🟢 OK" }
        
        Write-Host "    Mémoire WSL2 totale: $([math]::Round($totalWSLMem, 2)) GB" -ForegroundColor $(if ($totalWSLMem -gt 8) { 'Red' } elseif ($totalWSLMem -gt 6) { 'Yellow' } else { 'Green' })
        
        $reportContent += "### 1.2 RAM WSL2"
        $reportContent += ""
        $reportContent += "| Processus | Mémoire (GB) | Statut |"
        $reportContent += "|-----------|--------------|--------|"
        
        foreach ($proc in $wslProcesses) {
            $mem = [math]::Round($proc.WorkingSet64 / 1GB, 2)
            Write-Host "      $($proc.Name): $mem GB"
            $reportContent += "| $($proc.Name) | $mem GB | - |"
        }
        
        $reportContent += "| **TOTAL WSL2** | $([math]::Round($totalWSLMem, 2)) GB | $wslStatus |"
        $reportContent += ""
    } else {
        Write-Host "    ⚠️ Aucun processus WSL2 détecté" -ForegroundColor Yellow
        $reportContent += "### 1.2 RAM WSL2"
        $reportContent += ""
        $reportContent += "⚠️ Aucun processus WSL2 actif détecté"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse WSL2: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser WSL2"
    $reportContent += ""
}

# 1.3 Top 10 Processus RAM
Write-Host "  [1.3] Top 10 processus consommateurs RAM..." -ForegroundColor Cyan
try {
    $topProcesses = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10
    
    $reportContent += "### 1.3 Top 10 Processus Consommateurs RAM"
    $reportContent += ""
    $reportContent += "| Rang | Processus | RAM (GB) | CPU | PID |"
    $reportContent += "|------|-----------|----------|-----|-----|"
    
    $rank = 1
    foreach ($proc in $topProcesses) {
        $ramGB = [math]::Round($proc.WorkingSet64 / 1GB, 2)
        $cpuTime = if ($proc.CPU) { [math]::Round($proc.CPU, 2) } else { "N/A" }
        Write-Host "    $rank. $($proc.Name): $ramGB GB (CPU: $cpuTime)"
        $reportContent += "| $rank | $($proc.Name) | $ramGB GB | $cpuTime | $($proc.Id) |"
        $rank++
    }
    $reportContent += ""
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse processus: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser les processus"
    $reportContent += ""
}

# 1.4 Limites Mémoire Container Docker
Write-Host "  [1.4] Analyse limites mémoire Docker..." -ForegroundColor Cyan
try {
    $inspectJson = docker inspect qdrant_production 2>&1
    if ($LASTEXITCODE -eq 0) {
        $inspect = $inspectJson | ConvertFrom-Json
        $memLimit = $inspect[0].HostConfig.Memory
        
        $reportContent += "### 1.4 Limites Mémoire Container Docker"
        $reportContent += ""
        
        if ($memLimit -eq 0) {
            Write-Host "    ⚠️ Aucune limite mémoire configurée (illimité)" -ForegroundColor Yellow
            $reportContent += "⚠️ **Aucune limite mémoire configurée** - Container peut consommer toute la RAM disponible (RISQUE)"
            $reportContent += ""
        } else {
            $limitGB = [math]::Round($memLimit / 1GB, 2)
            Write-Host "    Limite mémoire: $limitGB GB" -ForegroundColor Green
            $reportContent += "✅ Limite mémoire configurée: **$limitGB GB**"
            $reportContent += ""
        }
        
        Write-Host "    Stats actuelles container:" -ForegroundColor Cyan
        $stats = docker stats qdrant_production --no-stream --format "{{.Container}};{{.CPUPerc}};{{.MemUsage}};{{.MemPerc}}" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $statsParts = $stats -split ';'
            Write-Host "      CPU: $($statsParts[1])"
            Write-Host "      Mémoire: $($statsParts[2]) ($($statsParts[3]))"
            
            $reportContent += "**Stats actuelles:**"
            $reportContent += "- CPU: $($statsParts[1])"
            $reportContent += "- Mémoire: $($statsParts[2]) ($($statsParts[3]))"
            $reportContent += ""
        }
    } else {
        Write-Host "    ⚠️ Container qdrant_production non trouvé ou arrêté" -ForegroundColor Yellow
        $reportContent += "⚠️ Container `qdrant_production` non trouvé ou arrêté"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse Docker: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser Docker"
    $reportContent += ""
}

# 1.5 Swap/Pagefile
Write-Host "  [1.5] Analyse Swap/Pagefile..." -ForegroundColor Cyan
try {
    $pageFile = Get-CimInstance Win32_PageFileUsage
    if ($pageFile) {
        $allocated = [math]::Round($pageFile.AllocatedBaseSize / 1024, 2)
        $current = [math]::Round($pageFile.CurrentUsage / 1024, 2)
        $percentUsed = [math]::Round(($current / $allocated) * 100, 2)
        
        $swapStatus = if ($percentUsed -gt 80) { "🔴 CRITIQUE" } elseif ($percentUsed -gt 60) { "🟡 ATTENTION" } else { "🟢 OK" }
        
        Write-Host "    Pagefile alloué: $allocated GB" -ForegroundColor Cyan
        Write-Host "    Pagefile utilisé: $current GB ($percentUsed%)" -ForegroundColor $(if ($percentUsed -gt 80) { 'Red' } elseif ($percentUsed -gt 60) { 'Yellow' } else { 'Green' })
        
        $reportContent += "### 1.5 Swap/Pagefile"
        $reportContent += ""
        $reportContent += "| Métrique | Valeur | Statut |"
        $reportContent += "|----------|--------|--------|"
        $reportContent += "| **Pagefile alloué** | $allocated GB | - |"
        $reportContent += "| **Pagefile utilisé** | $current GB ($percentUsed%) | $swapStatus |"
        $reportContent += ""
        
        if ($percentUsed -gt 80) {
            Write-Host "    ❌ CRITIQUE: Pagefile saturé, système en thrashing" -ForegroundColor Red
            $reportContent += "**⚠️ ALERTE CRITIQUE**: Pagefile saturé (>80%), système en thrashing - performances dégradées"
            $reportContent += ""
        }
    } else {
        Write-Host "    ⚠️ Aucun pagefile configuré" -ForegroundColor Yellow
        $reportContent += "⚠️ Aucun pagefile Windows configuré"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse pagefile: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser le pagefile"
    $reportContent += ""
}

Write-Host ""

# ============================================================================
# PHASE 2: DIAGNOSTIC ESPACE DISQUE
# ============================================================================

Write-Host "[PHASE 2] Diagnostic Espace Disque" -ForegroundColor Yellow
$reportContent += "## PHASE 2: DIAGNOSTIC ESPACE DISQUE"
$reportContent += ""

# 2.1 Espace Disque Système
Write-Host "  [2.1] Analyse espace disque système..." -ForegroundColor Cyan
try {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 }
    
    $reportContent += "### 2.1 Espace Disque Système"
    $reportContent += ""
    $reportContent += "| Lecteur | Utilisé | Total | Libre | % Utilisé | Statut |"
    $reportContent += "|---------|---------|-------|-------|-----------|--------|"
    
    foreach ($drive in $drives) {
        $percentUsed = [math]::Round(($drive.Used / ($drive.Used + $drive.Free)) * 100, 2)
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        $usedGB = [math]::Round($drive.Used / 1GB, 2)
        $totalGB = $usedGB + $freeGB
        
        $status = if ($percentUsed -gt 95) { "🔴 CRITIQUE" } elseif ($percentUsed -gt 90) { "🟡 ATTENTION" } else { "🟢 OK" }
        $color = if ($percentUsed -gt 95) { 'Red' } elseif ($percentUsed -gt 90) { 'Yellow' } else { 'Green' }
        
        Write-Host "    $($drive.Name): $usedGB GB / $totalGB GB ($percentUsed%) - Libre: $freeGB GB" -ForegroundColor $color
        $reportContent += "| $($drive.Name): | $usedGB GB | $totalGB GB | $freeGB GB | $percentUsed% | $status |"
        
        if ($percentUsed -gt 95) {
            Write-Host "      ❌ CRITIQUE: Disque $($drive.Name) presque plein!" -ForegroundColor Red
        }
    }
    $reportContent += ""
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse disque: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser l'espace disque"
    $reportContent += ""
}

# 2.2 Taille Logs Qdrant
Write-Host "  [2.2] Analyse taille logs Qdrant..." -ForegroundColor Cyan
try {
    $logPath = "\\wsl.localhost\Ubuntu\home\MYIA\qdrant_data\storage"
    if (Test-Path $logPath) {
        $files = Get-ChildItem -Path $logPath -Recurse -File -ErrorAction SilentlyContinue
        $logSize = ($files | Measure-Object -Property Length -Sum).Sum / 1GB
        $logSizeRounded = [math]::Round($logSize, 2)
        
        $logStatus = if ($logSize -gt 50) { "🔴 CRITIQUE" } elseif ($logSize -gt 20) { "🟡 ATTENTION" } else { "🟢 OK" }
        
        Write-Host "    Taille totale storage Qdrant: $logSizeRounded GB" -ForegroundColor $(if ($logSize -gt 50) { 'Red' } elseif ($logSize -gt 20) { 'Yellow' } else { 'Green' })
        
        $reportContent += "### 2.2 Taille Logs/Storage Qdrant"
        $reportContent += ""
        $reportContent += "**Taille totale storage**: $logSizeRounded GB | Statut: $logStatus"
        $reportContent += ""
        
        if ($logSize -gt 50) {
            Write-Host "    ❌ CRITIQUE: Storage Qdrant dépasse 50 GB" -ForegroundColor Red
            Write-Host "       Les logs peuvent remplir le disque rapidement" -ForegroundColor Red
            $reportContent += "**⚠️ ALERTE CRITIQUE**: Storage dépasse 50 GB, risque de saturation disque"
            $reportContent += ""
        }
        
        Write-Host "    Tailles par type de fichier:" -ForegroundColor Cyan
        $fileTypes = $files | Group-Object Extension | Select-Object Name, @{Name='Size_GB';Expression={[math]::Round((($_.Group | Measure-Object Length -Sum).Sum) / 1GB, 2)}} | Sort-Object Size_GB -Descending | Select-Object -First 10
        
        $reportContent += "**Tailles par type de fichier (Top 10):**"
        $reportContent += ""
        $reportContent += "| Extension | Taille (GB) |"
        $reportContent += "|-----------|-------------|"
        
        foreach ($type in $fileTypes) {
            Write-Host "      $($type.Name): $($type.Size_GB) GB"
            $reportContent += "| $($type.Name) | $($type.Size_GB) GB |"
        }
        $reportContent += ""
    } else {
        Write-Host "    ⚠️ Impossible d'accéder au répertoire storage WSL" -ForegroundColor Yellow
        $reportContent += "⚠️ Impossible d'accéder au répertoire storage Qdrant dans WSL"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse logs Qdrant: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser les logs Qdrant"
    $reportContent += ""
}

# 2.3 Taille Logs Docker
Write-Host "  [2.3] Analyse taille logs Docker container..." -ForegroundColor Cyan
try {
    $logPathCmd = docker inspect qdrant_production --format='{{.LogPath}}' 2>&1
    if ($LASTEXITCODE -eq 0 -and $logPathCmd) {
        # Extraire le chemin WSL
        $wslLogPath = $logPathCmd -replace '^/var/lib/docker', '\\wsl.localhost\docker-desktop-data\data\docker'
        
        if (Test-Path $logPathCmd) {
            $logSizeMB = [math]::Round((Get-Item $logPathCmd).Length / 1MB, 2)
            $logStatus = if ($logSizeMB -gt 1000) { "🔴 CRITIQUE" } elseif ($logSizeMB -gt 500) { "🟡 ATTENTION" } else { "🟢 OK" }
            
            Write-Host "    Taille log container: $logSizeMB MB" -ForegroundColor $(if ($logSizeMB -gt 1000) { 'Red' } elseif ($logSizeMB -gt 500) { 'Yellow' } else { 'Green' })
            
            $reportContent += "### 2.3 Taille Logs Docker Container"
            $reportContent += ""
            $reportContent += "**Taille log container**: $logSizeMB MB | Statut: $logStatus"
            $reportContent += ""
            
            if ($logSizeMB -gt 1000) {
                Write-Host "    ❌ CRITIQUE: Log Docker dépasse 1 GB" -ForegroundColor Red
                Write-Host "       Recommandation: Configurer log rotation dans docker-compose" -ForegroundColor Yellow
                $reportContent += "**⚠️ ALERTE**: Log Docker dépasse 1 GB, nécessite configuration de log rotation"
                $reportContent += ""
            }
        } else {
            Write-Host "    ⚠️ Chemin log inaccessible: $logPathCmd" -ForegroundColor Yellow
            $reportContent += "⚠️ Chemin log Docker inaccessible"
            $reportContent += ""
        }
    } else {
        Write-Host "    ⚠️ Impossible de récupérer le chemin log Docker" -ForegroundColor Yellow
        $reportContent += "⚠️ Impossible de récupérer le chemin log Docker"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse logs Docker: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser les logs Docker"
    $reportContent += ""
}

# 2.4 Espace Disque WSL2
Write-Host "  [2.4] Analyse espace disque WSL2..." -ForegroundColor Cyan
try {
    $wslDf = wsl df -h 2>&1 | Select-String -Pattern '/home|/mnt'
    
    $reportContent += "### 2.4 Espace Disque WSL2"
    $reportContent += ""
    $reportContent += '```'
    
    foreach ($line in $wslDf) {
        Write-Host "    $line"
        $reportContent += $line.ToString()
    }
    
    $reportContent += '```'
    $reportContent += ""
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse disque WSL2: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser l'espace disque WSL2"
    $reportContent += ""
}

Write-Host ""

# ============================================================================
# PHASE 3: ANALYSE CROISSANCE (MEMORY LEAKS)
# ============================================================================

Write-Host "[PHASE 3] Analyse Croissance Mémoire (Memory Leaks)" -ForegroundColor Yellow
$reportContent += "## PHASE 3: ANALYSE CROISSANCE MÉMOIRE (MEMORY LEAKS)"
$reportContent += ""

# 3.1 Analyse Logs Qdrant - Croissance
Write-Host "  [3.1] Analyse croissance logs Qdrant..." -ForegroundColor Cyan
try {
    $logPath = "\\wsl.localhost\Ubuntu\home\MYIA\qdrant_data\storage"
    if (Test-Path $logPath) {
        $recentFiles = Get-ChildItem -Path $logPath -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10
        
        $reportContent += "### 3.1 Derniers Fichiers Créés/Modifiés (Top 10)"
        $reportContent += ""
        $reportContent += "| Fichier | Taille (MB) | Dernière Modification |"
        $reportContent += "|---------|-------------|----------------------|"
        
        Write-Host "    Derniers fichiers créés/modifiés:" -ForegroundColor Cyan
        foreach ($file in $recentFiles) {
            $sizeMB = [math]::Round($file.Length / 1MB, 2)
            Write-Host "      $($file.Name): $sizeMB MB - $($file.LastWriteTime)"
            $reportContent += "| $($file.Name) | $sizeMB MB | $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) |"
        }
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de l'analyse croissance: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible d'analyser la croissance des logs"
    $reportContent += ""
}

# 3.2 Taux de Croissance Mémoire Container
Write-Host "  [3.2] Mesure taux de croissance mémoire container..." -ForegroundColor Cyan
try {
    $statsCmd = docker stats qdrant_production --no-stream --format '{{.MemUsage}}' 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Extraction mémoire (format: "XXX.YMiB / ZZZ.YGiB")
        if ($statsCmd -match '([0-9.]+)(MiB|GiB)') {
            $mem1Value = [double]$matches[1]
            $mem1Unit = $matches[2]
            $mem1GB = if ($mem1Unit -eq "GiB") { $mem1Value } else { $mem1Value / 1024 }
            
            Write-Host "    Mémoire initiale: $([math]::Round($mem1GB, 3)) GB" -ForegroundColor Cyan
            Write-Host "    Attente 30 secondes pour mesure croissance..." -ForegroundColor Yellow
            
            Start-Sleep -Seconds 30
            
            $statsCmd2 = docker stats qdrant_production --no-stream --format '{{.MemUsage}}' 2>&1
            if ($LASTEXITCODE -eq 0 -and $statsCmd2 -match '([0-9.]+)(MiB|GiB)') {
                $mem2Value = [double]$matches[1]
                $mem2Unit = $matches[2]
                $mem2GB = if ($mem2Unit -eq "GiB") { $mem2Value } else { $mem2Value / 1024 }
                
                Write-Host "    Mémoire après 30s: $([math]::Round($mem2GB, 3)) GB" -ForegroundColor Cyan
                
                $growth = $mem2GB - $mem1GB
                $growthRounded = [math]::Round($growth, 4)
                
                Write-Host "    Croissance: $growthRounded GB en 30s" -ForegroundColor $(if ([math]::Abs($growth) -gt 0.1) { 'Red' } else { 'Green' })
                
                $reportContent += "### 3.2 Taux de Croissance Mémoire Container"
                $reportContent += ""
                $reportContent += "| Mesure | Valeur |"
                $reportContent += "|--------|--------|"
                $reportContent += "| **Mémoire initiale** | $([math]::Round($mem1GB, 3)) GB |"
                $reportContent += "| **Mémoire après 30s** | $([math]::Round($mem2GB, 3)) GB |"
                $reportContent += "| **Croissance** | $growthRounded GB/30s |"
                $reportContent += "| **Projection horaire** | $([math]::Round($growth * 120, 2)) GB/h |"
                $reportContent += ""
                
                if ([math]::Abs($growth) -gt 0.1) {
                    Write-Host "    ❌ CRITIQUE: Memory leak détecté (>100 MB en 30s)" -ForegroundColor Red
                    Write-Host "       Projection: $([math]::Round($growth * 120, 2)) GB par heure" -ForegroundColor Red
                    $reportContent += "**⚠️ ALERTE CRITIQUE**: Memory leak détecté - croissance >100 MB en 30s"
                    $reportContent += ""
                    $reportContent += "**Projection**: Container consommera **$([math]::Round($growth * 120, 2)) GB supplémentaires par heure**"
                    $reportContent += ""
                }
            }
        }
    } else {
        Write-Host "    ⚠️ Container non disponible pour mesure" -ForegroundColor Yellow
        $reportContent += "⚠️ Container non disponible pour mesure de croissance"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de la mesure croissance: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible de mesurer la croissance mémoire"
    $reportContent += ""
}

Write-Host ""

# ============================================================================
# PHASE 4: CONFIGURATION DOCKER & WSL
# ============================================================================

Write-Host "[PHASE 4] Analyse Configuration Docker & WSL" -ForegroundColor Yellow
$reportContent += "## PHASE 4: CONFIGURATION DOCKER & WSL"
$reportContent += ""

# 4.1 Configuration .wslconfig
Write-Host "  [4.1] Vérification configuration .wslconfig..." -ForegroundColor Cyan
try {
    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    
    $reportContent += "### 4.1 Configuration WSL2 (.wslconfig)"
    $reportContent += ""
    
    if (Test-Path $wslConfigPath) {
        Write-Host "    ✅ Fichier .wslconfig trouvé" -ForegroundColor Green
        $wslConfig = Get-Content $wslConfigPath
        
        $reportContent += "**Fichier .wslconfig existant:**"
        $reportContent += ""
        $reportContent += '```ini'
        
        foreach ($line in $wslConfig) {
            Write-Host "    $line"
            $reportContent += $line
        }
        
        $reportContent += '```'
        $reportContent += ""
    } else {
        Write-Host "    ⚠️ Aucun fichier .wslconfig trouvé" -ForegroundColor Yellow
        Write-Host "       WSL2 utilise les limites par défaut:" -ForegroundColor Yellow
        Write-Host "       - Mémoire: 50% RAM système (ou 8 GB max si <16 GB RAM)" -ForegroundColor Yellow
        Write-Host "       - Swap: 25% RAM système" -ForegroundColor Yellow
        
        $reportContent += "⚠️ **Aucun fichier .wslconfig configuré**"
        $reportContent += ""
        $reportContent += "WSL2 utilise les limites par défaut:"
        $reportContent += "- Mémoire: 50% RAM système (ou 8 GB max si <16 GB RAM)"
        $reportContent += "- Swap: 25% RAM système"
        $reportContent += ""
        $reportContent += "**Recommandation**: Créer `.wslconfig` pour limiter consommation WSL2"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de la vérification .wslconfig: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible de vérifier .wslconfig"
    $reportContent += ""
}

# 4.2 Limites docker-compose
Write-Host "  [4.2] Vérification limites docker-compose..." -ForegroundColor Cyan
try {
    $composeFile = "docker-compose.production.yml"
    
    $reportContent += "### 4.2 Limites Docker Compose"
    $reportContent += ""
    
    if (Test-Path $composeFile) {
        $limitsFound = Select-String -Path $composeFile -Pattern 'mem_limit|memory|cpus|memswap' -Context 1
        
        if ($limitsFound) {
            Write-Host "    ✅ Limites trouvées dans docker-compose:" -ForegroundColor Green
            
            $reportContent += "**Limites configurées dans ${composeFile}:**"
            $reportContent += ""
            $reportContent += '```yaml'
            
            foreach ($match in $limitsFound) {
                Write-Host "    $($match.Line)"
                $reportContent += $match.Line
            }
            
            $reportContent += '```'
            $reportContent += ""
        } else {
            Write-Host "    ⚠️ Aucune limite mémoire trouvée dans docker-compose" -ForegroundColor Yellow
            $reportContent += "⚠️ **Aucune limite mémoire configurée** dans docker-compose"
            $reportContent += ""
            $reportContent += "**Recommandation**: Ajouter limites mémoire pour éviter consommation excessive"
            $reportContent += ""
        }
    } else {
        Write-Host "    ⚠️ Fichier docker-compose.production.yml non trouvé" -ForegroundColor Yellow
        $reportContent += "⚠️ Fichier $composeFile non trouvé"
        $reportContent += ""
    }
} catch {
    Write-Host "    ❌ Erreur lors de la vérification docker-compose: $_" -ForegroundColor Red
    $reportContent += "**Erreur**: Impossible de vérifier docker-compose"
    $reportContent += ""
}

Write-Host ""

# ============================================================================
# GÉNÉRATION RAPPORT FINAL
# ============================================================================

Write-Host "[RAPPORT] Génération du rapport final..." -ForegroundColor Yellow

# Créer le répertoire si nécessaire
$reportDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

# Ajouter section synthèse
$reportContent += ""
$reportContent += "---"
$reportContent += ""
$reportContent += "## SYNTHÈSE ET RECOMMANDATIONS"
$reportContent += ""
$reportContent += "*Cette section sera complétée après analyse des résultats ci-dessus*"
$reportContent += ""

# Écrire le rapport
$reportContent | Out-File -FilePath $OutputPath -Encoding UTF8

Write-Host "✅ Rapport généré: $OutputPath" -ForegroundColor Green
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "DIAGNOSTIC TERMINÉ" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan