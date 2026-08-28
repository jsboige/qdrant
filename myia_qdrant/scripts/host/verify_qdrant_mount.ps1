<#
.SYNOPSIS
    Watchdog mount Qdrant VHDX : detecte la derive split-brain (rootfs vs VHDX),
    avec auto-remediation optionnelle via -Remediate.
.DESCRIPTION
    Verifie en lecture seule, sans elevation requise:
      1) /mnt/qdrant-e mount inside Ubuntu sur /dev/sd* avec label 'qdrant-e'
      2) Container qdrant_production voit >= MinCollections collections
      3) Container's /qdrant/storage est sur le meme device (/dev/sd*) que celui label qdrant-e
    Si derive detectee -> log + sortie code != 0. Si tout OK -> log INFO + exit 0.

    Avec -Remediate : sur drift (codes 1-4), declenche la tache scheduled
    Mount-Qdrant-VHDX (qui a RunLevel=Highest) via schtasks. Pas d'UAC popup :
    la tache cible est deja configuree avec privileges admin.
    Cooldown 15 min entre tentatives pour eviter les boucles si la remediation echoue.

    Conçu pour scheduled task toutes les 2 min. Le log file est append-only,
    dernieres lignes = etat le plus recent.

    Lecon postmortem 2026-05-04 (5e hang Docker) : le qdrant container peut
    ecrire silencieusement sur le rootfs Ubuntu si le mount /mnt/qdrant-e disparait
    (idle WSL session, Docker Desktop restart, mount fait en session elevee).
    Sans watchdog, la derive n'est detectee qu'apres jours d'ecriture sur rootfs
    -> split-brain irreversible.

    Lecon 2026-05-17 (25h split-brain) : detection sans remediation = drift
    silencieux pendant des jours. Le user doit spot le log manuellement. D'ou
    -Remediate qui ferme la boucle automatiquement.
.CATEGORY
    monitoring
.REQUIRES
    None (read-only checks). -Remediate necessite tache Mount-Qdrant-VHDX existante.
.MACHINES
    myia-ai-01
.EXAMPLE
    .\verify_qdrant_mount.ps1
    Verification ponctuelle, lecture seule (mode detection).
.EXAMPLE
    .\verify_qdrant_mount.ps1 -Remediate
    Verification + declenchement auto de Mount-Qdrant-VHDX si drift detectee.
.EXAMPLE
    schtasks /create /tn "Verify-Qdrant-Mount" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\maint-scripts\verify_qdrant_mount.ps1' -Remediate" /sc minute /mo 2 /ru "MYIA-AI-01\MYIA"
    # IMPORTANT (shell ELEVE, 1 fois) : schtasks /create laisse ExecutionTimeLimit=PT72H par defaut.
    # Baisser a PT90S pour qu'un hang ne bloque pas les triggers suivants (cf. incident 2026-05-24) :
    $t=Get-ScheduledTask "Verify-Qdrant-Mount"; $t.Settings.ExecutionTimeLimit='PT90S'; Set-ScheduledTask -TaskName "Verify-Qdrant-Mount" -Settings $t.Settings
.NOTES
    Sortie codes:
      0   = OK
      1   = mountpoint absent                                  (REMEDIATE-ELIGIBLE)
      2   = mounted sur disque sans label qdrant-e (drift)     (REMEDIATE-ELIGIBLE)
      3   = container voit < MinCollections collections        (REMEDIATE-ELIGIBLE)
      4   = container's /qdrant/storage sur device different   (REMEDIATE-ELIGIBLE)
      9   = container down (pas un probleme de mount)          (no remediation)
      124 = self-timeout : un appel wsl/docker a hang > SelfTimeoutSeconds (force-exit)

    Update 2026-05-24 (post-GPU-crash : le watchdog avait HANG des heures) :
      - Self-timeout interne ($SelfTimeoutSeconds, defaut 90s) : thread .NET qui force-exit
        le process si un appel wsl.exe/docker.exe hang. Sans ca, un hang + ExecutionTimeLimit
        PT72H (defaut schtasks) + MultipleInstances=IgnoreNew = chaine watchdog morte des heures.
      - RECOMMANDE (1 fois, shell ELEVE) : baisser l'ExecutionTimeLimit de la tache a PT90S
        (cf. .EXAMPLE) -- defense en profondeur cote Task Scheduler.
#>

[CmdletBinding()]
param(
    [string]$Distro             = "Ubuntu",
    [string]$MountPoint         = "/mnt/qdrant-e",
    [string]$ExpectedLabel      = "qdrant-e",
    [int]$MinCollections        = 50,
    [string]$Container          = "qdrant_production",
    [switch]$Remediate,
    [string]$RemediationTask    = "Mount-Qdrant-VHDX",
    [int]$CooldownMinutes       = 15,
    [int]$SelfTimeoutSeconds    = 90
)

$logDir = "C:\ProgramData\maint-scripts\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "verify-qdrant-mount.log"
$stateFile = Join-Path $logDir "qdrant-mount-state.json"
$cooldownFile = Join-Path $logDir "remediation-cooldown.json"
$remediationLog = Join-Path $logDir "verify-remediation.log"

# --- Self-imposed hard deadline (hardened 2026-05-24) ---
# The 2026-05-24 post-GPU-crash incident: a wsl.exe/docker.exe call hung; the task's
# ExecutionTimeLimit was the schtasks default PT72H, and MultipleInstances=IgnoreNew, so
# the hung instance blocked EVERY 2-min trigger for hours -> watchdog chain dead.
# PowerShell's event-based timers do NOT fire while the main thread is blocked in a native
# call (single-threaded runspace), so we arm a real OS thread (pure .NET, no runspace) that
# force-exits the whole process tree after $SelfTimeoutSeconds. This kills the hung child too
# and frees the slot for the next trigger -- independent of the task's ExecutionTimeLimit.
# COMPLEMENTARY task-level fix (needs an ELEVATED shell, once):
#   $t=Get-ScheduledTask Verify-Qdrant-Mount; $t.Settings.ExecutionTimeLimit='PT90S'; Set-ScheduledTask -TaskName Verify-Qdrant-Mount -Settings $t.Settings
if ($SelfTimeoutSeconds -gt 0) {
    try {
        Add-Type -TypeDefinition @"
using System; using System.Threading; using System.IO;
public static class QdrantWatchdogSelfTimeout {
    public static void Arm(int ms, string logPath, int exitCode) {
        Thread t = new Thread(() => {
            Thread.Sleep(ms);
            try { File.AppendAllText(logPath, "["+DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")+"] [ERROR] SELF-TIMEOUT "+(ms/1000)+"s exceeded, force-exit "+exitCode+" (hung wsl/docker call)\n"); } catch {}
            Environment.Exit(exitCode);
        });
        t.IsBackground = true; t.Start();
    }
}
"@ -ErrorAction Stop
        [QdrantWatchdogSelfTimeout]::Arm($SelfTimeoutSeconds * 1000, $logFile, 124)
    } catch {
        # Non-fatal: if Add-Type fails (rare), proceed without the self-timeout guard.
        Add-Content -Path $logFile -Value ("[{0}] [WARN] self-timeout arm failed: {1}" -f (Get-Date -f "yyyy-MM-dd HH:mm:ss"), $_.Exception.Message) -Encoding UTF8
    }
}

function Log {
    param([string]$msg, [string]$lvl = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "yyyy-MM-dd HH:mm:ss"), $lvl, $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function TryRemediate {
    param([int]$ExitCode, [string]$Status)
    if (-not $Remediate) {
        Log "Remediate=OFF, skip auto-repair (exit=$ExitCode)"
        return
    }
    # Codes 1-4 = drift mount. Code 9 = container down (REMOVED) AVEC mount OK.
    # Update 2026-05-28 : code 9 ajoute (2 container REMOVED en 8h apres hard crashes Windows,
    # Mount-Qdrant-VHDX a fail au compose up sur "ubuntu.sock not found" -> container reste a
    # l'etat REMOVED -> watchdog WARN sans agir jusqu'a intervention humaine).
    # Mount-Qdrant-VHDX est idempotent : Phase 1-5 skip si mount OK, Phase 6 = compose up (re-cree
    # le container manquant). Le compose-up retry (defense-in-depth) couvre la fenetre etroite
    # ou la socket bind-mount est mid-init.
    if ($ExitCode -lt 1 -or ($ExitCode -gt 4 -and $ExitCode -ne 9)) {
        Log "Exit=$ExitCode hors range remediate (1-4, 9), skip"
        return
    }
    # Cooldown : ne pas redeclencher Mount-Qdrant-VHDX dans les N minutes
    $now = Get-Date
    if (Test-Path $cooldownFile) {
        try {
            $cd = Get-Content $cooldownFile -Raw | ConvertFrom-Json
            $last = [DateTime]::Parse($cd.last_attempt)
            $elapsed = ($now - $last).TotalMinutes
            if ($elapsed -lt $CooldownMinutes) {
                $remaining = [Math]::Round($CooldownMinutes - $elapsed, 1)
                Log "Cooldown actif ($remaining min restants). Remediation skip pour eviter boucle." "WARN"
                Add-Content -Path $remediationLog -Value ("[{0}] SKIP cooldown {1} min remaining (exit={2} status={3})" -f $now.ToString("yyyy-MM-dd HH:mm:ss"), $remaining, $ExitCode, $Status) -Encoding UTF8
                return
            }
        } catch {
            Log "Cooldown file corrompu, ignore: $($_.Exception.Message)" "WARN"
        }
    }
    # Write cooldown record BEFORE invoking task (defense against loop si task hangs)
    try {
        @{ last_attempt = $now.ToString("o"); exit_code = $ExitCode; status = $Status } | ConvertTo-Json | Set-Content -Path $cooldownFile -Encoding UTF8
    } catch {
        Log "WriteCooldown failed: $($_.Exception.Message)" "WARN"
    }
    Log "REMEDIATE: declenche tache scheduled $RemediationTask (exit=$ExitCode status=$Status)" "WARN"
    Add-Content -Path $remediationLog -Value ("[{0}] TRIGGER {1} (exit={2} status={3})" -f $now.ToString("yyyy-MM-dd HH:mm:ss"), $RemediationTask, $ExitCode, $Status) -Encoding UTF8
    try {
        $rc = & schtasks.exe /run /tn $RemediationTask 2>&1
        $rcCode = $LASTEXITCODE
        Log "schtasks /run /tn $RemediationTask -> rc=$rcCode : $(($rc | Out-String).Trim())"
        Add-Content -Path $remediationLog -Value ("[{0}] SCHTASKS rc={1} : {2}" -f (Get-Date -f "yyyy-MM-dd HH:mm:ss"), $rcCode, (($rc | Out-String).Trim())) -Encoding UTF8
    } catch {
        Log "schtasks invocation failed: $($_.Exception.Message)" "ERROR"
        Add-Content -Path $remediationLog -Value ("[{0}] FAILED : {1}" -f (Get-Date -f "yyyy-MM-dd HH:mm:ss"), $_.Exception.Message) -Encoding UTF8
    }
}

function WriteState {
    param([int]$ExitCode, [string]$Status, [hashtable]$Data = @{})
    $state = @{
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
        exit_code = $ExitCode
        status = $Status
        details = $Data
    }
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8
    } catch {
        Log "WriteState failed: $($_.Exception.Message)" "WARN"
    }
}

function NotifyEvent {
    param([int]$EventId, [string]$Type = "ERROR", [string]$Message)
    # eventcreate.exe : pas besoin de registration prealable, ID range 1-1000
    # Type valides: ERROR, WARNING, INFORMATION
    try {
        & eventcreate.exe /T $Type /SO "QdrantWatchdog" /ID $EventId /L APPLICATION /D $Message 2>&1 | Out-Null
    } catch {
        Log "NotifyEvent failed: $($_.Exception.Message)" "WARN"
    }
}

# --- Check 1: mountpoint inside Ubuntu ---
# --cd / : evite "wsl: Failed to translate" si PowerShell CWD est un path UNC/GDrive
$mountInfo = & wsl.exe --cd / -d $Distro -u root -- bash -c "mountpoint -q $MountPoint && findmnt -n -o SOURCE $MountPoint || echo UNMOUNTED" 2>&1
# Filtrer les warnings WSL stderr (e.g. "wsl: Failed to translate ...")
$mountStr = (($mountInfo | Out-String) -split "`r?`n" | Where-Object { $_ -match "^/dev/sd|^UNMOUNTED" } | Select-Object -First 1)
if (-not $mountStr -or $mountStr -notmatch "^(/dev/sd[a-z]+)$") {
    $rawState = ($mountInfo | Out-String).Trim()
    Log "DRIFT: $MountPoint NOT mounted (state=$rawState)" "ERROR"
    WriteState -ExitCode 1 -Status "DRIFT_UNMOUNTED" -Data @{ raw_mount_state = $rawState }
    NotifyEvent -EventId 1001 -Type "ERROR" -Message "Qdrant mount $MountPoint absent (split-brain risk imminent). Run mount_qdrant_vhdx.ps1 admin pour recover. Voir C:\ProgramData\maint-scripts\logs\verify-qdrant-mount.log"
    TryRemediate -ExitCode 1 -Status "DRIFT_UNMOUNTED"
    exit 1
}
$ubuntuDev = $matches[1]

# --- Check 2: label is qdrant-e ---
$labelOut = & wsl.exe --cd / -d $Distro -u root -- bash -c "blkid -s LABEL -o value $ubuntuDev 2>/dev/null" 2>&1
$labelStr = (($labelOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^[A-Za-z0-9_-]+$" } | Select-Object -First 1)
if (-not $labelStr) { $labelStr = ($labelOut | Out-String).Trim() }
if ($labelStr -ne $ExpectedLabel) {
    Log "DRIFT: $MountPoint mounte sur $ubuntuDev mais label='$labelStr' (attendu '$ExpectedLabel') -- split-brain!" "ERROR"
    WriteState -ExitCode 2 -Status "DRIFT_WRONG_LABEL" -Data @{ device = $ubuntuDev; label = $labelStr; expected_label = $ExpectedLabel }
    NotifyEvent -EventId 1002 -Type "ERROR" -Message "Qdrant mounte sur disque inattendu : device=$ubuntuDev label='$labelStr' (attendu '$ExpectedLabel'). SPLIT-BRAIN imminent. Voir log."
    TryRemediate -ExitCode 2 -Status "DRIFT_WRONG_LABEL"
    exit 2
}

# --- Check 3: container sees >= MinCollections ---
$running = & docker.exe inspect $Container --format '{{.State.Running}}' 2>&1
if ($LASTEXITCODE -ne 0 -or ($running | Out-String).Trim() -ne "true") {
    $rawRunning = ($running | Out-String).Trim()
    Log "WARN: container $Container non running (state=$rawRunning) -- skip check 3+4" "WARN"
    WriteState -ExitCode 9 -Status "CONTAINER_DOWN" -Data @{ device = $ubuntuDev; label = $labelStr; container_state = $rawRunning }
    NotifyEvent -EventId 1009 -Type "WARNING" -Message "Container $Container non running (state=$rawRunning). Mount Ubuntu OK ($ubuntuDev label=$labelStr) mais qdrant indisponible."
    TryRemediate -ExitCode 9 -Status "CONTAINER_DOWN"
    exit 9
}

$collsOut = & docker.exe exec $Container sh -c "ls //qdrant/storage/collections/ 2>/dev/null | wc -l" 2>&1
$collsClean = ($collsOut | Out-String).Trim() -replace "[^0-9]", ""
$collCount = if ($collsClean -match "^\d+$") { [int]$collsClean } else { -1 }
if ($collCount -lt $MinCollections) {
    Log "DRIFT: container voit $collCount collections (< $MinCollections threshold)" "ERROR"
    WriteState -ExitCode 3 -Status "DRIFT_LOW_COLLECTIONS" -Data @{ device = $ubuntuDev; collections_seen = $collCount; min_threshold = $MinCollections }
    NotifyEvent -EventId 1003 -Type "ERROR" -Message "Qdrant container voit seulement $collCount collections (< $MinCollections). Cache stale, container down ou mount invalide."
    TryRemediate -ExitCode 3 -Status "DRIFT_LOW_COLLECTIONS"
    exit 3
}

# --- Check 4: container's /qdrant/storage device match Ubuntu's mount device ---
# Eviter awk (probleme escape $ dans PowerShell). Utiliser cut.
$dfOut = & docker.exe exec $Container sh -c "df //qdrant/storage | tail -1 | tr -s ' ' | cut -d' ' -f1" 2>&1
$containerDev = (($dfOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^/dev/sd|^/dev/" } | Select-Object -First 1)
if (-not $containerDev) { $containerDev = ($dfOut | Out-String).Trim() }
if ($containerDev -ne $ubuntuDev) {
    Log "DRIFT: container voit /qdrant/storage sur $containerDev mais Ubuntu mount $MountPoint sur $ubuntuDev -- bind-mount cache stale" "ERROR"
    WriteState -ExitCode 4 -Status "DRIFT_DEVICE_MISMATCH" -Data @{ ubuntu_device = $ubuntuDev; container_device = $containerDev; collections_seen = $collCount }
    NotifyEvent -EventId 1004 -Type "ERROR" -Message "Bind-mount cache stale : Ubuntu mount $MountPoint=$ubuntuDev mais container voit $containerDev. Restart Docker Desktop pour refresh."
    TryRemediate -ExitCode 4 -Status "DRIFT_DEVICE_MISMATCH"
    exit 4
}

Log "OK: $MountPoint=$ubuntuDev label=$labelStr container=$Container collections=$collCount"
WriteState -ExitCode 0 -Status "OK" -Data @{ device = $ubuntuDev; label = $labelStr; collections_seen = $collCount; container = $Container }
exit 0
