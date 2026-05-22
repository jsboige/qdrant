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
      3. Download to GDrive offsite (-SharedPath) and, unless skipped, to a local dir (-LocalCopyDir).
      4. SIZE-GUARD: if the new snapshot is < 50% of the largest existing one, SKIP retention and warn.
      5. Delete server-side snapshot.
      6. Retention: 7 daily + 4 weekly Mondays (per destination).

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
    [int]$MinPoints      = 100000,
    [string]$LogDir      = ''
)

$ErrorActionPreference = 'Stop'

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

if ($missing.Count -eq 0) {
    Write-Log "Idempotent: all destinations have today's snapshot."
} elseif ($existingTodayPath) {
    # Reuse the already-created snapshot; just fan it out to the missing destinations.
    $sourceFile = $existingTodayPath
    $newSnapshotSize = (Get-Item $sourceFile).Length
    Write-Log "Reusing existing snapshot for $($missing.Count) missing dest(s): $sourceFile ($newSnapshotSize bytes)"
} else {
    # No destination has today's: create a fresh server snapshot and download once.
    if ($PSCmdlet.ShouldProcess("$QdrantUrl/collections/$Collection/snapshots", 'POST create snapshot')) {
        try {
            $createResp = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots" -Headers $headers -Method Post -TimeoutSec 600
        } catch { Write-Log "FATAL: snapshot creation failed: $($_.Exception.Message)" 'ERROR'; exit 1 }
        $snapName = $createResp.result.name
        if ([string]::IsNullOrWhiteSpace($snapName)) { Write-Log 'FATAL: snapshot response missing name' 'ERROR'; exit 1 }
        Write-Log "Snapshot created: name=$snapName serverSize=$($createResp.result.size)"
        $tmp = Join-Path $env:TEMP $snapName
        try {
            Invoke-WebRequest -Uri "$QdrantUrl/collections/$Collection/snapshots/$snapName" -Headers $dlHeaders -OutFile $tmp -TimeoutSec 3600
        } catch { Write-Log "FATAL: download failed: $($_.Exception.Message)" 'ERROR'; exit 1 }
        $sourceFile = $tmp
        $newSnapshotSize = (Get-Item $tmp).Length
        Write-Log "Downloaded to temp: size=$newSnapshotSize bytes"
        # Server-side cleanup (non-fatal)
        try {
            $null = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection/snapshots/$snapName" -Headers $headers -Method Delete -TimeoutSec 120
            Write-Log "Server-side snapshot cleaned: $snapName"
        } catch { Write-Log "WARN: server-side cleanup failed (non-fatal): $($_.Exception.Message)" 'WARN' }
    } else {
        Write-Log 'WhatIf: would create + download snapshot, then distribute to all destinations'
    }
}

# Fan out the source file (existing or freshly downloaded) to every missing destination.
if ($sourceFile) {
    $snapLeaf = Split-Path $sourceFile -Leaf
    foreach ($d in $missing) {
        $dayDir = "$($d.Root)/$today"
        if ($PSCmdlet.ShouldProcess("$dayDir/$snapLeaf", "copy snapshot to $($d.Name)")) {
            if (-not (Test-Path $dayDir)) { New-Item -ItemType Directory -Path $dayDir -Force | Out-Null }
            Copy-Item -Path $sourceFile -Destination "$dayDir/$snapLeaf" -Force
            Write-Log "Copied to $($d.Name): $dayDir/$snapLeaf"
        }
    }
}
if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

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
    foreach ($x in ($dayDirs | Sort-Object Name -Descending | Select-Object -First 7)) { [void]$keep.Add($x.Name) }
    $mondays = $dayDirs | Where-Object {
        try { ([DateTime]::ParseExact($_.Name, 'yyyy-MM-dd', $null)).DayOfWeek -eq [DayOfWeek]::Monday } catch { $false }
    } | Sort-Object Name -Descending | Select-Object -First 4
    foreach ($m in $mondays) { [void]$keep.Add($m.Name) }

    $deleted = 0
    foreach ($x in $dayDirs) {
        if (-not $keep.Contains($x.Name)) {
            if ($PSCmdlet.ShouldProcess($x.FullName, 'Remove old snapshot dir')) {
                try { Remove-Item -Path $x.FullName -Recurse -Force; $deleted++; Write-Log "Retention ($($d.Name)) deleted: $($x.Name)" }
                catch { Write-Log "WARN: delete failed $($x.Name): $($_.Exception.Message)" 'WARN' }
            } else { Write-Log "WhatIf ($($d.Name)): would delete $($x.Name)" }
        }
    }
    Write-Log "Retention ($($d.Name)) complete: kept=$($keep.Count) deleted=$deleted"
}

Write-Log 'Backup done'
exit 0
