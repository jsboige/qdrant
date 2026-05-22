<#
.SYNOPSIS
    Restore a Qdrant .snapshot file into a collection (sister of qdrant_snapshot_backup.ps1).

.DESCRIPTION
    Uploads a .snapshot file via PUT /collections/<c>/snapshots/upload. Optionally drops the
    target collection first (-RecreateCollection, DESTRUCTIVE, confirmed). Verifies point count.
    Consolidated into the fork 2026-05-21 (port of D:\roo-extensions\scripts\qdrant\restore-snapshot.ps1).

    SAFE restore to verify a backup without touching production data:
      qdrant_snapshot_restore.ps1 -SnapshotPath <file> -Collection <temp_name>
    (uploads into a NEW collection; existing data untouched.)

.PARAMETER SnapshotPath
    Full path to the .snapshot file (e.g. from GDrive qdrant-snapshots/... or D:\qdrant-backups\...).

.PARAMETER Collection
    Target collection name.

.PARAMETER RecreateCollection
    DROP the target collection (DELETE /collections/<c>) before upload. DESTRUCTIVE.

.PARAMETER Force
    Skip the interactive "type DROP" confirmation (for scheduled/automated use).

.NOTES
    API key read from myia_qdrant/.env.production (QDRANT__SERVICE__API_KEY). Never printed.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$SnapshotPath,
    [Parameter(Mandatory = $true)][string]$Collection,
    [string]$QdrantUrl = $(if ($env:QDRANT_URL) { $env:QDRANT_URL } else { 'http://localhost:6333' }),
    [string]$ApiKey = '',
    [switch]$RecreateCollection,
    [switch]$Force,
    [string]$LogDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SnapshotPath)) {
    [Console]::Error.WriteLine("ERROR: snapshot file not found: $SnapshotPath")
    exit 1
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

$jsonHeaders = @{ 'Content-Type' = 'application/json' }
$uploadHeaders = @{}
if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { $jsonHeaders['api-key'] = $ApiKey; $uploadHeaders['api-key'] = $ApiKey }

if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $PSScriptRoot '..\backups\snapshot-logs' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$logFile = Join-Path $LogDir "snapshot-restore-$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Information $line -InformationAction Continue
}

$snapInfo = Get-Item $SnapshotPath
Write-Log "Restore start: snapshot=$($snapInfo.FullName) size=$($snapInfo.Length) collection=$Collection target=$QdrantUrl"

# ========== OPTIONAL DESTRUCTIVE DROP ==========

if ($RecreateCollection) {
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('  WARNING: THIS WILL DROP THE COLLECTION before restore.')
    [Console]::Error.WriteLine("  Target: $QdrantUrl / $Collection")
    [Console]::Error.WriteLine('')
    if (-not $Force) {
        $answer = Read-Host 'Type DROP to continue, anything else to abort'
        if ($answer -ne 'DROP') { Write-Log 'User aborted (no DROP)' 'WARN'; [Console]::Error.WriteLine('Aborted.'); exit 1 }
    }
    if ($PSCmdlet.ShouldProcess("$QdrantUrl/collections/$Collection", 'DELETE collection')) {
        try {
            $null = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection" -Headers $jsonHeaders -Method Delete -TimeoutSec 120
            Write-Log "Collection dropped: $Collection"
        } catch { Write-Log "WARN: drop failed (may not exist): $($_.Exception.Message)" 'WARN' }
    }
}

# ========== UPLOAD ==========

if (-not $PSCmdlet.ShouldProcess("$QdrantUrl/collections/$Collection/snapshots/upload", 'PUT upload snapshot')) {
    Write-Log 'WhatIf: would upload snapshot — exiting'
    exit 0
}

try {
    $uploadResp = Invoke-WebRequest -Uri "$QdrantUrl/collections/$Collection/snapshots/upload" `
        -Headers $uploadHeaders -Method Post -Form @{ snapshot = Get-Item -Path $SnapshotPath } -TimeoutSec 3600
    Write-Log "Upload HTTP $($uploadResp.StatusCode)"
} catch {
    Write-Log "FATAL: upload failed: $($_.Exception.Message)" 'ERROR'
    [Console]::Error.WriteLine("Upload failed: $($_.Exception.Message)")
    exit 1
}

# ========== VERIFY ==========

Start-Sleep -Seconds 2
try {
    $info = Invoke-RestMethod -Uri "$QdrantUrl/collections/$Collection" -Headers $jsonHeaders -Method Get -TimeoutSec 60
    Write-Log "Restored collection: status=$($info.result.status) points=$($info.result.points_count)"
    Write-Output "Restore complete: $Collection points=$($info.result.points_count) status=$($info.result.status)"
} catch { Write-Log "WARN: verification GET failed: $($_.Exception.Message)" 'WARN' }

exit 0
