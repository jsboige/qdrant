<#
.SYNOPSIS
    Qdrant snapshot backup (offsite GDrive + local copy) WITH anti-split-brain poison-guard.

.DESCRIPTION
    Canonical backup for the precious collection (roo_tasks_semantic_index).
    Consolidated into the fork 2026-05-21 — supersedes D:\roo-extensions\scripts\qdrant\backup-snapshot.ps1
    (which only lived in the wrong repo and had NO poison-guard).

    Pipeline:
      1. POISON-GUARD: GET /collections/<c>; abort (exit 2) if points_count < -MinPoints.
         => never snapshots a wiped/empty collection, never lets retention rotate out good backups.
      2. Create snapshot via REST (idempotent per day).
      3. Download once to temp (-TempDir, else %TEMP%; TEMP-GUARD refuses the download when the
         temp volume lacks snapshot size + -TempMarginGB), then distribute:
         offsite = DIRECT Drive API upload (gdrive_user_upload.ps1, NO G: transit — the DriveFS
         copy failed silently twice: 2026-09-03 and 2026-11-17, local copy complete but never
         delivered server-side; legacy DriveFS copy remains as fallback only),
         plus local copy to -LocalCopyDir unless skipped.
      4. SIZE-GUARD: if the new snapshot is < 50% of the largest existing one, SKIP retention and warn.
      5. Delete server-side snapshot.
      6. Retention: DailyKeep most recent + WeeklyKeep weekly Mondays (per destination).
         Defaults = 1 + 0 (user ruling 2026-11-17, keep=1 + Q29 doctrine). Historical: 3+0
         (2026-10-07, Q4 "A+B"), 7 daily + 4 weekly Mondays (original).
         OFFSITE DELETE = PERMANENT via Drive API AS THE USER (gdrive_user_delete.ps1 +
         .gdrive_oauth.json; files.delete has no trash). The service account stays READ-ONLY
         (gdrive_sa_verify.ps1 gates retention server-side): an SA can neither delete user
         files (canDelete=false, 403 — measured 2026-11-01) nor own uploads (zero storage
         quota on a consumer My Drive, 403 Storage Quota Exceeded — measured 2026-11-17).
         Without the OAuth token: legacy DriveFS trash + WARN (empty Drive trash manually).

.PARAMETER MinPoints
    Poison-guard floor. Default 100000 (roo_tasks_semantic_index ~380k as of 2026-05-21).

.PARAMETER LocalCopyDir
    Local backup directory on a different physical disk. Default 'D:\qdrant-backups'. Pass '' to skip.

.PARAMETER SharedPath
    GDrive offsite root. Default $env:ROOSYNC_SHARED_PATH. Pass '-' to skip the offsite leg.

.NOTES
    API key read from myia_qdrant/.env.production (QDRANT__SERVICE__API_KEY). Never printed.
    Sister restore: qdrant_snapshot_restore.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$QdrantUrl   = $(if ($env:QDRANT_URL) { $env:QDRANT_URL } else { 'http://localhost:6333' }),
    [string]$ApiKey      = '',
    [string]$Collection  = 'roo_tasks_semantic_index',
    [string]$MachineId   = '',
    [string]$SharedPath  = '',
    [string]$LocalCopyDir = 'D:\qdrant-backups',
    # Transit temp (download ~210 Go/nuit) : param > $env:TEMP.
    # H:\qdrant-tmp n'est PLUS prefere automatiquement (2026-11-20) : le Seagate USB est
    # DEFAILLANT (51 blocs defectueux, 2 197 resets USB, journal NTFS en echec — Maintenance#354)
    # et a tue l'upload du 20/11 a 14 % sur une erreur CRC de lecture. Il peut se re-enumerer par
    # intermittence : un Test-Path 'H:\' vrai a 02:41 renverrait le transit sur un disque mourant.
    # D: = transit des autres lanes (consigne Maintenance 20/11) ; E: porte la VHDX.
    [string]$TempDir = '',
    # TEMP-GUARD : marge exigee au-dela de la taille du snapshot sur le volume temp.
    [int]$TempMarginGB = 30,
    [int]$MinPoints      = 100000,
    # Client timeout on the snapshot CREATION call. 1800 s was the old margin ("builds in ~8 min
    # at ~2M pts / 26 GB", 2026-08-20). Measured 2026-11-26: the 01:17Z run gave up at 1800 s
    # while the server kept building and finished at 10 961 s (3 h 02) for a 248 GB snapshot —
    # the collection is ~16.5M pts and the build is dominated by cold-page paging. 14 400 s (4 h)
    # leaves ~57 min of margin over that measurement.
    [int]$CreateTimeoutSec = 14400,
    # Retention: user ruling 2026-11-17 (GO via Maintenance) = keep 1 offsite copy, with Q29
    # doctrine: the predecessor is deleted ONLY after the new copy is verified server-side.
    # At 03:17 today's copy is still uploading (DriveFS lags hours) -> offsite deletion is
    # DEFERRED to the evening pass (-RetentionOnly, run by the 19:45 sweep). Historical: 3
    # (2026-10-07, Q4 "A+B"), 7 daily + 4 weekly Mondays (original).
    [int]$DailyKeep      = 1,
    [int]$WeeklyKeep     = 0,
    # Evening pass: skip snapshot creation, run retention only (verify today's copy
    # server-side, then permanently delete the predecessors). Exits 0 with a marker if
    # today's backup is absent anywhere (fail-safe: nothing deleted).
    [switch]$RetentionOnly,
    [string]$LogDir      = ''
)

$ErrorActionPreference = 'Stop'
# 2026-11-07: Invoke-WebRequest progress rendering throttles large downloads 10-50x in an
# INTERACTIVE console (measured 0.68 MB/s vs ~55 MB/s hidden; disk/CPU exonerated by dd/docker
# stats). The schtask VBS launcher is hidden so it never paid this cost; manual console runs did.
$ProgressPreference = 'SilentlyContinue'

# ========== RESOLVE INPUTS ==========

if ([string]::IsNullOrWhiteSpace($MachineId)) {
    $MachineId = if ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLowerInvariant() } else { (hostname).ToLowerInvariant() }
}

# API key: param > env > fork .env.production (QDRANT__SERVICE__API_KEY). Never echoed.
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = $env:QDRANT__SERVICE__API_KEY
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { $ApiKey = $env:QDRANT_API_KEY }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        $envFile = Join-Path $PSScriptRoot '..\.env.production'
        if (Test-Path $envFile) {
            $line = (Get-Content $envFile | Where-Object { $_ -match '^QDRANT__SERVICE__API_KEY=' } | Select-Object -First 1)
            if ($line) { $ApiKey = ($line -replace '^QDRANT__SERVICE__API_KEY=', '').Trim().Trim('"').Trim("'") }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    [Console]::Error.WriteLine('ERROR: API key not found (param / $env:QDRANT__SERVICE__API_KEY / .env.production).')
    exit 1
}

$headers   = @{ 'Content-Type' = 'application/json'; 'api-key' = $ApiKey }
$dlHeaders = @{ 'api-key' = $ApiKey }

if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $PSScriptRoot '..\backups\snapshot-logs' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$dateStamp = Get-Date -Format 'yyyyMMdd'
$today     = Get-Date -Format 'yyyy-MM-dd'
$logFile   = Join-Path $LogDir "snapshot-backup-$dateStamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Information $line -InformationAction Continue
}

# Destinations: list of @{ Name; Root } where Root/<date>/ holds the .snapshot files.
$destinations = @()
if ([string]::IsNullOrWhiteSpace($SharedPath)) { $SharedPath = $env:ROOSYNC_SHARED_PATH }
if ($SharedPath -eq '-') {
    Write-Log 'Offsite leg skipped (-SharedPath -)' 'WARN'
} elseif ([string]::IsNullOrWhiteSpace($SharedPath)) {
    Write-Log 'Offsite leg skipped: $env:ROOSYNC_SHARED_PATH not set and -SharedPath not provided' 'WARN'
} elseif (-not (Test-Path $SharedPath)) {
    Write-Log "Offsite leg skipped: SharedPath does not exist: $SharedPath" 'WARN'
} else {
    $destinations += @{ Name = 'offsite'; Root = "$SharedPath/qdrant-snapshots/$MachineId/$Collection" }
}
if (-not [string]::IsNullOrWhiteSpace($LocalCopyDir)) {
    $destinations += @{ Name = 'local'; Root = "$LocalCopyDir/$MachineId/$Collection" }
}
if ($destinations.Count -eq 0) {
    [Console]::Error.WriteLine('ERROR: no backup destination (offsite skipped and LocalCopyDir empty).')
    exit 1
}

Write-Log "Backup start: machine=$MachineId collection=$Collection qdrant=$QdrantUrl dests=$([string]::Join(',', ($destinations | ForEach-Object { $_.Name })))"

# ========== POISON-GUARD ==========

try {
    $info = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection" -Headers $headers -Method Get -TimeoutSec 60
} catch {
    Write-Log "FATAL: cannot read collection (qdrant down or gate-refused?): $($_.Exception.Message)" 'ERROR'
    [Console]::Error.WriteLine("Cannot read collection $Collection : $($_.Exception.Message)")
    exit 1
}
$pts = [int]$info.result.points_count
$status = $info.result.status
Write-Log "Collection state: points=$pts status=$status"
if ($pts -lt $MinPoints) {
    Write-Log "POISON-GUARD TRIPPED: points=$pts < MinPoints=$MinPoints. Aborting (no snapshot, no retention)." 'ERROR'
    [Console]::Error.WriteLine("POISON-GUARD: $Collection has only $pts points (< $MinPoints). Refusing to back up a possibly-wiped collection.")
    exit 2
}

# ========== ORPHAN CLEANUP ==========
# The server-side delete below only runs at the END of a successful run, so every failed/
# interrupted run leaves its snapshot behind (2026-08-22: 9 orphans / ~151 GB accumulated
# since May). Purge server-side snapshots older than 48h up-front; the margin avoids racing
# a concurrent live run. Offsite history is unaffected (retention runs on its own tree).

try {
    $orphList = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots" -Headers $headers -Method Get -TimeoutSec 60
    $orphCutoff = (Get-Date).AddHours(-48)
    $orphDeleted = 0
    foreach ($s in @($orphList.result)) {
        try { $ct = [datetime]::Parse($s.creation_time, [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
        if ($ct -lt $orphCutoff) {
            try {
                $null = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots/$($s.name)" -Headers $headers -Method Delete -TimeoutSec 300
                $orphDeleted++
                Write-Log "Orphan cleanup: deleted server-side snapshot $($s.name) ($([math]::Round($s.size/1GB,2)) GB, created $($s.creation_time))"
            } catch { Write-Log "WARN: orphan delete failed $($s.name): $($_.Exception.Message)" 'WARN' }
        }
    }
    # Always log the summary: a silent success is indistinguishable from "block never ran".
    Write-Log "Orphan cleanup: $orphDeleted deleted of $(@($orphList.result).Count) server-side snapshot(s) (cutoff 48h)"
} catch { Write-Log "WARN: orphan cleanup list failed (non-fatal): $($_.Exception.Message)" 'WARN' }

# ========== IDEMPOTENCY (per-destination) ==========
# Skip server snapshot only if EVERY destination already has today's. If some have it and some
# don't, copy the existing file to the missing ones (no need to re-snapshot the server).

$missing = @()
$existingTodayPath = $null
foreach ($d in $destinations) {
    $dayDir = "$($d.Root)/$today"
    $ex = @()
    if (Test-Path $dayDir) { $ex = @(Get-ChildItem -Path $dayDir -Filter '*.snapshot' -File -ErrorAction SilentlyContinue) }
    if ($ex.Count -gt 0) {
        if (-not $existingTodayPath) { $existingTodayPath = $ex[0].FullName }
        Write-Log "$($d.Name) already has today's snapshot ($($ex[0].Name))"
    } else {
        $missing += $d
    }
}

$newSnapshotSize = 0L
$sourceFile = $null
$tmp = $null

if ($RetentionOnly -and $missing.Count -gt 0) {
    Write-Log "EVENING-PASS SKIPPED: today's snapshot absent from: $(($missing | ForEach-Object { $_.Name }) -join ', ') — nothing deleted (fail-safe)."
    Write-Log 'Backup done'
    exit 0
}

if ($missing.Count -eq 0) {
    Write-Log "Idempotent: all destinations have today's snapshot."
} elseif ($existingTodayPath) {
    # Reuse the already-created snapshot; just fan it out to the missing destinations.
    $sourceFile = $existingTodayPath
    $newSnapshotSize = (Get-Item $sourceFile).Length
    Write-Log "Reusing existing snapshot for $($missing.Count) missing dest(s): $sourceFile ($newSnapshotSize bytes)"
} else {
    # No destination has today's. Before POSTing a NEW ~220 GB snapshot, check whether an
    # interrupted earlier run already left a COMPLETED one server-side (2026-11-23: the 02:17
    # run died on the 1800s HttpClient timeout while the server kept building — a naive rerun
    # stacks a second ~220 GB artifact inside the VHDX, the 19/11 failure class). Qdrant only
    # lists FINALIZED snapshots, so anything found here is restorable as-is.
    $reuse = $null
    try {
        $srvList = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots" -Headers $headers -Method Get -TimeoutSec 60
        # creation_time is a UTC timestamp whose yyyy-MM-dd prefix equals the date embedded
        # in the snapshot NAME; nightly runs (03:17 local = 02:17 UTC) share the date in both
        # zones. String prefix = no timezone-parsing drift between PS 5.1 and 7.
        # 2026-11-26: creation_time came back NULL on v1.20.2 for the snapshot the engine really
        # built (measured on the 01:17Z artifact), so this filter never matched and a rerun would
        # have stacked a SECOND ~248 GB snapshot. Fall back to the UTC date embedded in the name.
        $todayUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        $reuse = @($srvList.result) | Where-Object {
            $ct = if ($_.creation_time) { "$($_.creation_time)" } else { '' }
            $nd = if ("$($_.name)" -match '-(\d{4}-\d\d-\d\d)-\d\d-\d\d-\d\d-') { $Matches[1] } else { '' }
            ($ct -ne '' -and $ct.StartsWith($today)) -or ($nd -ne '' -and ($nd -eq $today -or $nd -eq $todayUtc))
        } | Sort-Object -Property name -Descending | Select-Object -First 1
    } catch { Write-Log "WARN: reuse-check list failed (non-fatal, creating fresh): $($_.Exception.Message)" 'WARN' }

    $snapName = $null
    $snapSize = 0L
    $createdThisRun = $false
    if ($reuse) {
        $snapName = $reuse.name
        $snapSize = [int64]$reuse.size
        Write-Log "REUSE: today's server-side snapshot already exists (leftover from an interrupted run): name=$snapName serverSize=$snapSize — creation SKIPPED"
    } elseif ($PSCmdlet.ShouldProcess("$QdrantUrl/collections/$Collection/snapshots", 'POST create snapshot')) {
        try {
            # -CreateTimeoutSec (default 14 400 s): measured 10 961 s on 2026-11-26 for 248 GB
            # at ~16.5M pts; the old 1800 s was tuned when the snapshot built in ~8 min.
            $createResp = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots" -Headers $headers -Method Post -TimeoutSec $CreateTimeoutSec
        } catch { Write-Log "FATAL: snapshot creation failed: $($_.Exception.Message)" 'ERROR'; exit 1 }
        $snapName = $createResp.result.name
        if ([string]::IsNullOrWhiteSpace($snapName)) { Write-Log 'FATAL: snapshot response missing name' 'ERROR'; exit 1 }
        $snapSize = [int64]$createResp.result.size
        $createdThisRun = $true
        Write-Log "Snapshot created: name=$snapName serverSize=$snapSize"
    } else {
        Write-Log 'WhatIf: would create + download snapshot, then distribute to all destinations'
    }

    if ($snapName) {
        if ([string]::IsNullOrWhiteSpace($TempDir)) { $TempDir = $env:TEMP }
        if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
        # TEMP-GUARD (2026-11-20): a ~210 GB download must never fill the temp volume (C: by
        # default = the whole machine). Refuse cleanly and exit 1 — nothing rotated.
        # On refusal: a snapshot CREATED this run is dropped server-side (nobody else wants it,
        # else it lingers 48h inside the VHDX until orphan cleanup); a REUSED one is KEPT — it
        # is the only completed artifact of an interrupted run, retryable with a larger -TempDir.
        $tempRoot = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $TempDir).ProviderPath)
        $tempFree = [int64](New-Object System.IO.DriveInfo($tempRoot)).AvailableFreeSpace
        $tempNeed = $snapSize + ([int64]$TempMarginGB * 1GB)
        Write-Log "Temp dir: $TempDir (free=$([math]::Round($tempFree/1GB,1)) GiB, need=$([math]::Round($tempNeed/1GB,1)) GiB incl. margin $TempMarginGB GiB)"
        if ($snapSize -gt 0 -and $tempFree -lt $tempNeed) {
            Write-Log "FATAL: TEMP-GUARD: $TempDir has $tempFree bytes free < snapshot $snapSize + margin $TempMarginGB GiB — download REFUSED (pass -TempDir on a larger volume)" 'ERROR'
            if ($createdThisRun) {
                try {
                    $null = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots/$snapName" -Headers $headers -Method Delete -TimeoutSec 120
                    Write-Log "Server-side snapshot cleaned after TEMP-GUARD refusal: $snapName"
                } catch { Write-Log "WARN: server-side cleanup after TEMP-GUARD failed (orphan cleanup will catch it at 48h): $($_.Exception.Message)" 'WARN' }
            } else {
                Write-Log "TEMP-GUARD: reused server-side snapshot KEPT for retry ($snapName; orphan cleanup holds it 48h)" 'WARN'
            }
            exit 1
        }
        $tmp = Join-Path $TempDir $snapName
        try {
            Invoke-WebRequest -Uri "$QdrantUrl/collections/$Collection/snapshots/$snapName" -Headers $dlHeaders -OutFile $tmp -TimeoutSec 3600
        } catch { Write-Log "FATAL: download failed: $($_.Exception.Message)" 'ERROR'; exit 1 }
        $sourceFile = $tmp
        $newSnapshotSize = (Get-Item $tmp).Length
        Write-Log "Downloaded to temp: size=$newSnapshotSize bytes"
        # Server-side cleanup (non-fatal) — safe for BOTH paths: the download succeeded, so the
        # data now exists locally and is being fanned out below.
        try {
            $null = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots/$snapName" -Headers $headers -Method Delete -TimeoutSec 120
            Write-Log "Server-side snapshot cleaned: $snapName"
        } catch { Write-Log "WARN: server-side cleanup failed (non-fatal): $($_.Exception.Message)" 'WARN' }
    }
}

# Fan out the source file (existing or freshly downloaded) to every missing destination.
# The copy is the step that actually moves the data, and it was the one fatal step with no catch.
# On 2026-08-15 it threw between the copy and its success log: $ErrorActionPreference='Stop' killed
# the script, and the hidden launcher (wscript //B) discarded stderr. The only surviving trace was
# the scheduler's exit code 1 -- an empty day directory offsite, a 26 GB temp file left behind
# because the cleanup below never ran, and no way to know what the error had been.
$copyFailed = $false
try {
    if ($sourceFile) {
        # Post-reboot GoogleDriveFS race: on 2026-08-28 the 03:17 run hit
        # DirectoryNotFoundException on G:\ (Drive not remounted yet ~45 min after a 02:30
        # reboot) and died keeping the temp as the only copy. Bounded wait for each
        # destination root before attempting the copy.
        foreach ($d in $missing) {
            $waited = 0
            while (-not (Test-Path $d.Root) -and $waited -lt 600) {
                Start-Sleep -Seconds 30
                $waited += 30
                Write-Log "Waiting for $($d.Name) destination root (not yet mounted, ${waited}s): $($d.Root)" 'WARN'
            }
            if (-not (Test-Path $d.Root)) {
                Write-Log "Destination root STILL absent after ${waited}s wait: $($d.Root) — copy will likely fail" 'ERROR'
            }
        }
        $snapLeaf = Split-Path $sourceFile -Leaf
        foreach ($d in $missing) {
            $dayDir = "$($d.Root)/$today"

            # ---- OFFSITE = UPLOAD DIRECT Drive API (2026-11-18, direction user 17/11) ----
            # Le transit DriveFS (copie vers G:) a echoue SILENCIEUSEMENT le 17/11 : copie
            # locale complete, JAMAIS livree cote serveur, cache purge (classe 2026-09-03) ;
            # le sauvetage API est mort a 89 % sur une LECTURE G: ("ressources systeme
            # insuffisantes"). L'offsite ne transite plus par G: : gdrive_user_upload.ps1 en
            # processus pwsh enfant (HttpClient + ByteArrayContent = octets exacts ; enfant
            # car ses exit quitteraient le parent). Idempotent par taille (ALREADY_THERE),
            # reprise 308/Range intra-session, verification finale server-side. Repli legacy
            # DriveFS si token/pwsh absents OU echec apres retries : au pire le statu quo.
            $directDone = $false
            if ($d.Name -eq 'offsite') {
                $uploader = Join-Path $PSScriptRoot 'utilities\gdrive_user_upload.ps1'
                $oauthTok = Join-Path $PSScriptRoot '..\.gdrive_oauth.json'
                $pwshExe  = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                if (-not $pwshExe -and (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe")) { $pwshExe = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
                if ((Test-Path $uploader) -and (Test-Path $oauthTok) -and $pwshExe) {
                    if ($PSCmdlet.ShouldProcess("Drive API $dayDir/$snapLeaf", 'direct upload snapshot (offsite, no G: transit)')) {
                        $maxUpload = 2
                        for ($attempt = 1; $attempt -le $maxUpload; $attempt++) {
                            # Chaque tentative repart de l'offset 0 (l'URI de session resumable
                            # n'est pas persistee entre processus) : ~188 Go a ~9 MiB/s ~ 6 h,
                            # 2 tentatives bornees puis repli DriveFS.
                            Write-Log "offsite direct upload attempt $attempt/$maxUpload : $sourceFile -> Drive API ($($d.Root)/$today)"
                            $out = & $pwshExe -NoProfile -File $uploader -Upload $sourceFile -Day $today -Machine $MachineId -Collection $Collection 2>&1
                            $rcUp = $LASTEXITCODE
                            $lastProg = ''
                            foreach ($l in @($out)) { $t = "$l"; if ($t -match '^PROGRESS:') { $lastProg = $t } elseif ($t) { Write-Log "upload: $t" } }
                            if ($rcUp -eq 0) { Write-Log "OFFSITE UPLOAD DONE (direct Drive API, no G: transit): $snapLeaf"; $directDone = $true; break }
                            if ($lastProg) { Write-Log "upload died after: $lastProg" 'WARN' }
                            Write-Log "offsite direct upload rc=$rcUp (attempt $attempt/$maxUpload)" 'WARN'
                            if ($attempt -lt $maxUpload) { Start-Sleep -Seconds 60 }
                        }
                        if (-not $directDone) { Write-Log "offsite direct upload FAILED after $maxUpload attempt(s) — legacy DriveFS copy follows (status quo)" 'WARN' }
                    } else { Write-Log 'WhatIf: would direct-upload snapshot to offsite via Drive API' }
                } else {
                    Write-Log 'offsite direct upload unavailable (uploader/token/pwsh absent) — legacy DriveFS copy' 'WARN'
                }
            }
            if ($directDone) { continue }

            if ($PSCmdlet.ShouldProcess("$dayDir/$snapLeaf", "copy snapshot to $($d.Name)")) {
                # Bounded retry: the root pre-wait above only covers "root absent at start".
                # On 2026-09-03 G: was MOUNTED but DriveFS degraded deeper (small reads OK,
                # big write threw DirectoryNotFoundException) -- a state a pre-check cannot
                # see. Retry the copy itself; DriveFS settled within minutes on both observed
                # classes (2026-08-28 mount race, 2026-09-03 degraded mount).
                $maxAttempts = 3
                $copied = $false
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    try {
                        if (-not (Test-Path $dayDir)) { New-Item -ItemType Directory -Path $dayDir -Force | Out-Null }
                        Copy-Item -Path $sourceFile -Destination "$dayDir/$snapLeaf" -Force
                        $copied = $true
                        break
                    } catch {
                        Write-Log "copy to $($d.Name) attempt $attempt/$maxAttempts failed: $($_.Exception.GetType().Name): $($_.Exception.Message)" 'ERROR'
                        if ($attempt -lt $maxAttempts) {
                            # A partial destination locked by DriveFS would fail the next
                            # overwrite too -- clear it (best effort) before waiting.
                            Remove-Item -LiteralPath "$dayDir/$snapLeaf" -Force -ErrorAction SilentlyContinue
                            Write-Log "retrying copy to $($d.Name) in 300s (DriveFS may settle)..." 'WARN'
                            Start-Sleep -Seconds 300
                        }
                    }
                }
                if (-not $copied) {
                    $copyFailed = $true
                    Write-Log "FATAL: copy to $($d.Name) failed after $maxAttempts attempts ($dayDir/$snapLeaf)" 'ERROR'
                    throw
                }
                Write-Log "Copied to $($d.Name): $dayDir/$snapLeaf"
            }
        }
    }
} finally {
    # Keep the temp when the copy failed: the server-side snapshot is already deleted by then, so
    # this file is the only remaining copy of today's backup. Deleting it to reclaim disk would
    # destroy the very thing the run exists to produce. Say where it is instead.
    if ($tmp -and (Test-Path $tmp)) {
        if ($copyFailed) {
            Write-Log "Temp KEPT (copy failed; this is the only remaining copy of today's snapshot): $tmp" 'WARN'
        } else {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# ========== RETENTION (per destination), with SIZE-GUARD ==========

foreach ($d in $destinations) {
    $root = $d.Root
    if (-not (Test-Path $root)) { Write-Log "No root yet for $($d.Name) ($root); retention skipped"; continue }

    # SIZE-GUARD: if the new snapshot is anomalously small vs the biggest existing, skip retention.
    if ($newSnapshotSize -gt 0) {
        $maxExisting = (Get-ChildItem -Path $root -Recurse -Filter '*.snapshot' -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Maximum).Maximum
        if ($maxExisting -and $newSnapshotSize -lt ($maxExisting * 0.5)) {
            Write-Log "SIZE-GUARD ($($d.Name)): new=$newSnapshotSize < 50% of max=$maxExisting. Skipping retention (keeping all)." 'ERROR'
            continue
        }
    }

    $dayDirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }
    $keep = New-Object System.Collections.Generic.HashSet[string]
    foreach ($x in ($dayDirs | Sort-Object Name -Descending | Select-Object -First $DailyKeep)) { [void]$keep.Add($x.Name) }
    if ($WeeklyKeep -gt 0) {
        $mondays = $dayDirs | Where-Object {
            try { ([DateTime]::ParseExact($_.Name, 'yyyy-MM-dd', $null)).DayOfWeek -eq [DayOfWeek]::Monday } catch { $false }
        } | Sort-Object Name -Descending | Select-Object -First $WeeklyKeep
        foreach ($m in $mondays) { [void]$keep.Add($m.Name) }
    }

    # SA GATE (offsite only, 2026-11-01): before rotating cloud copies out, confirm SERVER-SIDE
    # (Drive API as the service account) that the newest kept snapshot actually made it to the
    # cloud. The G: copy completes locally at once; DriveFS uploads in the background (hours for
    # ~60 GB). A silent upload failure (degraded-mount class, 2026-09-03) must not let retention
    # delete the older cloud copies — the only confirmed-good offsite ones. Fail-safe direction:
    # on ABSENT/divergent/unverifiable, skip offsite retention this run (extra copies kept).
    if ($d.Name -eq 'offsite') {
        $saVerify = Join-Path $PSScriptRoot 'utilities\gdrive_sa_verify.ps1'
        $saKey = Join-Path $PSScriptRoot '..\.gdrive_sa.json'
        if ((Test-Path $saVerify) -and (Test-Path $saKey)) {
            # Target: evening pass (-RetentionOnly) verifies TODAY's copy (uploaded during the
            # day, ~16h by 19:45) — that is the Q29 "verify the new before deleting the old"
            # for keep=1. Nightly pass targets the newest kept dir STRICTLY OLDER than today:
            # today's local copy is not uploaded yet at 03:17 (DriveFS lags hours).
            if ($RetentionOnly) {
                $newestKept = $keep | Sort-Object -Descending | Select-Object -First 1
            } else {
                $newestKept = $keep | Where-Object { $_ -lt $today } | Sort-Object -Descending | Select-Object -First 1
            }
            $newestFile = if ($newestKept) { Get-ChildItem -Path "$root/$newestKept" -Filter '*.snapshot' -File -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
            if (-not $newestKept) {
                # keep=1 nightly: nothing verifiable yet (today still uploading) but older
                # copies exist -> DEFER the whole offsite deletion to the evening pass (Q29).
                $pendingDel = @($dayDirs | Where-Object { -not $keep.Contains($_.Name) })
                if ($pendingDel.Count -gt 0) {
                    Write-Log "SA gate: keep=$DailyKeep, today's copy not verifiable yet, $($pendingDel.Count) predecessor(s) pending — offsite retention DEFERRED to the evening pass (-RetentionOnly, Q29)" 'WARN'
                    continue
                }
                Write-Log "SA gate: no kept dir older than today yet — retention proceeds (nothing prior to confirm)"
            } elseif (-not $newestFile) {
                Write-Log "SA GATE: kept dir $newestKept has no snapshot file (unexpected) — retention SKIPPED this run (fail-safe)" 'WARN'
                continue
            } else {
                try {
                    $out = & powershell.exe -NoProfile -File $saVerify -SnapshotName $newestFile.Name -ExpectedSizeBytes $newestFile.Length 2>&1
                    $rc = $LASTEXITCODE
                    foreach ($l in @($out)) { if ($l) { Write-Log "SA gate: $l" } }
                    if ($rc -ne 0) {
                        Write-Log "SA GATE ($($d.Name)): newest kept snapshot NOT confirmed server-side (rc=$rc) — retention SKIPPED this run (fail-safe: keeping extra copies)" 'WARN'
                        continue
                    }
                } catch {
                    Write-Log "SA GATE ($($d.Name)): verifier invocation failed: $($_.Exception.Message) — retention SKIPPED this run (fail-safe)" 'WARN'
                    continue
                }
            }
        } else {
            Write-Log "SA gate: helper or key absent — offsite retention proceeds WITHOUT server-side confirmation" 'WARN'
        }
    }

    # PERMANENT DELETE (offsite, Q8-b pivot 2026-11-17) : DriveFS Remove-Item envoie chaque
    # rotation en CORBEILLE (~30-190 Go/nuit -> forfait 5 To sature, RX162). Avec un token
    # OAuth user present (.gdrive_oauth.json, consenti via gdrive_oauth_consent.ps1), la
    # suppression se fait via l'API Drive EN TANT QUE USER : files.delete = DEFINITIF, sans
    # corbeille (SA-uploader mesure IMPOSSIBLE le 17/11 : 403 Storage Quota Exceeded, un SA
    # ne peut pas posseder de fichiers sur un My Drive consommateur). Sans token : legacy
    # corbeille + WARN (le user vide la corbeille a la main).
    $permDelete = $null
    if ($d.Name -eq 'offsite') {
        $userDelete = Join-Path $PSScriptRoot 'utilities\gdrive_user_delete.ps1'
        $oauthToken = Join-Path $PSScriptRoot '..\.gdrive_oauth.json'
        if ((Test-Path $userDelete) -and (Test-Path $oauthToken)) { $permDelete = $userDelete }
        else { Write-Log "PERM-DELETE: helper ou token OAuth absent - rotations offsite partiront EN CORBEILLE (legacy)" 'WARN' }
    }

    $deleted = 0
    foreach ($x in $dayDirs) {
        if (-not $keep.Contains($x.Name)) {
            if ($PSCmdlet.ShouldProcess($x.FullName, 'Remove old snapshot dir')) {
                if ($permDelete) {
                    # Fail-safe STRICT (relect. coord. 17/11) : si l'API echoue (token expire/revogue,
                    # reseau), on ne supprime NI definitivement NI via DriveFS — rien ne part en
                    # corbeille, les copies supplementaires restent. Un retour silencieux a la
                    # corbeille serait RX162 revu ; le sweep releve "perm-delete rc=" dans le log
                    # du jour et escalade ([ASK]) tant que le token n'est pas repare.
                    $rcPerm = -1
                    try {
                        $out = & powershell.exe -NoProfile -File $permDelete -DeleteDay $x.Name -Machine $MachineId -Collection $Collection 2>&1
                        $rcPerm = $LASTEXITCODE
                        foreach ($l in @($out)) { if ($l) { Write-Log "perm-delete: $l" } }
                    } catch { Write-Log "WARN: perm-delete invocation echouee $($x.Name): $($_.Exception.Message)" 'WARN' }
                    if ($rcPerm -eq 0) {
                        $deleted++
                        Write-Log "Retention ($($d.Name)) deleted PERMANENTLY: $($x.Name)"
                        # Cache eviction DriveFS uniquement apres succes server-side (le dossier est
                        # deja supprime cote Drive ; ceci ne peut pas le ressusciter en corbeille).
                        try { Remove-Item -Path $x.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                    } else {
                        Write-Log "WARN: perm-delete rc=$rcPerm pour $($x.Name) - RIEN supprime (fail-safe : ni definitif ni corbeille ; ESCALADE si recursif, token a re-consentir ?)" 'WARN'
                    }
                } else {
                    try { Remove-Item -Path $x.FullName -Recurse -Force; $deleted++; Write-Log "Retention ($($d.Name)) deleted: $($x.Name)" }
                    catch { Write-Log "WARN: delete failed $($x.Name): $($_.Exception.Message)" 'WARN' }
                }
            } else { Write-Log "WhatIf ($($d.Name)): would delete $($x.Name)" }
        }
    }
    Write-Log "Retention ($($d.Name)) complete: kept=$($keep.Count) deleted=$deleted$(if ($permDelete) { ' (permanent)' })"
}

Write-Log 'Backup done'
exit 0
