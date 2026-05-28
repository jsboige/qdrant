<#
.SYNOPSIS
    Monte le VHDX Qdrant dans WSL Ubuntu sur /mnt/qdrant-e + restart qdrant_production (idempotent, requis au boot).
.DESCRIPTION
    Sequence reproductible apres redemarrage Windows :
      1) Mount-VHD E:\wsl-data\qdrant.vhdx (Hyper-V)
      2) wsl --mount \\.\PHYSICALDRIVEN --bare (expose dans WSL)
      3) blkid -L qdrant-e pour identifier /dev/sdX
      4) mount /dev/sdX /mnt/qdrant-e dans Ubuntu
      5) Wait Docker ready + docker compose down/up qdrant_production (refresh bind-mount cache)
      6) Verification finale : 62 collections via API
    Script idempotent : si tout est deja OK, exit 0 sans toucher.
    Necessite Admin (Mount-VHD + wsl --mount).
.CATEGORY
    maintenance
.REQUIRES
    Admin
.MACHINES
    myia-ai-01
.EXAMPLE
    # Manuel (UAC popup) :
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File 'G:\Mon Drive\Maintenance\maintenance\wsl\mount_qdrant_vhdx.ps1'"

    # Au logon via Task Scheduler (avec privileges Admin):
    schtasks /create /tn "Mount-Qdrant-VHDX" /tr "powershell -ExecutionPolicy Bypass -File 'C:\ProgramData\maint-scripts\mount_qdrant_vhdx.ps1'" /sc onlogon /rl HIGHEST /ru "MYIA-AI-01\jsboige"
.NOTES
    Cree le 2026-04-27 apres migration Qdrant -> VHDX.
    Update 2026-05-04 (postmortem 5e hang Docker) :
      - Phase 4 : utilise fstab (mount $MountPoint) au lieu de mount $deviceFound (split WSL session bug)
      - Phase 6 : verifie UNC \\wsl.localhost\Ubuntu\... accessible avant compose up (docker info insuffisant)
    Update 2026-05-24 (post-GPU-crash drift : auto-remediation etait CASSEE, exit 0x8) :
      - Phase 4 : monte dans la namespace de PID 1 (systemd) via `nsenter -t 1 -m -- mount`
                  (Docker resout les binds depuis la ns de PID 1, pas une session wsl fraiche)
                  + `mount --make-shared` (le mount nsenter brut est PRIVATE -> pas de propagation /mnt/wsl).
      - Phase 5 : verifie le DEVICE par label (findmnt SOURCE -> blkid LABEL == qdrant-e), pas juste
                  collection-count>0. Le rootfs leftover avait ~14 dirs de collections et PASSAIT l'ancien
                  check -> bind du mauvais store. Mauvais label => refus anti-split-brain (exit 6/2008).
      - Phase 6 : nettoyage SELECTIF des shims docker-desktop-bind-mounts qdrant stale entre down et up
                  (compose down ne les enleve pas ; ils restent colles au rootfs /dev/sdd). Filtre ROBUSTE :
                  source mountinfo contient "qdrant_data" ET device != device du VHDX -> ne nettoie que les
                  shims qdrant DRIFTES (sur rootfs), GARDE les sains (sur le VHDX), ne touche jamais les ~8
                  shims open-webui/vllm. NB: la source d'un shim qdrant sain est "/qdrant_data/storage"
                  (chemin DANS le fs qdrant-e), pas "/mnt/qdrant-e/qdrant_data/storage" -> un match par prefixe
                  $MountPoint echouerait. C'est le root-cause : le fix "compose recreate" documente etait INCOMPLET sans ca.
    Update 2026-05-28 (post 2 container REMOVED en 8h apres hard crashes Windows) :
      - Phase 6 : probe explicite de la socket /run/guest-services/distro-services/ubuntu.sock
                  AVANT de tenter compose up. Le proxy plan9 UNC repond avant cette socket bind-mount
                  service ; sans elle compose up echoue ("Error response from daemon: accessing specified
                  distro mount service: stat /run/.../ubuntu.sock: no such file or directory") -> container
                  REMOVED, schtask exit 8. Fenetre observee : ~3 min entre plan9 ready et sock ready.
      - Phase 6 : retry compose up avec backoff 15s (3 tentatives) si l'erreur mentionne le bind-mount
                  service / la socket guest-services. Defense en profondeur si la sock apparait juste apres
                  le probe mais que le service est mid-init. Toute autre erreur -> abort immediat (pas de
                  retry idiot sur image-not-found etc.).
    Le mount n'est PAS persistant a travers les reboots Windows : VHDX se detache, /dev/sdX disparait.
    Ce script doit etre rejoue a chaque boot/logon avant que qdrant_production ne fonctionne.
    REQUIS : /etc/fstab dans Ubuntu doit contenir l'entree qdrant-e (cf. CLAUDE.md "Persistent in-Ubuntu mount via /etc/fstab").
    REQUIS : /etc/wsl.conf doit contenir [boot] systemd=true (sinon fstab ignore).
#>

[CmdletBinding()]
param(
    [string]$VhdxPath    = "E:\wsl-data\qdrant.vhdx",
    [string]$Distro      = "Ubuntu",
    [string]$Label       = "qdrant-e",
    [string]$MountPoint  = "/mnt/qdrant-e",
    [string]$ComposePath = "D:\qdrant\myia_qdrant\docker-compose.production.yml",
    [int]$WaitSeconds    = 30,
    [int]$DockerWaitSec  = 180,
    [switch]$SkipDocker
)

$ErrorActionPreference = "Stop"
$logDir = "C:\ProgramData\maint-scripts\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "mount-qdrant-vhdx-$(Get-Date -f yyyyMMdd-HHmmss).log"

function Log {
    param([string]$msg, [string]$lvl = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "HH:mm:ss"), $lvl, $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function NotifyEvent {
    param([int]$EventId, [string]$Type = "ERROR", [string]$Message)
    # eventcreate.exe : pas besoin de registration prealable, ID range 1-1000
    # Visible dans Event Viewer / source "QdrantMount". Type: ERROR, WARNING, INFORMATION
    try {
        & eventcreate.exe /T $Type /SO "QdrantMount" /ID $EventId /L APPLICATION /D $Message 2>&1 | Out-Null
    } catch {
        Log "NotifyEvent failed: $($_.Exception.Message)" "WARN"
    }
}

function FailExit {
    param([int]$Code, [int]$EventId, [string]$Message)
    Log $Message "ERROR"
    NotifyEvent -EventId $EventId -Type "ERROR" -Message ("Mount-Qdrant-VHDX exit=$Code : " + $Message + " — voir " + $logFile)
    exit $Code
}

# --- Check Admin ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "Privileges Admin requis (Mount-VHD + wsl --mount). Relancer avec Start-Process -Verb RunAs." "ERROR"
    exit 2
}

Log "=== Mount Qdrant VHDX -> $MountPoint + Restart qdrant ==="
Log "VHDX: $VhdxPath"
Log "Distro: $Distro / Label: $Label"
Log "Compose: $ComposePath"
Log "Log: $logFile"

# --- Phase 1: Mount-VHD ---
Log "Phase 1: Verification etat Mount-VHD..."
$vhd = Get-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
if (-not $vhd) {
    FailExit -Code 3 -EventId 2003 -Message "VHDX introuvable: $VhdxPath"
}
if (-not $vhd.Attached) {
    Log "VHDX non attache. Mount-VHD..."
    Mount-VHD -Path $VhdxPath -PassThru | Out-Null
    Start-Sleep -Seconds 2
    $vhd = Get-VHD -Path $VhdxPath
} else {
    Log "VHDX deja attache (idempotent)"
}
$diskNum = $vhd.DiskNumber
Log "VHDX attache: DiskNumber=$diskNum"

# --- Phase 2: wsl --mount --bare (idempotent) ---
Log "Phase 2: wsl --mount \\.\PHYSICALDRIVE$diskNum --bare..."
$mountOut = & wsl.exe --mount "\\.\PHYSICALDRIVE$diskNum" --bare 2>&1
$mountRc = $LASTEXITCODE
$mountStr = ($mountOut | Out-String).Trim()
Log "wsl --mount (rc=$mountRc): $mountStr"
if ($mountRc -ne 0 -and $mountStr -notmatch "already|deja|attache|attached") {
    Log "wsl --mount echec (rc=$mountRc)" "WARN"
}

# --- Phase 3: Identifier /dev/sdX dans Ubuntu ---
Log "Phase 3: Identification device dans Ubuntu (label=$Label)..."
$deviceFound = $null
for ($i = 0; $i -lt $WaitSeconds; $i++) {
    $blkidOut = & wsl.exe -d $Distro -u root -- bash -c "blkid -L $Label 2>/dev/null" 2>&1
    $blkidStr = ($blkidOut | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $blkidStr -match "/dev/sd[a-z]+") {
        $deviceFound = $matches[0]
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $deviceFound) {
    FailExit -Code 4 -EventId 2004 -Message "Device label '$Label' non trouve apres ${WaitSeconds}s. wsl --mount --bare a echoue ou disque pas pret."
}
Log "Device: $deviceFound"

# --- Phase 4: mount via fstab DANS LE NAMESPACE DE PID 1 (celui que Docker lit) ---
# Lecon 04/05: mount $deviceFound $MountPoint en session elevee ad-hoc n'est PAS
# visible par la session user-context que Docker Desktop utilise (split WSL session).
# Lecon 24/05 (recovery post-crash GPU): meme `mount $MountPoint` lance via une
# session WSL peut atterrir dans un namespace different de PID 1. Docker Desktop
# resout ses bind-mounts depuis le namespace de PID 1 (systemd). On force donc le
# mount via `nsenter -t 1 -m` (+ `mount --make-shared` pour la propagation cross-distro
# vers /mnt/wsl). fstab fournit toujours device/options.
Log "Phase 4: mount $MountPoint via fstab dans le namespace PID 1 (nsenter)..."
$mountInfo = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mountpoint -q $MountPoint && findmnt -n -o SOURCE $MountPoint || echo UNMOUNTED" 2>&1
$mountInfoStr = (($mountInfo | Out-String) -split "`r?`n" | Where-Object { $_ -match "^/dev/sd|^UNMOUNTED" } | Select-Object -First 1)
if (-not $mountInfoStr) { $mountInfoStr = ($mountInfo | Out-String).Trim() }
$needMount = $true
if ($mountInfoStr -match "^/dev/sd[a-z]+$") {
    # Already mounted in PID-1 ns — verify it's the right disk (label qdrant-e)
    $currentDev = $matches[0]
    $labelOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "blkid -s LABEL -o value $currentDev 2>/dev/null" 2>&1
    $labelStr = (($labelOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^[A-Za-z0-9_-]+$" } | Select-Object -First 1)
    if ($labelStr -eq $Label) {
        Log "$MountPoint deja monte sur $currentDev (label=$Label) dans PID-1 ns (idempotent)"
        $needMount = $false
    } else {
        Log "$MountPoint monte sur $currentDev mais label='$labelStr' (attendu '$Label') -- umount + remount" "WARN"
        & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "umount $MountPoint" 2>&1 | Out-Null
    }
}
if ($needMount) {
    $mountFsOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mkdir -p $MountPoint && mount $MountPoint 2>&1 && mountpoint -q $MountPoint && echo MOUNT_OK" 2>&1
    $mountFsRc = $LASTEXITCODE
    $mountFsStr = ($mountFsOut | Out-String).Trim()
    Log "mount via fstab/nsenter (rc=$mountFsRc): $mountFsStr"
    if ($mountFsRc -ne 0 -or $mountFsStr -notmatch "MOUNT_OK") {
        # Fallback: explicit device mount dans PID-1 ns
        Log "fstab mount echoue, fallback explicit $deviceFound (PID-1 ns)" "WARN"
        $mountFsOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mount $deviceFound $MountPoint && echo MOUNT_OK" 2>&1
        $mountFsRc = $LASTEXITCODE
        $mountFsStr = ($mountFsOut | Out-String).Trim()
        Log "fallback mount (rc=$mountFsRc): $mountFsStr"
        if ($mountFsRc -ne 0 -or $mountFsStr -notmatch "MOUNT_OK") {
            FailExit -Code 5 -EventId 2006 -Message "mount $MountPoint echec total (fstab et fallback, PID-1 ns). Verifier /etc/fstab et que disque label '$Label' est attache."
        }
    }
    Log "$MountPoint monte OK (fstab, PID-1 ns)"
}
# Propagation: un mount nsenter est PRIVE par defaut (pas de flag shared:) -> le
# helper de bind cross-distro de Docker Desktop (/mnt/wsl) ne le verrait pas.
# make-shared est idempotent. Lecon 24/05.
& wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mount --make-shared $MountPoint" 2>&1 | Out-Null
Log "$MountPoint marque shared (propagation cross-distro)"

# --- Phase 5: Verification PAR DEVICE (label), pas seulement compte collections ---
# Lecon 24/05: le rootfs leftover contient ~14 collection dirs stale -> un simple
# count>0 PASSE meme quand le bind est sur le rootfs (faux positif). On exige que
# le device de $MountPoint porte le label '$Label' = preuve que c'est le VHDX.
Log "Phase 5: Verification device + collections..."
$srcOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "findmnt -n -o SOURCE $MountPoint 2>/dev/null" 2>&1
$srcDev = (($srcOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^/dev/sd[a-z]+$" } | Select-Object -First 1)
if (-not $srcDev) {
    FailExit -Code 6 -EventId 2007 -Message "Impossible de lire le device de $MountPoint (PID-1 ns). Raw=$(($srcOut | Out-String).Trim())"
}
$srcLabelOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "blkid -s LABEL -o value $srcDev 2>/dev/null" 2>&1
$srcLabel = (($srcLabelOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^[A-Za-z0-9_-]+$" } | Select-Object -First 1)
if ($srcLabel -ne $Label) {
    FailExit -Code 6 -EventId 2008 -Message "$MountPoint monte sur $srcDev label='$srcLabel' (attendu '$Label'). Mount sur rootfs/disque incorrect -- refus (anti-split-brain)."
}
Log "OK: $MountPoint sur $srcDev label=$srcLabel (VHDX confirme)" "OK"
$collOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "ls $MountPoint/qdrant_data/storage/collections 2>/dev/null | wc -l" 2>&1
$lines = @(($collOut | Out-String) -split "`r?`n" | Where-Object { $_.Trim() -match "^\d+$" })
$collCount = if ($lines.Count -gt 0) { [int]$lines[-1].Trim() } else { 0 }
Log "Collections visibles sur ${MountPoint}: $collCount" "OK"

# --- Phase 6: Wait Docker + Restart qdrant_production ---
if ($SkipDocker) {
    Log "Phase 6 SKIPPED (--SkipDocker)"
    exit 0
}

Log "Phase 6: Wait Docker Desktop ready (timeout=${DockerWaitSec}s)..."
# Docker emet des warnings sur stderr qui sous $ErrorActionPreference=Stop deviennent terminating.
# On switch en Continue pour tout le bloc Phase 6 (le script exit ensuite).
$ErrorActionPreference = "Continue"
# Lecon 01/05: docker info repond OK avant que le user-distro proxy
# (\\wsl.localhost\$Distro\) soit fonctionnel. Verifier les DEUX:
#   1) docker info (engine ready)
#   2) Test-Path UNC vers le mountpoint qdrant (user-distro proxy ready)
# Lecon 28/05 (2 containers REMOVED en 8h apres hard crashes Windows): le proxy plan9 UNC
# revient AVANT la socket Docker bind-mount service (/run/guest-services/distro-services/ubuntu.sock).
# Sans elle, `compose up` echoue:
#   "Error response from daemon: accessing specified distro mount service: stat
#    /run/guest-services/distro-services/ubuntu.sock: no such file or directory"
# -> container reste a l'etat REMOVED, schtask exit 8, watchdog WARN sans remediation.
# FIX: verifier explicitement la presence de la socket avant de proceder a compose down/up.
$dockerReady = $false
$uncProbe = "\\wsl.localhost\$Distro\mnt\qdrant-e\qdrant_data\storage\raft_state.json"
$sockProbe = "\\wsl.localhost\$Distro\run\guest-services\distro-services\ubuntu.sock"
for ($i = 0; $i -lt $DockerWaitSec; $i++) {
    Start-Sleep -Seconds 2
    $null = & docker.exe ps -q 2>&1
    if ($LASTEXITCODE -ne 0) { continue }
    if (-not (Test-Path $uncProbe -ErrorAction SilentlyContinue)) { continue }
    if (-not (Test-Path $sockProbe -ErrorAction SilentlyContinue)) { continue }
    $dockerReady = $true
    break
}
if (-not $dockerReady) {
    FailExit -Code 7 -EventId 2009 -Message "Docker engine + user-distro proxy + bind-mount service non prets apres ${DockerWaitSec}s (UNC probe: $uncProbe ; SOCK probe: $sockProbe). Mount Ubuntu OK mais qdrant ne peut pas demarrer."
}
Log "Docker + user-distro proxy + bind-mount service ready (apres $($i*2)s)"

if (-not (Test-Path $ComposePath)) {
    Log "Compose introuvable: $ComposePath" "WARN"
    exit 0
}

# Idempotence check: si qdrant voit deja >= 50 collections (vraies donnees), skip restart
$health = & docker.exe inspect qdrant_production --format '{{.State.Health.Status}}' 2>&1
$healthStr = ($health | Out-String).Trim()
Log "qdrant_production health: $healthStr"

if ($healthStr -eq "healthy") {
    $collInsideOut = & docker.exe exec qdrant_production sh -c "ls /qdrant/storage/collections 2>/dev/null | wc -l" 2>&1
    $collInsideLines = @(($collInsideOut | Out-String) -split "`r?`n" | Where-Object { $_.Trim() -match "^\d+$" })
    $collInsideStr = if ($collInsideLines.Count -gt 0) { $collInsideLines[-1].Trim() } else { "0" }
    Log "qdrant voit $collInsideStr collections (interne)"
    if ([int]$collInsideStr -ge 50) {
        Log "Idempotent: qdrant deja sur les vraies donnees, skip restart" "OK"
        exit 0
    }
}

# Force restart pour rafraichir bind-mount cache (au cas ou Docker a demarre avant le mount)
Log "Restart qdrant_production (refresh bind-mount cache)..."
$composeDir = Split-Path $ComposePath -Parent
Push-Location $composeDir
try {
    & docker.exe compose -f $ComposePath down 2>&1 | ForEach-Object { Log "  down: $_" }
    Start-Sleep -Seconds 3

    # --- Selective stale-shim clearing (root-cause fix, hardened 2026-05-24) ---
    # `compose down` does NOT remove /mnt/wsl/docker-desktop-bind-mounts/Ubuntu/<hash>.
    # A shim created while $MountPoint was the empty rootfs leftover stays bound to
    # rootfs (/dev/sdd) even after the VHDX is correctly mounted; a fresh `compose up`
    # then resolves the bind THROUGH that stale shim and re-binds the empty store.
    # ROBUST filter (validated 2026-05-24): match shims whose mountinfo source path
    # contains "qdrant_data" AND whose backing device != the VHDX device. This clears
    # ONLY drifted qdrant shims (on rootfs) and KEEPS healthy ones (on the VHDX) -> safe
    # to run idempotently. The ~8 open-webui/vllm shims (source /home/...) are never matched.
    # NB: mountinfo field 4 of a healthy qdrant shim is "/qdrant_data/storage" (path within
    # the qdrant-e fs), NOT "$MountPoint/qdrant_data/storage" -- so a literal $MountPoint
    # prefix match would FAIL; the qdrant_data substring + device check is the correct test.
    # base64 to dodge PowerShell/WSL/awk quoting interplay.
    $shimScript = @'
vhdx_dev=$(findmnt -n -o MAJ:MIN __MOUNTPOINT__ 2>/dev/null | tr -d " ")
if [ -z "$vhdx_dev" ]; then echo "WARN:cannot-read-vhdx-device,skip-shim-clear"; exit 0; fi
grep docker-desktop-bind-mounts /proc/1/mountinfo | while read -r line; do
  shim_dev=$(echo "$line" | awk "{print \$3}")
  src=$(echo "$line" | awk "{print \$4}")
  mp=$(echo "$line" | awk "{print \$5}")
  case "$src" in
    *qdrant_data*)
      if [ "$shim_dev" != "$vhdx_dev" ]; then
        umount "$mp" 2>/dev/null && echo "cleared:$mp(dev $shim_dev!=vhdx $vhdx_dev)" || echo "fail-umount:$mp"
      else
        echo "keep:$mp(dev $shim_dev==vhdx,healthy)"
      fi
      ;;
  esac
done
'@
    $shimScript = $shimScript.Replace('__MOUNTPOINT__', $MountPoint)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($shimScript))
    $shimClear = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "echo $b64 | base64 -d | bash" 2>&1
    $shimLines = @(($shimClear | Out-String).Trim() -split "`r?`n" | Where-Object { $_ })
    if ($shimLines.Count -gt 0) {
        $shimLines | ForEach-Object { Log "  shim: $_" }
    } else {
        Log "  shim: aucun shim qdrant detecte (rien a nettoyer)"
    }
    # Re-make-shared so the post-down mount keeps cross-distro /mnt/wsl propagation.
    $null = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- mount --make-shared $MountPoint 2>&1

    # Defense-in-depth (added 2026-05-28): retry compose up if the bind-mount service
    # is in a transient state. Phase-6 socket probe catches the common case; this catches
    # the narrow window where the sock exists but the service is mid-init.
    $upOk = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $upOutput = & docker.exe compose -f $ComposePath up -d 2>&1
        $upOutput | ForEach-Object { Log "  up[$attempt]: $_" }
        if ($LASTEXITCODE -eq 0) { $upOk = $true; break }
        $upJoined = ($upOutput | Out-String)
        if ($upJoined -match "distro-services/ubuntu\.sock|distro mount service|guest-services") {
            Log "  up[$attempt] FAIL (bind-mount service race) — sleep 15s + retry" "WARN"
            Start-Sleep -Seconds 15
        } else {
            # Different failure — abort retries.
            break
        }
    }
    if (-not $upOk) {
        Log "compose up echoue apres 3 tentatives — container va rester REMOVED" "ERROR"
    }
} finally {
    Pop-Location
}

# Wait healthy
Log "Wait qdrant_production healthy (timeout 120s)..."
$healthy = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    $h = & docker.exe inspect qdrant_production --format '{{.State.Health.Status}}' 2>&1
    if ((($h | Out-String).Trim()) -eq "healthy") { $healthy = $true; break }
}
if ($healthy) {
    Log "qdrant_production healthy" "OK"
    exit 0
} else {
    FailExit -Code 8 -EventId 2010 -Message "qdrant_production pas healthy apres 120s post-restart. Compose down/up done mais container ne demarre pas correctement."
}
