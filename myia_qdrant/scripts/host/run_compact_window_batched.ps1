<#
.SYNOPSIS
    Enveloppe d'UNE SEULE elevation pour la fenetre de compaction VHDX qdrant (2026-10-29).
.DESCRIPTION
    Enchaine, dans UNE seule session elevee :
      0) deploiement du script de compaction corrige (l'original est conserve en .bak) ;
      1) PASSE DE VALIDATION (-SkipOptimize) : toute la sequence demontage/remontage est
         exercee SANS reclaim -> preuve que le detach/remount se fait proprement ;
      2) PORTE DE CONTROLE : healthz + device resolu par LABEL qdrant-e + sentinelle 285 o
         lue dans le namespace PID-1 + >= 117 collections + roo_tasks green / optimizer ok /
         points >= plancher. Un seul controle en echec -> PAS de passe reelle : les gardes
         sont re-armees et l'enveloppe sort ;
      3) PASSE REELLE (-OptimizeMode <mode>) ;
      4) CLOTURE : close_compact_window.ps1 (re-arme les DEUX gardes + criteres stricts).
    Pourquoi une enveloppe : run_compact_window.ps1 (v2) se RE-LANCE en eleve a chaque
    invocation (donc 1 UAC par passe). L'enveloppe permet validation + passe reelle sous
    UN SEUL clic UAC, avec une porte de controle entre les deux.
    Regles : powershell.exe 5.1 (jamais pwsh), journal dans ProgramData\maint-scripts\logs,
    aucune suppression : l'original deploye est conserve en .bak horodate.
.PARAMETER OptimizeMode
    Quick (defaut : ne reclame que les blocs liberes par le trim, pas de scan zero) |
    Full (scan zero, plus exigeant en espace) | Retrim.
.PARAMETER ValidationTimeoutMinutes
    Duree max d'attente de la passe de validation (defaut 60).
.PARAMETER RealTimeoutMinutes
    Duree max d'attente de la passe reelle (defaut 180).
.MACHINES
    myia-ai-01
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\qdrant\myia_qdrant\scripts\host\run_compact_window_batched.ps1
.NOTES
    Le mode Quick est choisi par defaut : l'espace mort du VHDX est du bloc *trimme* (liberé
    par fstrim), pas des blocs zéros -- le scan zero de Full est donc inutile ici et
    Optimize-VHD consomme de l'espace hote (le volume ne pourrait pas héberger original +
    copie temporaire).
#>
[CmdletBinding()]
param(
    [string]$RepoScripts = "D:\qdrant\myia_qdrant\scripts\host",
    [string]$DeployDir = "C:\ProgramData\maint-scripts",
    [ValidateSet("Full","Quick","Retrim")]
    [string]$OptimizeMode = "Quick",
    [int]$ValidationTimeoutMinutes = 45,
    [int]$RealTimeoutMinutes = 60
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $DeployDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("compact-batch-{0}.log" -f (Get-Date -f yyyyMMdd-HHmmss))

function Log {
    param([string]$Msg, [string]$Lvl = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "HH:mm:ss"), $Lvl, $Msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Wait-TaskIdle {
    # Attend que la tache ait DEMARRE (LastRunTime > $After) puis qu'elle ne soit plus
    # 'Running' (le FINALLY du script de compaction fait le remontage AVANT la fin).
    param([string]$TaskName, [datetime]$After, [int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $seen = $false
    while ((Get-Date) -lt $deadline) {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t) {
            if (-not $seen -and $t.LastRunTime -and $t.LastRunTime -gt $After) {
                $seen = $true
                Log "  tache '$TaskName' demarree a $($t.LastRunTime)."
            }
            if ($seen -and $t.State -ne 'Running') { Start-Sleep 25; return $true }
        }
        Start-Sleep 15
    }
    Log "  delai depasse pour '$TaskName' (vue : demarre=$seen)." "ERROR"
    return $false
}

function Test-StoreHealthy {
    $res = @{}
    $lsblk = (wsl.exe -u root -- lsblk -no LABEL,NAME 2>&1 | Out-String)
    $dev = $null
    foreach ($line in ($lsblk -split "`r?`n")) {
        $p = ($line.Trim() -split '\s+')
        if ($p.Count -ge 2 -and $p[0] -eq 'qdrant-e') { $dev = $p[1]; break }
    }
    $res['label'] = [bool]$dev
    if ($dev) { $res['device'] = $dev } else { $res['device'] = 'aucun' }
    $sent = (wsl.exe -u root -- nsenter -t 1 -m -- stat -c %s /mnt/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>&1 | Out-String).Trim()
    $res['sentinel'] = ($sent -eq '285')
    $res['sentinelRaw'] = $sent
    try {
        $h = Invoke-WebRequest -Uri http://localhost:6333/healthz -UseBasicParsing -TimeoutSec 15
        $res['healthz'] = ($h.StatusCode -eq 200)
    } catch { $res['healthz'] = $false }
    $apiKey = $null
    $envFile = "D:\qdrant\myia_qdrant\.env.production"
    if (Test-Path $envFile) {
        $m = [regex]::Match((Get-Content $envFile -Raw), '(?m)^QDRANT__SERVICE__API_KEY=(.+)$')
        if ($m.Success) { $apiKey = $m.Groups[1].Value.Trim() }
    }
    $nb = 0; $status = ''; $opt = ''; $pts = 0
    if ($apiKey) {
        $H = @{ 'api-key' = $apiKey }
        try { $c = Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $H -TimeoutSec 30; $nb = @($c.result.collections).Count } catch { }
        try { $r = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $H -TimeoutSec 30; $status = [string]$r.result.status; $opt = [string]$r.result.optimizer_status; $pts = [long]$r.result.points_count } catch { }
    }
    $res['collections'] = $nb
    $res['status'] = $status
    $res['optimizer'] = $opt
    $res['points'] = $pts
    $res['ok'] = ($res['label'] -and $res['sentinel'] -and $res['healthz'] -and $nb -ge 117 -and $status -eq 'green' -and $opt -eq 'ok' -and $pts -ge 1500000)
    return $res
}

# --- Admin ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "Privileges Admin requis (relance via Start-Process -Verb RunAs)." "ERROR"
    exit 2
}

$compactLive = Join-Path $DeployDir "compact_qdrant_vhdx.ps1"
$v2 = Join-Path $DeployDir "run_compact_window.ps1"
$closeLive = Join-Path $DeployDir "close_compact_window.ps1"
$srcCompact = Join-Path $RepoScripts "compact_qdrant_vhdx.ps1"
foreach ($f in @($compactLive, $v2, $closeLive, $srcCompact)) {
    if (-not (Test-Path $f)) { Log "Fichier absent : $f" "ERROR"; exit 3 }
}

$vhdxPath = "E:\wsl-data\qdrant.vhdx"
$vhdxGo = [math]::Round((Get-Item $vhdxPath).Length / 1GB, 1)
$freeGo = [math]::Round((Get-Volume E).SizeRemaining / 1GB, 1)

# --- Garde-fou horaire : le backup de 02:17 (Qdrant-Snapshot-Daily) ne doit JAMAIS
#     croiser la fenetre. Un clic UAC tardif declencherait sinon la compaction pile sur
#     le backup. Refus propre (exit 5), aucune modif.
$now = Get-Date
$backupAt = $now.Date.AddHours(2).AddMinutes(17)
if ($backupAt -le $now) { $backupAt = $now.Date.AddDays(1).AddHours(2).AddMinutes(17) }
$minutesToBackup = ($backupAt - $now).TotalMinutes
if ($minutesToBackup -lt 100) {
    Log "FENETRE REFUSEE : seulement $([math]::Round($minutesToBackup)) min avant le backup de 02:17 (la fenetre ne doit jamais croiser le backup)." "ERROR"
    exit 5
}

Log "=== FENETRE DE COMPACTION BATCHEE (1 elevation) ==="
Log "VHDX : $vhdxGo Go | E: libre : $freeGo Go | mode : $OptimizeMode"
Log "Backup 02:17 dans $([math]::Round($minutesToBackup)) min (garde-fou horaire respecte)."

# --- 0) deploiement du script corrige (original conserve) ---
$bak = Join-Path $DeployDir ("compact_qdrant_vhdx.ps1.bak-{0}" -f (Get-Date -f yyyyMMdd-HHmmss))
Copy-Item $compactLive $bak -Force
Copy-Item $srcCompact $compactLive -Force
Log "Script de compaction corrige deploye : $compactLive (original conserve : $bak)"

# --- 1) PASSE DE VALIDATION ---
Log "--- PASSE 1/2 : validation de la sequence (SkipOptimize, aucun reclaim) ---"
$t0 = Get-Date
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $v2 -DryRun -OptimizeMode $OptimizeMode 2>&1 | ForEach-Object { Log "  v2: $_" }

$idle = Wait-TaskIdle -TaskName "Compact-Qdrant-VHDX" -After $t0 -TimeoutMinutes $ValidationTimeoutMinutes
if (-not $idle) {
    Log "PASSE DE VALIDATION : non aboutie dans le delai -> pas de passe reelle." "ERROR"
} else {
    $chk = Test-StoreHealthy
    Log ("PORTE DE CONTROLE : label={0} ({1}) sentinelle={2} ({3}) healthz={4} collections={5} status={6} optimizer={7} points={8} => {9}" -f `
        $chk['label'], $chk['device'], $chk['sentinel'], $chk['sentinelRaw'], $chk['healthz'], $chk['collections'], $chk['status'], $chk['optimizer'], $chk['points'], $(if ($chk['ok']) { 'OK' } else { 'ECHEC' }))
    if ($chk['ok']) {
        Log "--- PASSE 2/2 : compaction reelle (mode $OptimizeMode) ---"
        $t1 = Get-Date
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $v2 -OptimizeMode $OptimizeMode 2>&1 | ForEach-Object { Log "  v2: $_" }
        if (Wait-TaskIdle -TaskName "Compact-Qdrant-VHDX" -After $t1 -TimeoutMinutes $RealTimeoutMinutes) {
            Log "Passe reelle terminee -> cloture (re-armement des gardes + criteres stricts)."
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $closeLive 2>&1 | ForEach-Object { Log "  close: $_" }
        } else {
            Log "PASSE REELLE : delai depasse." "ERROR"
        }
    } else {
        Log "PORTE DE CONTROLE KO -> pas de passe reelle. Re-armement des gardes." "ERROR"
        foreach ($g in @('Verify-Qdrant-Mount', 'Mount-Qdrant-VHDX')) {
            try { Enable-ScheduledTask -TaskName $g | Out-Null; Log "  garde $g re-armee." } catch { Log "  garde $g : $($_.Exception.Message)" "WARN" }
        }
    }
}

$vhdxGo2 = [math]::Round((Get-Item $vhdxPath).Length / 1GB, 1)
$freeGo2 = [math]::Round((Get-Volume E).SizeRemaining / 1GB, 1)
Log "=== BILAN ENVELOPPE ==="
Log "VHDX : $vhdxGo Go -> $vhdxGo2 Go | E: libre : $freeGo Go -> $freeGo2 Go"
Log "Journal : $logFile"
exit 0
