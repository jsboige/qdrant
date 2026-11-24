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
      0   = OK. Status OK_DOCKER_PROOF : la sonde wsl.exe etait illisible mais le chemin Docker
            prouve que le conteneur voit >= MinCollections collections => pas de derive
      1   = mountpoint absent                                  (REMEDIATE-ELIGIBLE)
      2   = mounted sur disque sans label qdrant-e (drift)     (REMEDIATE-ELIGIBLE)
      3   = container voit < MinCollections collections        (REMEDIATE-ELIGIBLE)
      4   = container's /qdrant/storage sur device different   (REMEDIATE-ELIGIBLE)
      5   = ETAT INCONNU : wsl.exe n'a pas execute la commande Linux, ou une valeur est
            illisible, ou Docker est injoignable. AUCUNE remediation, a aucun rang de la
            serie ; une ligne ESCALADE quand la serie atteint ProbeErrorEscalateAfter
      9   = conteneur absent ou arrete (preuve Docker)         (REMEDIATE-ELIGIBLE)
      124 = self-timeout : un appel wsl/docker a hang > SelfTimeoutSeconds (force-exit)

    Update 2026-10-31 (fausses derives) : sur 30 j, 14 des 15 "NOT mounted" etaient des
    erreurs du CLI wsl.exe lui-meme (Wsl/Service/0x8007274c timeout, "installation ou
    conversion en cours", warning .wslconfig "Touche inconnue") -- la commande Linux n'avait
    jamais tourne, le montage etait sain. Classees DRIFT_UNMOUNTED, elles declenchaient
    Mount-Qdrant-VHDX (restart production le 24/10 13:05 alors que Phase 5 validait le
    montage) et armaient un cooldown de 15 min qui aurait masque une vraie derive.
    Le marqueur PROBE_RAN distingue "Linux dit non monte" (derive, code 1) de "Linux n'a
    pas repondu" (code 5). Un blocage WSL prolonge reste couvert : apres
    ProbeErrorEscalateAfter echecs consecutifs (~6 min), retour au chemin de remediation.

    Update 2026-11-24 (Maintenance #380 -- fail-closed, le retour au chemin de remediation
    ci-dessus est RETIRE) : la nuit du 24/11, wsl.exe a echoue 60-80 % des sessions
    (fragmentation de la memoire de la VM) sur un montage RESTE SAIN. Apres 3 echecs, ProbeBlind
    "traitait comme derive" : 8 faux veredicts DRIFT, l'erreur wsl.exe prise pour l'etat ou le
    label, 3 lancements de Mount-Qdrant-VHDX (5 autres sauves par le cooldown, par chance).
    Desormais un état INCONNU n'est JAMAIS une derive : code 5, aucune remediation, quel que
    soit le rang de la serie. Une remediation exige une PREUVE POSITIVE, et le chemin Docker
    (qui ne depend pas de wsl.exe : moteur sain toute cette nuit) en fournit une : compteur
    de collections LU. Lu et >= MinCollections => pas de derive (OK_DOCKER_PROOF) ; lu et
    < MinCollections => derive (code 3) ; non entier => "non mesure", jamais 0. Le texte de
    sortie de wsl.exe n'est jamais une valeur d'etat.
    Limite mesuree le 24/11 : NotifyEvent ecrivait avec des ID 1001-1009, hors de la plage
    eventcreate (1-1000) -- aucune notification n'a jamais atteint le journal Windows ; et la
    tache tourne sans elevation ("Acces refuse" tant que la source n'existe pas). L'escalade
    qui compte est donc la ligne ESCALADE du log.

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
    [int]$SelfTimeoutSeconds    = 90,
    [int]$ProbeErrorEscalateAfter = 3,
    # Repertoire des logs/etat. Surcharge par le selftest (commandes factices) pour ne jamais
    # toucher l'etat reel de la tache planifiee.
    [string]$LogDir            = "C:\ProgramData\maint-scripts\logs"
)

$logDir = $LogDir
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

# Echecs consecutifs de la sonde (wsl.exe n'a pas execute la commande Linux), portes par le
# fichier d'etat : tout run dont la sonde repond reecrit l'etat sans ce champ -> remise a zero.
$prevStreak = 0
if (Test-Path $stateFile) {
    try {
        $prev = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($prev.details.probe_error_streak) { $prevStreak = [int]$prev.details.probe_error_streak }
    } catch { }
}

function Get-DockerVerdict {
    # Preuve par le chemin Docker (Maintenance #380) : le moteur Docker ne depend pas de wsl.exe.
    # Rend une table { state ; count ; raw } avec state :
    #   absent        : docker inspect dit "No such object"      (preuve positive : conteneur supprime)
    #   stopped       : inspect reussit, Running=false            (preuve positive)
    #   ok:<n>        : conteneur running, compteur de collections LU, >= MinCollections
    #   low:<n>       : conteneur running, compteur LU, < MinCollections (preuve positive de derive)
    #   unknown       : inspect en erreur autre (moteur injoignable, timeout)  -- ETAT INCONNU
    #   unknown-count : running mais compteur illisible (docker exec en echec) -- ETAT INCONNU, jamais 0
    $insp = & docker.exe inspect $Container --format '{{.State.Running}}' 2>&1
    $inspRc = $LASTEXITCODE
    $inspStr = ($insp | Out-String).Trim()
    if ($inspRc -ne 0) {
        if ($inspStr -match "No such object") { return @{ state = "absent"; count = $null; raw = $inspStr } }
        return @{ state = "unknown"; count = $null; raw = $inspStr }
    }
    if ($inspStr -ne "true") { return @{ state = "stopped"; count = $null; raw = $inspStr } }
    $cnt = & docker.exe exec $Container sh -c "ls //qdrant/storage/collections/ 2>/dev/null | wc -l" 2>&1
    $cntRc = $LASTEXITCODE
    $cntStr = ($cnt | Out-String).Trim()
    $cntClean = $cntStr -replace "[^0-9]", ""
    if ($cntRc -ne 0 -or $cntClean -notmatch "^\d+$") { return @{ state = "unknown-count"; count = $null; raw = $cntStr } }
    $n = [int]$cntClean
    if ($n -lt $MinCollections) { return @{ state = "low:$n"; count = $n; raw = $cntStr } }
    return @{ state = "ok:$n"; count = $n; raw = $cntStr }
}

function ProbeUnknown {
    # ETAT INCONNU (sonde wsl.exe aveugle, valeur illisible, Docker injoignable) : JAMAIS une
    # derive, JAMAIS de remediation -- a aucun rang de la serie. Nuit du 24/11 : 8 faux veredicts
    # DRIFT sur montage sain, 3 lancements de Mount-Qdrant-VHDX (Maintenance #380).
    # Une remediation reste possible sur PREUVE DOCKER seule : compteur LU < MinCollections
    # (code 3) ou conteneur absent/arrete (code 9).
    param([string]$Probe, [string]$What, [string]$Raw)
    $streak = $prevStreak + 1
    $rawOne = (([string]$Raw) -replace "\0", "" -replace "[\r\n]+", " | ")
    if ($rawOne.Length -gt 160) { $rawOne = $rawOne.Substring(0, 160) + "..." }
    $docker = Get-DockerVerdict
    $details = @{ probe = $Probe; unreadable = $What; raw = $rawOne; docker = $docker.state; probe_error_streak = $streak }
    $line = "PROBE_ERROR $Probe ($streak/$ProbeErrorEscalateAfter): $What (docker=$($docker.state) raw=$rawOne)"
    if ($streak -eq $ProbeErrorEscalateAfter) {
        Log "$line -- ESCALADE : sonde wsl.exe illisible $streak fois de suite, l'instrument est en panne (voir Maintenance #380)" "ERROR"
        NotifyEvent -EventId 905 -Type "WARNING" -Message "QdrantWatchdog : sonde wsl.exe illisible $streak fois de suite ($Probe). Aucune remediation decidee. Voir C:\ProgramData\maint-scripts\logs\verify-qdrant-mount.log"
    } else {
        Log "$line -- etat inconnu" "WARN"
    }
    if ($docker.state -like "ok:*") {
        # Preuve positive d'ABSENCE de derive : le conteneur voit les vraies donnees.
        Log "Docker prouve que $Container voit $($docker.count) collections (>= $MinCollections) : PAS de derive, pas de remediation" "WARN"
        WriteState -ExitCode 0 -Status "OK_DOCKER_PROOF" -Data $details
        exit 0
    }
    if ($docker.state -eq "absent" -or $docker.state -eq "stopped") {
        WriteState -ExitCode 9 -Status "CONTAINER_DOWN" -Data $details
        TryRemediate -ExitCode 9 -Status "CONTAINER_DOWN"
        exit 9
    }
    if ($docker.state -like "low:*") {
        Log "DRIFT prouvee par Docker : $Container voit $($docker.count) collections (< $MinCollections) -- store mauvais (conteneur sur un reste rootfs ?)" "ERROR"
        WriteState -ExitCode 3 -Status "DRIFT_LOW_COLLECTIONS" -Data $details
        TryRemediate -ExitCode 3 -Status "DRIFT_LOW_COLLECTIONS"
        exit 3
    }
    WriteState -ExitCode 5 -Status "PROBE_ERROR" -Data $details
    exit 5
}

function Test-ContainerDown {
    # Conteneur absent ou arrete : preuve Docker positive, remediation autorisee (code 9).
    param([string]$Raw)
    Log "WARN: container $Container absent ou non running (docker=$Raw) -- skip check 3+4" "WARN"
    WriteState -ExitCode 9 -Status "CONTAINER_DOWN" -Data @{ device = $ubuntuDev; label = $labelStr; container_state = $Raw }
    NotifyEvent -EventId 909 -Type "WARNING" -Message "Container $Container absent ou non running (docker=$Raw). Mount Ubuntu OK ($ubuntuDev label=$labelStr) mais qdrant indisponible."
    TryRemediate -ExitCode 9 -Status "CONTAINER_DOWN"
    exit 9
}

# --- Check 1: mountpoint inside Ubuntu ---
# --cd / : evite "wsl: Failed to translate" si PowerShell CWD est un path UNC/GDrive
$mountInfo = & wsl.exe --cd / -d $Distro -u root -- bash -c "echo PROBE_RAN; mountpoint -q $MountPoint && findmnt -n -o SOURCE $MountPoint || echo UNMOUNTED" 2>&1
$mountText = $mountInfo | Out-String
if ($mountText -notmatch '(?m)^PROBE_RAN\s*$') { ProbeUnknown -Probe "mount" -What "wsl.exe n'a pas execute la commande Linux" -Raw $mountText.Trim() }
# Filtrer les warnings WSL stderr (e.g. "wsl: Failed to translate ...")
$mountStr = ($mountText -split "`r?`n" | Where-Object { $_ -match "^/dev/sd|^UNMOUNTED" } | Select-Object -First 1)
if (-not $mountStr) { ProbeUnknown -Probe "mount" -What "reponse Linux sans device ni UNMOUNTED" -Raw $mountText.Trim() }
if ($mountStr -eq "UNMOUNTED" -or $mountStr -notmatch "^(/dev/sd[a-z]+)$") {
    # Linux a repondu (PROBE_RAN present) : le mountpoint n'est pas monte, ou pas sur un /dev/sd*.
    $rawState = $mountText.Trim()
    Log "DRIFT: $MountPoint NOT mounted (state=$rawState)" "ERROR"
    WriteState -ExitCode 1 -Status "DRIFT_UNMOUNTED" -Data @{ raw_mount_state = $rawState }
    NotifyEvent -EventId 901 -Type "ERROR" -Message "Qdrant mount $MountPoint absent (split-brain risk imminent). Run mount_qdrant_vhdx.ps1 admin pour recover. Voir C:\ProgramData\maint-scripts\logs\verify-qdrant-mount.log"
    TryRemediate -ExitCode 1 -Status "DRIFT_UNMOUNTED"
    exit 1
}
$ubuntuDev = $matches[1]

# --- Check 2: label is qdrant-e ---
$labelOut = & wsl.exe --cd / -d $Distro -u root -- bash -c "echo PROBE_RAN; blkid -s LABEL -o value $ubuntuDev 2>/dev/null" 2>&1
$labelText = $labelOut | Out-String
if ($labelText -notmatch '(?m)^PROBE_RAN\s*$') { ProbeUnknown -Probe "label" -What "wsl.exe n'a pas execute la commande Linux" -Raw $labelText.Trim() }
$labelStr = ($labelText -split "`r?`n" | Where-Object { $_ -match "^[A-Za-z0-9_-]+$" -and $_ -ne "PROBE_RAN" } | Select-Object -First 1)
if (-not $labelStr) {
    # PROBE_RAN present mais blkid sans reponse : valeur ILLISIBLE, pas un label vide (PR #40).
    ProbeUnknown -Probe "label" -What "label blkid illisible (sortie vide)" -Raw $labelText.Trim()
}
if ($labelStr -ne $ExpectedLabel) {
    Log "DRIFT: $MountPoint monte sur $ubuntuDev mais label='$labelStr' (attendu '$ExpectedLabel') -- split-brain!" "ERROR"
    WriteState -ExitCode 2 -Status "DRIFT_WRONG_LABEL" -Data @{ device = $ubuntuDev; label = $labelStr; expected_label = $ExpectedLabel }
    NotifyEvent -EventId 902 -Type "ERROR" -Message "Qdrant mounte sur disque inattendu : device=$ubuntuDev label='$labelStr' (attendu '$ExpectedLabel'). SPLIT-BRAIN imminent. Voir log."
    TryRemediate -ExitCode 2 -Status "DRIFT_WRONG_LABEL"
    exit 2
}

# --- Check 3 : le conteneur voit-il >= MinCollections collections ? (preuve Docker) ---
# Un echec de docker inspect/exec est un etat INCONNU (code 5), jamais un compteur a -1.
$docker = Get-DockerVerdict
if ($docker.state -eq "absent" -or $docker.state -eq "stopped") { Test-ContainerDown -Raw $docker.raw }
if ($docker.state -eq "unknown" -or $docker.state -eq "unknown-count") { ProbeUnknown -Probe "docker" -What "Docker illisible ($($docker.state))" -Raw $docker.raw }
$collCount = $docker.count
if ($docker.state -like "low:*") {
    Log "DRIFT: container voit $collCount collections (< $MinCollections threshold)" "ERROR"
    WriteState -ExitCode 3 -Status "DRIFT_LOW_COLLECTIONS" -Data @{ device = $ubuntuDev; label = $labelStr; collections_seen = $collCount; min_threshold = $MinCollections }
    NotifyEvent -EventId 903 -Type "ERROR" -Message "Qdrant container voit seulement $collCount collections (< $MinCollections). Cache stale, container down ou mount invalide."
    TryRemediate -ExitCode 3 -Status "DRIFT_LOW_COLLECTIONS"
    exit 3
}

# --- Check 4: container's /qdrant/storage device match Ubuntu's mount device ---
# Eviter awk (probleme escape $ dans PowerShell). Utiliser cut.
$dfOut = & docker.exe exec $Container sh -c "df //qdrant/storage | tail -1 | tr -s ' ' | cut -d' ' -f1" 2>&1
$dfRc = $LASTEXITCODE
$dfStr = ($dfOut | Out-String).Trim()
if ($dfRc -ne 0 -or -not $dfStr) { ProbeUnknown -Probe "device" -What "device de /qdrant/storage illisible dans le conteneur" -Raw $dfStr }
$containerDev = ($dfStr -split "`r?`n" | Where-Object { $_ -match "^/dev/" } | Select-Object -First 1)
if (-not $containerDev) { $containerDev = ($dfStr -split "`r?`n" | Select-Object -First 1) }
if ($containerDev -ne $ubuntuDev) {
    Log "DRIFT: container voit /qdrant/storage sur $containerDev mais Ubuntu mount $MountPoint sur $ubuntuDev -- bind-mount cache stale" "ERROR"
    WriteState -ExitCode 4 -Status "DRIFT_DEVICE_MISMATCH" -Data @{ ubuntu_device = $ubuntuDev; container_device = $containerDev; collections_seen = $collCount }
    NotifyEvent -EventId 904 -Type "ERROR" -Message "Bind-mount cache stale : Ubuntu mount $MountPoint=$ubuntuDev mais container voit $containerDev. Restart Docker Desktop pour refresh."
    TryRemediate -ExitCode 4 -Status "DRIFT_DEVICE_MISMATCH"
    exit 4
}

Log "OK: $MountPoint=$ubuntuDev label=$labelStr container=$Container collections=$collCount"
WriteState -ExitCode 0 -Status "OK" -Data @{ device = $ubuntuDev; label = $labelStr; collections_seen = $collCount; container = $Container }
exit 0
