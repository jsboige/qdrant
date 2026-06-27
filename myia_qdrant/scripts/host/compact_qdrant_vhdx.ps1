<#
.SYNOPSIS
    Compaction OFFLINE de E:\wsl-data\qdrant.vhdx (recupere le slack alloue-mais-libere ; ~735 GiB observes 2026-06-06).
.DESCRIPTION
    Fenetre de maintenance one-shot. Le VHDX dynamique a gonfle a ~877 GB sur disque alors que l'ext4
    n'utilise que ~104 GB (sequelle des 53M points avant le dedup -94.6%). fstrim a deja desalloue les blocs
    dans la BAT ; seul Optimize-VHD (offline, hors-ligne) reduit physiquement le fichier.

    Sequence :
      1) Desactive + stoppe les schtasks watchdog (Verify-Qdrant-Mount + Mount-Qdrant-VHDX)
         -> sinon le watchdog (toutes les 2 min, -Remediate) remonte le VHDX en plein Optimize.
      2) docker compose down (qdrant_production + qdrant_autoheal)
      3) fstrim final /mnt/qdrant-e (PID-1 ns) -- recupere le delta ecrit depuis le fstrim live
      4) purge des shims docker qdrant_data + umount /mnt/qdrant-e ; wsl --unmount ; Dismount-VHD  (libere le fichier)
      5) Mount-VHD -ReadOnly -NoDriveLetter ; Optimize-VHD -Mode <mode> ; Dismount-VHD (finally interne)
      6) re-attache via le script canonique mount_qdrant_vhdx.ps1 (Mount-VHD + wsl --mount + mount + compose up + verify)
      7) FINALLY : re-active les watchdog schtasks (TOUJOURS) ; validation 72 collections + healthz + point-count

    SECURITE :
      - Optimize-VHD ne supprime QUE des blocs deja libres/desalloues ; les donnees allouees ne sont jamais touchees.
      - Le watchdog est re-active dans un finally -> meme si le script plante, qdrant auto-recupere en <=2 min.
      - Le detachement read-only de la phase 5 est garanti par un finally interne (pas de fuite read-only).
      - Backup de reference : snapshot quotidien Qdrant-Snapshot-Daily (GDrive). Optimize ne modifie pas les donnees.

    Self-elevation : si non-admin, relance via Start-Process -Verb RunAs (popup UAC). Log -> C:\ProgramData\maint-scripts\logs\.
.REQUIRES
    Admin (Mount-VHD / Optimize-VHD / wsl --mount / *-ScheduledTask)
.MACHINES
    myia-ai-01
.EXAMPLE
    # Lancement manuel (popup UAC) :
    powershell -ExecutionPolicy Bypass -File D:\qdrant\myia_qdrant\scripts\host\compact_qdrant_vhdx.ps1
.NOTES
    Cree le 2026-06-06. One-shot (pas schedule). Reutilise mount_qdrant_vhdx.ps1 pour le re-attach.
#>
[CmdletBinding()]
param(
    [string]$VhdxPath     = "E:\wsl-data\qdrant.vhdx",
    [string]$Distro       = "Ubuntu",
    [string]$Label        = "qdrant-e",
    [string]$MountPoint   = "/mnt/qdrant-e",
    [string]$ComposePath  = "D:\qdrant\myia_qdrant\docker-compose.production.yml",
    [string]$MountScript  = "D:\qdrant\myia_qdrant\scripts\host\mount_qdrant_vhdx.ps1",
    [string]$EnvFile      = "D:\qdrant\myia_qdrant\.env.production",
    [ValidateSet("Full","Quick","Retrim")]
    [string]$OptimizeMode = "Full",
    [int]$MinCollections  = 50,
    [switch]$SkipOptimize   # tout sauf l'Optimize lui-meme (test du demontage/remontage)
)

# ---------------------------------------------------------------------------
# Self-elevation (UAC)
# ---------------------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ELEVATION] Privileges Admin requis -- relance avec UAC..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"",
                 '-OptimizeMode', $OptimizeMode)
    if ($SkipOptimize) { $argList += '-SkipOptimize' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

$ErrorActionPreference = "Stop"
$logDir = "C:\ProgramData\maint-scripts\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("compact-qdrant-vhdx-{0}.log" -f (Get-Date -f yyyyMMdd-HHmmss))

function Log {
    param([string]$msg, [string]$lvl = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "HH:mm:ss"), $lvl, $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# Invoke a native exe (docker/wsl/powershell) capturing stdout+stderr WITHOUT throwing.
# CRITICAL: docker compose writes progress ("Container ... Stopping") to STDERR ; under
# $ErrorActionPreference='Stop' a `& exe 2>&1` turns the first stderr line into a TERMINATING
# error (NativeCommandError). We must gate on the real exit code, not on stderr presence.
function Invoke-Native {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [string]$Tag = "")
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $File @Arguments 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    if ($Tag) { foreach ($l in @($out)) { $s = "$l".Trim(); if ($s) { Log "  ${Tag}: $s" } } }
    return [pscustomobject]@{ Code = $code; Output = ($out | Out-String) }
}

# Run an arbitrary bash script as root in the PID-1 mount namespace (base64 to dodge quoting).
function Invoke-WslRoot {
    param([string]$Bash)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Bash))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $o = (& wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "echo $b64 | base64 -d | bash" 2>&1 | Out-String)
    } finally { $ErrorActionPreference = $prev }
    return $o.Trim()
}

# Qdrant API helpers (key read from env, NEVER logged).
function Get-QdrantKey {
    $m = Select-String -Path $EnvFile -Pattern '^QDRANT__SERVICE__API_KEY=(.+)$' -ErrorAction SilentlyContinue
    if ($m) { return $m.Matches.Groups[1].Value } else { return $null }
}
function Get-CollectionsCount {
    param([string]$Key)
    try {
        $r = Invoke-RestMethod -Uri 'http://localhost:6333/collections' -Headers @{ 'api-key' = $Key } -TimeoutSec 15
        return $r.result.collections.Count
    } catch { return -1 }
}
function Get-RooTasksPoints {
    param([string]$Key)
    try {
        $r = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers @{ 'api-key' = $Key } -TimeoutSec 15
        return [pscustomobject]@{ status = $r.result.status; points = $r.result.points_count }
    } catch { return $null }
}

$swatch = [System.Diagnostics.Stopwatch]::StartNew()
Log "=== Compaction qdrant.vhdx ==="
Log "VHDX: $VhdxPath | Mode: $OptimizeMode | SkipOptimize: $SkipOptimize"
Log "Log: $logFile"

# Baseline (avant)
$apiKey = Get-QdrantKey
$baseColl = Get-CollectionsCount -Key $apiKey
$basePts  = Get-RooTasksPoints -Key $apiKey
Log ("Baseline: collections={0} ; roo_tasks={1} pts ({2})" -f $baseColl, ($basePts.points), ($basePts.status))

$vhdBefore = Get-VHD -Path $VhdxPath
Log ("VHD type={0} attached={1} FileSize={2:N1} GB Size(max)={3:N0} GB MinimumSize={4:N1} GB" -f `
    $vhdBefore.VhdType, $vhdBefore.Attached, ($vhdBefore.FileSize/1GB), ($vhdBefore.Size/1GB), ($vhdBefore.MinimumSize/1GB))
if ($vhdBefore.VhdType -ne 'Dynamic') {
    Log "VHDX n'est PAS dynamique (type=$($vhdBefore.VhdType)) -> Optimize ne recuperera rien. ABORT." "ERROR"
    exit 20
}
$eFreeBefore = (Get-PSDrive E).Free / 1GB
Log ("E: free avant = {0:N1} GB" -f $eFreeBefore)

# ---------------------------------------------------------------------------
# Phase 1 : neutraliser le watchdog
# ---------------------------------------------------------------------------
$watchTasks = @('Verify-Qdrant-Mount','Mount-Qdrant-VHDX')
Log "Phase 1: desactivation watchdog ($($watchTasks -join ', '))..."
foreach ($t in $watchTasks) {
    try { Disable-ScheduledTask -TaskName $t -ErrorAction Stop | Out-Null; Log "  $t disabled" } catch { Log "  $t disable: $($_.Exception.Message)" "WARN" }
    try { Stop-ScheduledTask    -TaskName $t -ErrorAction SilentlyContinue | Out-Null } catch {}
}
Start-Sleep -Seconds 3
# verifie qu'aucune instance ne tourne encore
foreach ($t in $watchTasks) {
    $info = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if ($info -and $info.State -eq 'Running') { Log "  $t encore Running apres stop -- attente 5s" "WARN"; Start-Sleep 5 }
}

$compacted = $false
try {
    # -----------------------------------------------------------------------
    # Phase 2 : compose down
    # -----------------------------------------------------------------------
    Log "Phase 2: docker compose down (qdrant_production + qdrant_autoheal)..."
    # docker compose ecrit sa progression sur STDERR -> Invoke-Native (gate sur exit code, pas sur stderr).
    Push-Location (Split-Path $ComposePath -Parent)
    try {
        $down = Invoke-Native 'docker.exe' @('compose','-f',$ComposePath,'down') 'down'
    } finally { Pop-Location }
    if ($down.Code -ne 0) { throw "compose down exit=$($down.Code)" }
    $still = (Invoke-Native 'docker.exe' @('ps','-a','--filter','name=qdrant_production','--format','{{.Names}}')).Output.Trim()
    if ($still -match 'qdrant_production') { throw "qdrant_production toujours present apres compose down" }
    Log "compose down OK (containers retires)" "OK"

    # -----------------------------------------------------------------------
    # GATE 1 : attendre que l'utilisateur QUITTE Docker Desktop.
    # Regle user 2026-06-06 : toujours quitter Docker AVANT toute op WSL/VHD
    # (wsl --unmount / Dismount-VHD). Le detache + Optimize tournent Docker DOWN.
    # -----------------------------------------------------------------------
    Log "=============================================================" "WARN"
    Log ">>> QUITTE DOCKER DESKTOP MAINTENANT (tray -> Quit Docker Desktop)." "WARN"
    Log ">>> J'attends qu'il soit completement arrete avant de detacher le VHDX..." "WARN"
    Log "=============================================================" "WARN"
    $downDeadline = (Get-Date).AddMinutes(15)
    $dockerDown = $false
    while ((Get-Date) -lt $downDeadline) {
        Start-Sleep -Seconds 3
        $null = & docker.exe ps -q 2>$null
        $cliDown = ($LASTEXITCODE -ne 0)
        $proc = Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue
        if ($cliDown -and -not $proc) { $dockerDown = $true; break }
    }
    if (-not $dockerDown) { throw "Docker toujours actif apres 15 min -- abort avant detache (regle Docker-down non respectee)." }
    Log "Docker Desktop arrete confirme -> fenetre offline ouverte." "OK"

    # -----------------------------------------------------------------------
    # Phase 3 : fstrim final
    # -----------------------------------------------------------------------
    Log "Phase 3: fstrim final /mnt/qdrant-e..."
    $trim = Invoke-WslRoot "fstrim -v $MountPoint 2>&1 || echo 'fstrim-failed'"
    Log "  $trim"

    # -----------------------------------------------------------------------
    # Phase 4 : liberer le VHDX (purge shims -> umount -> wsl --unmount -> Dismount-VHD)
    # -----------------------------------------------------------------------
    Log "Phase 4: liberation du VHDX..."
    $diskNum = (Get-VHD -Path $VhdxPath).DiskNumber
    Log "  DiskNumber=$diskNum (\\.\PHYSICALDRIVE$diskNum)"

    # 4a. purge des shims docker qdrant_data (ils tiennent /mnt/qdrant-e occupe), puis umount
    $releaseBash = @"
set +e
grep docker-desktop-bind-mounts /proc/1/mountinfo 2>/dev/null | while read -r line; do
  src=`$(echo "`$line" | awk '{print `$4}')
  mp=`$(echo "`$line" | awk '{print `$5}')
  case "`$src" in
    *qdrant_data*) umount "`$mp" 2>/dev/null && echo "shim-cleared:`$mp" ;;
  esac
done
umount $MountPoint 2>/dev/null && echo "umount-ok" || (umount -l $MountPoint 2>/dev/null && echo "umount-lazy-ok" || echo "umount-FAILED")
mountpoint -q $MountPoint && echo "STILL-MOUNTED" || echo "UNMOUNTED-CONFIRMED"
"@
    $rel = Invoke-WslRoot $releaseBash
    $rel -split "`n" | ForEach-Object { if ($_.Trim()) { Log "  $($_.Trim())" } }
    if ($rel -notmatch 'UNMOUNTED-CONFIRMED') { throw "Echec umount $MountPoint (PID-1 ns) : $rel" }

    # 4b. detache de WSL2 puis de l'hote
    Log "  wsl --unmount \\.\PHYSICALDRIVE$diskNum..."
    $u = Invoke-Native 'wsl.exe' @('--unmount', "\\.\PHYSICALDRIVE$diskNum")
    Log "  wsl --unmount: $($u.Output.Trim()) (rc=$($u.Code))"
    if ($u.Code -ne 0) {
        Log "  unmount cible echoue -> fallback 'wsl --unmount' (tous disques)" "WARN"
        $u2 = Invoke-Native 'wsl.exe' @('--unmount'); Log "  wsl --unmount(all): $($u2.Output.Trim())"
    }
    Start-Sleep -Seconds 2
    $vNow = Get-VHD -Path $VhdxPath
    if ($vNow.Attached) {
        Log "  Dismount-VHD (detache de l'hote)..."
        Dismount-VHD -Path $VhdxPath
        Start-Sleep -Seconds 2
    }
    $vNow = Get-VHD -Path $VhdxPath
    if ($vNow.Attached) { throw "VHDX toujours attache apres Dismount-VHD (fichier en cours d'utilisation)" }
    Log "VHDX libere (detache hote + WSL)" "OK"

    # -----------------------------------------------------------------------
    # Phase 5 : Optimize-VHD (mount read-only -> optimize -> dismount garanti)
    # -----------------------------------------------------------------------
    if ($SkipOptimize) {
        Log "Phase 5 SKIPPED (-SkipOptimize)" "WARN"
    } else {
        Log "Phase 5: Mount-VHD -ReadOnly + Optimize-VHD -Mode $OptimizeMode (LONG -- peut prendre 30 min a plusieurs heures)..."
        Mount-VHD -Path $VhdxPath -ReadOnly -NoDriveLetter
        try {
            $optSw = [System.Diagnostics.Stopwatch]::StartNew()
            Optimize-VHD -Path $VhdxPath -Mode $OptimizeMode
            $optSw.Stop()
            Log ("Optimize-VHD termine en {0:N1} min" -f ($optSw.Elapsed.TotalMinutes)) "OK"
        } finally {
            Log "  Dismount-VHD (detache le mount read-only -- garanti)..."
            Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        $vhdAfter = Get-VHD -Path $VhdxPath
        $savedGB = ($vhdBefore.FileSize - $vhdAfter.FileSize) / 1GB
        Log ("VHD FileSize: {0:N1} GB -> {1:N1} GB (recupere {2:N1} GB)" -f `
            ($vhdBefore.FileSize/1GB), ($vhdAfter.FileSize/1GB), $savedGB) "OK"
        $compacted = $true
    }

    # -----------------------------------------------------------------------
    # GATE 2 : attendre que l'utilisateur RELANCE Docker Desktop avant le re-attach
    # (le re-attach via mount_qdrant_vhdx.ps1 fait un `compose up` -> Docker requis).
    # -----------------------------------------------------------------------
    Log "=============================================================" "WARN"
    Log ">>> RELANCE DOCKER DESKTOP MAINTENANT (tray / menu Demarrer)." "WARN"
    Log ">>> J'attends que l'engine + le service bind-mount soient prets avant de re-attacher..." "WARN"
    Log "=============================================================" "WARN"
    $sockNew = "/mnt/wsl/docker-desktop/shared-sockets/guest-services/distro-services/ubuntu.sock"
    $sockOld = "/run/guest-services/distro-services/ubuntu.sock"
    $upDeadline = (Get-Date).AddMinutes(15)
    $dockerUp = $false
    while ((Get-Date) -lt $upDeadline) {
        Start-Sleep -Seconds 3
        $null = & docker.exe ps -q 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        & wsl.exe -d $Distro -- bash -c "test -S '$sockNew' || test -S '$sockOld'" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $dockerUp = $true; break
    }
    if (-not $dockerUp) { throw "Docker pas pret apres 15 min -- re-attach impossible ici. Watchdog re-active (Phase 7) convergera des que Docker revient." }
    Log "Docker engine + service bind-mount prets -> re-attach." "OK"

    # -----------------------------------------------------------------------
    # Phase 6 : re-attach via le script canonique (idempotent depuis etat detache)
    # -----------------------------------------------------------------------
    Log "Phase 6: re-attach via $MountScript..."
    if (-not (Test-Path $MountScript)) { throw "Script de mount introuvable: $MountScript" }
    # Child process ISOLE (Invoke-Native) : un `exit N` du script de mount ne doit PAS tuer ce script-ci
    # (le call-operator `&` partage le process -> son `exit` sauterait le finally Phase 7 / re-enable watchdog).
    $mr = Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$MountScript) 'mount'
    Log "mount_qdrant_vhdx.ps1 exit=$($mr.Code)"
    if ($mr.Code -ne 0) { throw "Re-attach (mount_qdrant_vhdx.ps1) a echoue (exit=$($mr.Code))" }
}
catch {
    Log "ECHEC: $($_.Exception.Message)" "ERROR"
    # NE PAS Dismount-VHD ici a l'aveugle : detacher le disque pendant que Docker tient encore des
    # bind-mounts dessus wedge la WSL-integration (ubuntu.sock perdu -> compose up impossible 180s).
    # La phase 5 garantit deja un detach propre (finally interne). Ici on se contente de RE-MONTER
    # (idempotent depuis attache OU detache) ; le watchdog re-active en Phase 7 converge sinon.
    Log "Tentative de recuperation : re-mount canonique (sans dismount aveugle)..." "WARN"
    try { $rm = Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$MountScript) 'recover-mount'; Log "Recuperation mount exit=$($rm.Code)" } catch { Log "Recuperation mount a echoue: $($_.Exception.Message)" "ERROR" }
}
finally {
    # -----------------------------------------------------------------------
    # Phase 7 : re-activer le watchdog -- TOUJOURS (filet de securite ultime)
    # -----------------------------------------------------------------------
    Log "Phase 7 (finally): re-activation watchdog..."
    foreach ($t in $watchTasks) {
        try { Enable-ScheduledTask -TaskName $t -ErrorAction Stop | Out-Null; Log "  $t enabled" } catch { Log "  $t enable: $($_.Exception.Message)" "WARN" }
    }
}

# ---------------------------------------------------------------------------
# Validation finale
# ---------------------------------------------------------------------------
Log "Validation finale (attente qdrant healthy)..."
$healthy = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    $h = (Invoke-Native 'docker.exe' @('inspect','qdrant_production','--format','{{.State.Health.Status}}')).Output.Trim()
    if ($h -eq 'healthy') { $healthy = $true; break }
}
$finColl = Get-CollectionsCount -Key $apiKey
$finPts  = Get-RooTasksPoints -Key $apiKey
$eFreeAfter = (Get-PSDrive E).Free / 1GB
$swatch.Stop()

Log "================ BILAN ================"
Log ("Duree totale       : {0:N1} min" -f $swatch.Elapsed.TotalMinutes)
Log ("qdrant healthy     : $healthy")
Log ("Collections        : {0} -> {1} (baseline {0})" -f $baseColl, $finColl)
Log ("roo_tasks points   : {0} -> {1}" -f ($basePts.points), ($finPts.points))
Log ("roo_tasks status   : {0}" -f ($finPts.status))
Log ("E: free            : {0:N1} GB -> {1:N1} GB (+{2:N1} GB)" -f $eFreeBefore, $eFreeAfter, ($eFreeAfter - $eFreeBefore))
Log "======================================"

if ($healthy -and $finColl -ge $MinCollections -and $finPts.status -eq 'green') {
    Log "SUCCES : qdrant healthy, $finColl collections, roo_tasks green." "OK"
    exit 0
} else {
    Log "ATTENTION : etat post-operation non nominal (healthy=$healthy coll=$finColl status=$($finPts.status)). Le watchdog est re-active et tentera de converger. Verifier les logs." "ERROR"
    exit 13
}
