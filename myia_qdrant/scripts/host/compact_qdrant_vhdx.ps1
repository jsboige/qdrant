<#
.SYNOPSIS
    Compacte le VHDX Qdrant (E:\wsl-data\qdrant.vhdx) en recuperant l'espace thin-provisionne
    gonfle a vide, avec downtime Qdrant-only (Docker + les ~18 autres conteneurs restent up).
.DESCRIPTION
    Le VHDX qdrant est alloue ~876 GB sur disque mais n'utilise que ~111 GB en interne (14%).
    Les ~700 GB restants sont des blocs ext4 liberes jamais reclames (thin-provisioning ne se
    retracte pas seul). Ce script :
      1) Desactive le watchdog Verify-Qdrant-Mount (-Remediate re-monterait MID-Optimize -> corruption)
      2) Stop qdrant_autoheal (sinon il redemarre qdrant_production pendant la fenetre)
      3) docker stop qdrant_production (release le handle conteneur sur le fs)
      4) sync + fstrim -v /mnt/qdrant-e  <-- GO/NO-GO : doit reporter ~700 GB trimmed.
         Si discard non supporte, on saute l'Optimize (aucun degat) et on remonte.
      5) Clear des shims docker-desktop-bind-mounts qdrant (sinon umount EBUSY)
      6) umount /mnt/qdrant-e (namespace PID-1, celui que Docker lit)
      7) wsl --unmount \\.\PHYSICALDRIVE<N>  (detache du WSL utility VM)
      8) Dismount-VHD  (detache de l'hote Windows)
      9) Mount-VHD -ReadOnly + Optimize-VHD -Mode Full + Dismount-VHD  (reclame physiquement)
     10) finally : re-run mount_qdrant_vhdx.ps1 (re-attach + compose up qdrant), start autoheal,
         re-enable watchdog -- TOUJOURS, meme sur erreur, pour que qdrant revienne.

    NON DESTRUCTIF pour les donnees : fstrim n'agit que sur les blocs libres ; Optimize-VHD -Mode Full
    sur un VHDX monte read-only ne deplace/drop que les blocs inutilises. Les ~111 GB de donnees
    (index 41M points) sont preserves. Filet de securite supplementaire : snapshot quotidien GDrive
    (tache Qdrant-Snapshot-Daily).
.REQUIRES
    Admin (Mount-VHD / Optimize-VHD / wsl --unmount / Disable-ScheduledTask).
.MACHINES
    myia-ai-01
.NOTES
    Cree le 2026-06-20. Reverse exact de mount_qdrant_vhdx.ps1 (meme namespace PID-1, meme verif label).
    2026-10-29 : copie de reference dans le depot = version DEPLOYEE du 20/06 (SHA256
    28E525D9FE0335B71E4A2FD96586D8E1FC0A2B53BE4547B48D2436332B60661E) + correctif de
    compatibilite : run_compact_window.ps1 (v2) passait -OptimizeMode / -SkipOptimize,
    parametres INCONNUS de cette version -> la tache de compaction echouait au demarrage et
    le mode -DryRun du runbook etait inoperant. Comportement par defaut INCHANGE (Full).
#>

[CmdletBinding()]
param(
    [string]$VhdxPath    = "E:\wsl-data\qdrant.vhdx",
    [string]$Distro      = "Ubuntu",
    [string]$MountPoint  = "/mnt/qdrant-e",
    [string]$Label       = "qdrant-e",
    [string]$ComposePath = "D:\qdrant\myia_qdrant\docker-compose.production.yml",
    [string]$MountScript = "C:\ProgramData\maint-scripts\mount_qdrant_vhdx.ps1",
    [string]$VerifyTask  = "Verify-Qdrant-Mount",
    [string]$Autoheal    = "qdrant_autoheal",
    [string]$Container   = "qdrant_production",
    [ValidateSet("Full","Quick","Retrim")]
    [string]$OptimizeMode = "Full",
    [switch]$SkipOptimize
)

$ErrorActionPreference = "Stop"
$logDir = "C:\ProgramData\maint-scripts\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "compact-qdrant-vhdx-$(Get-Date -f yyyyMMdd-HHmmss).log"

function Log {
    param([string]$msg, [string]$lvl = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "HH:mm:ss"), $lvl, $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# --- Admin check ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p  = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "Privileges Admin requis. Relancer avec Start-Process -Verb RunAs." "ERROR"; exit 2
}

function FreeGB { param([string]$Drive="E") [math]::Round((Get-Volume $Drive).SizeRemaining/1GB,1) }
function VhdxGB { [math]::Round((Get-Item $VhdxPath).Length/1GB,1) }

Log "=== Compact Qdrant VHDX : $VhdxPath ==="
Log "Avant : E: free=$(FreeGB) GB | vhdx on-disk=$(VhdxGB) GB"
$freeBefore = FreeGB
$vhdxBefore = VhdxGB

$doOptimize  = $true   # passe a $false si fstrim NO-GO
$watchdogOff = $false

try {
    # --- 1. Desactiver le watchdog (sinon -Remediate re-monte mid-Optimize) ---
    Log "1/9 Disable watchdog $VerifyTask..."
    Disable-ScheduledTask -TaskName $VerifyTask -ErrorAction Stop | Out-Null
    $watchdogOff = $true
    # S'assurer qu'aucune instance Mount-Qdrant-VHDX n'est en cours
    $running = Get-ScheduledTask -TaskName "Mount-Qdrant-VHDX" -ErrorAction SilentlyContinue
    if ($running -and $running.State -eq "Running") {
        Log "Mount-Qdrant-VHDX en cours d'execution -- attente fin (max 120s)..." "WARN"
        for ($i=0; $i -lt 60 -and (Get-ScheduledTask -TaskName "Mount-Qdrant-VHDX").State -eq "Running"; $i++) { Start-Sleep 2 }
    }

    # --- 2. Stop autoheal ---
    Log "2/9 Stop $Autoheal..."
    & docker.exe stop $Autoheal 2>&1 | ForEach-Object { Log "  $_" }

    # --- 3. Stop qdrant_production (cible, ne touche pas les autres services compose) ---
    Log "3/9 Stop $Container..."
    & docker.exe stop $Container 2>&1 | ForEach-Object { Log "  $_" }

    # --- 4. sync + fstrim (GO/NO-GO) ---
    Log "4/9 sync + fstrim -v $MountPoint (GO/NO-GO discard)..."
    $trimOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "sync; fstrim -v $MountPoint 2>&1" 2>&1
    $trimStr = ($trimOut | Out-String).Trim()
    Log "  fstrim: $trimStr"
    if ($trimStr -match "not supported|operation not permitted|failed") {
        Log "fstrim NON SUPPORTE sur ce montage -> Optimize ne reclamerait rien. On SAUTE l'Optimize." "WARN"
        $doOptimize = $false
        throw "FSTRIM_UNSUPPORTED"   # part en finally -> remount propre, aucun degat
    }

    # --- 5. Clear shims qdrant docker-desktop-bind-mounts (sinon umount EBUSY) ---
    Log "5/9 Clear shims bind-mounts qdrant..."
    $shimScript = @'
grep docker-desktop-bind-mounts /proc/1/mountinfo 2>/dev/null | while read -r line; do
  src=$(echo "$line" | awk "{print \$4}")
  mp=$(echo "$line" | awk "{print \$5}")
  case "$src" in
    *qdrant_data*) umount "$mp" 2>/dev/null && echo "cleared:$mp" || echo "fail:$mp" ;;
  esac
done
echo "shim-clear-done"
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($shimScript))
    $shimOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "echo $b64 | base64 -d | bash" 2>&1
    ($shimOut | Out-String).Trim() -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Log "  shim: $_" }

    # --- 6. umount /mnt/qdrant-e (namespace PID-1) ---
    Log "6/9 umount $MountPoint (PID-1 ns)..."
    $umOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "sync; umount $MountPoint && echo UMOUNT_OK || (umount -l $MountPoint && echo UMOUNT_LAZY)" 2>&1
    $umStr = ($umOut | Out-String).Trim()
    Log "  umount: $umStr"
    if ($umStr -notmatch "UMOUNT_OK|UMOUNT_LAZY") { throw "UMOUNT_FAILED: $umStr" }

    # --- 7. wsl --unmount (detache du WSL VM) ---
    $vhd = Get-VHD -Path $VhdxPath
    $diskNum = $vhd.DiskNumber
    Log "7/9 wsl --unmount \\.\PHYSICALDRIVE$diskNum..."
    $wuOut = & wsl.exe --unmount "\\.\PHYSICALDRIVE$diskNum" 2>&1
    Log "  wsl --unmount (rc=$LASTEXITCODE): $(($wuOut | Out-String).Trim())"
    Start-Sleep 2

    # --- 8. Dismount-VHD (detache de l'hote) ---
    Log "8/9 Dismount-VHD..."
    Dismount-VHD -Path $VhdxPath
    Start-Sleep 2

    # --- 9. Mount RO + Optimize (<mode>) + Dismount ---
    if ($SkipOptimize) {
        Log "9/9 -SkipOptimize : Optimize ANNULE (passe de VALIDATION) ; le montage RO puis le demontage sont malgre tout exercises."
    } else {
        Log "9/9 Mount-VHD -ReadOnly + Optimize-VHD -Mode $OptimizeMode (peut durer 10-40 min)..."
    }
    Mount-VHD -Path $VhdxPath -ReadOnly -NoDriveLetter
    Start-Sleep 2
    if (-not $SkipOptimize) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Optimize-VHD -Path $VhdxPath -Mode $OptimizeMode
        $sw.Stop()
        Log "Optimize-VHD ($OptimizeMode) termine en $([math]::Round($sw.Elapsed.TotalMinutes,1)) min" "OK"
    }
    Dismount-VHD -Path $VhdxPath
    Start-Sleep 2
    Log "vhdx on-disk apres Optimize : $(VhdxGB) GB (etait $vhdxBefore GB)" "OK"
}
catch {
    if ("$($_.Exception.Message)" -eq "FSTRIM_UNSUPPORTED") {
        Log "Abandon Optimize (fstrim non supporte). Remontage sans reclaim." "WARN"
    } else {
        Log "ERREUR : $($_.Exception.Message)" "ERROR"
        Log "Remontage de securite via finally (qdrant va revenir)." "WARN"
    }
}
finally {
    # --- TOUJOURS : remonter + restart qdrant, autoheal, re-enable watchdog ---
    Log "FINALLY : remontage via $MountScript ..."
    try {
        # Si le VHDX est reste attache RO/dismounted, le mount script (idempotent) gere tout.
        & $MountScript
        Log "mount_qdrant_vhdx.ps1 rc=$LASTEXITCODE"
    } catch {
        Log "Remount script a leve : $($_.Exception.Message)" "ERROR"
    }
    try { & docker.exe start $Autoheal 2>&1 | ForEach-Object { Log "  autoheal: $_" } } catch {}
    if ($watchdogOff) {
        try { Enable-ScheduledTask -TaskName $VerifyTask | Out-Null; Log "Watchdog $VerifyTask re-active." "OK" }
        catch { Log "ECHEC re-enable watchdog $VerifyTask -- A REACTIVER MANUELLEMENT : Enable-ScheduledTask -TaskName $VerifyTask" "ERROR" }
    }

    # Verif finale qdrant
    Start-Sleep 3
    $health = (& docker.exe inspect $Container --format '{{.State.Health.Status}}' 2>&1 | Out-String).Trim()
    $freeAfter = FreeGB
    Log "=== BILAN ===" "OK"
    Log "E: free : $freeBefore GB -> $freeAfter GB (delta +$([math]::Round($freeAfter-$freeBefore,1)) GB)" "OK"
    Log "vhdx    : $vhdxBefore GB -> $(VhdxGB) GB" "OK"
    Log "qdrant_production health : $health" "OK"
    Log "Log complet : $logFile" "OK"
}
