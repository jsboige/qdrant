<#
.SYNOPSIS
    Selftest of qdrant_snapshot_backup.ps1 decision blocks — REAL code extracted from the script,
    fake inputs. No Qdrant request, no snapshot, no network.

.DESCRIPTION
    Covers three blocks added/fixed on 2026-11-26:
      T1  orphan cleanup: v1.20.2 returns creation_time NULL -> the UTC build time is taken from the
          snapshot NAME; today's leftover must be KEPT (the REUSE path needs it), only >48h goes.
      T2  transit volume: candidates must keep snapshot + margin + max(floor GB, floor %) free, and
          the script REFUSES when no candidate qualifies (no silent fallback to %TEMP%).
      T3  NO-TRANSIT: the server-side file is read in place only when it exists with the exact size
          the API reports; anything else falls back to the download.
    Extraction = text between two unique WHOLE lines of the script, so a refactor that moves or
    re-indents a block fails loudly here instead of silently testing stale code.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File snapshot_backup_selftest.ps1
    pwsh -NoProfile -File snapshot_backup_selftest.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Resolved here, not in the param default: $PSScriptRoot is EMPTY there under Windows PowerShell 5.1.
if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = Join-Path $PSScriptRoot '..\qdrant_snapshot_backup.ps1' }

$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = @($src -split "`r?`n")

function Find-Line {
    param([string]$Needle)
    $hits = @($lines | Where-Object { $_.TrimEnd() -ceq $Needle })
    if ($hits.Count -ne 1) { throw "marker line '$Needle' found $($hits.Count) time(s) in $ScriptPath (expected exactly 1)" }
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].TrimEnd() -ceq $Needle) { return $i } }
}

function Get-Block {
    param([string]$From, [string]$Before)
    $a = Find-Line $From
    $b = Find-Line $Before
    if ($b -le $a) { throw "block '$From' must come before '$Before'" }
    return ($lines[$a..($b - 1)] -join "`n")
}

function Get-BlockThrough {
    # From a unique line to N lines after another unique line (for a block whose closing line is not unique).
    param([string]$From, [string]$Through, [int]$Extra = 0)
    $a = Find-Line $From
    $b = Find-Line $Through
    if ($b -le $a) { throw "block '$From' must come before '$Through'" }
    return ($lines[$a..($b + $Extra)] -join "`n")
}

$script:failures = 0
$script:checks = 0
function Assert {
    param([bool]$Cond, [string]$Label)
    $script:checks++
    if ($Cond) { Write-Host "  ok   $Label" } else { Write-Host "  FAIL $Label" -ForegroundColor Red; $script:failures++ }
}

# ---- mocks shared by the blocks (a function shadows the cmdlet of the same name) ----
$script:log = @()
function Write-Log { param([string]$Message, [string]$Level = 'INFO') $script:log += "[$Level] $Message" }
$script:deleted = @()
$script:getResult = $null
function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $TimeoutSec)
    if ("$Method" -eq 'Delete') { $script:deleted += ("$Uri" -replace '^.*/', ''); return $null }
    return $script:getResult
}
# Fixed clock, UTC: the blocks call (Get-Date).ToUniversalTime().AddHours(-48).
function Get-Date { return [datetime]::SpecifyKind([datetime]'2026-11-26T12:00:00', 'Utc') }
$script:drives = @{}
function Get-DriveSpace {
    param([string]$Path)
    $root = [System.IO.Path]::GetPathRoot($Path)
    if (-not $script:drives.ContainsKey($root)) { throw "drive $root not found (fake)" }
    return $script:drives[$root]
}

[int64]$GB = 1GB
[int64]$SNAP = 247857645568

Write-Host 'T1  orphan cleanup (creation_time NULL -> name; today''s leftover kept)'
$t1 = Get-Block '    $orphCutoff = (Get-Date).ToUniversalTime().AddHours(-48)' '    # Always log the summary: a silent success is indistinguishable from "block never ran".'
$orphList = @{ result = @(
        [pscustomobject]@{ name = 'c-1-2026-11-26-01-17-06-0.snapshot'; creation_time = $null;                  size = $SNAP }   # today's leftover: KEEP (REUSE path)
        [pscustomobject]@{ name = 'c-1-2026-11-23-01-17-01-1.snapshot'; creation_time = $null;                  size = 1 }        # 3 days: DELETE
        [pscustomobject]@{ name = 'c-1-2026-11-24-13-00-00-0.snapshot'; creation_time = $null;                  size = 1 }        # 47 h old: KEEP
        [pscustomobject]@{ name = 'c-1-2026-11-24-11-59-59-0.snapshot'; creation_time = $null;                  size = 1 }        # 48 h + 1 s: DELETE
        [pscustomobject]@{ name = 'c-1-2026-11-20-10-00-00-0.snapshot'; creation_time = '2026-11-20T10:00:00Z'; size = 1 }        # creation_time present: DELETE
        [pscustomobject]@{ name = 'no-date-here.snapshot';             creation_time = $null;                  size = 1 }        # unparseable: SKIP
    ) }
$QdrantUrl = 'http://x'; $Collection = 'c'; $headers = @{}
. ([scriptblock]::Create($t1))
$expectDel = @('c-1-2026-11-20-10-00-00-0.snapshot', 'c-1-2026-11-23-01-17-01-1.snapshot', 'c-1-2026-11-24-11-59-59-0.snapshot')
$gotDel = (@($script:deleted | Sort-Object) -join ',')
Assert ($gotDel -eq (@($expectDel | Sort-Object) -join ',')) "deleted = exactly the 3 expired (got: $gotDel)"
Assert ($orphDeleted -eq 3) "orphDeleted = 3 (got $orphDeleted)"

Write-Host 'T2  transit volume (floor = max(GB, %) ; REFUSE when no candidate)'
$t2 = Get-Block '            $noTransitVolume = $false' '            if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }'
$script:TempMarginGB = 30; $script:TempFloorGB = 50; $script:TempFloorPct = 6
$script:TempDirFallbacks = @('F:\qdrant-tmp'); $env:TEMP = 'C:\Users\x\AppData\Local\Temp'

# a) the evening of 2026-11-26 IF the in-place path did not apply: C: 324.2 GiB free of 3722 GiB;
#    F: 793.7 GiB free of 7418 GiB BEFORE the build, minus the 231 GiB snapshot the build just wrote
#    (this check runs AFTER the snapshot exists) = 562.8 GiB.
$script:log = @(); $script:drives = @{}
$script:drives['C:\'] = @{ Free = [int64](324.2 * $GB); Total = [int64](3722.0 * $GB) }
$script:drives['F:\'] = @{ Free = [int64](562.8 * $GB); Total = [int64](7418.0 * $GB) }
$TempDir = ''; $snapSize = $SNAP
. ([scriptblock]::Create($t2))
Assert ($noTransitVolume -eq $true) 'a) no candidate -> refuse (C: and F: both too tight)'
Assert (@($script:log | Where-Object { $_ -match 'Temp candidate skipped' }).Count -eq 2) 'a) both candidates logged as skipped'
Assert (@($script:log | Where-Object { $_ -match 'Temp volume selected' }).Count -eq 0) 'a) no volume selected'

# a2) the floor is a share of the volume: on F: (7.4 TiB) 6 % = 445 GiB, so a 793.7 GiB volume
#     passes BEFORE a build but not after one — unlike a flat 50 GB floor.
$script:log = @(); $script:drives = @{}
$script:drives['C:\'] = @{ Free = [int64](0.5 * $GB); Total = [int64](3722.0 * $GB) }
$script:drives['F:\'] = @{ Free = [int64](793.7 * $GB); Total = [int64](7418.0 * $GB) }
$TempDir = ''; $snapSize = $SNAP
. ([scriptblock]::Create($t2))
Assert (($noTransitVolume -eq $false) -and ($TempDir -eq 'F:\qdrant-tmp')) "a2) F: with its pre-build 793.7 GiB qualifies (got '$TempDir')"

# b) premise: PR #63's rule (floor 50 GB alone) WOULD have picked C: on the very same volumes.
Assert (([int64](324.2 * $GB) -ge ($SNAP + [int64]30 * $GB + [int64]50 * $GB))) 'b) premise: a 50 GB floor alone would have picked C: (the hole this closes)'

# c) a volume with real room is picked; the first qualifying candidate wins.
$script:log = @(); $script:drives = @{}
$script:drives['C:\'] = @{ Free = [int64](324.2 * $GB); Total = [int64](3722.0 * $GB) }
$script:drives['F:\'] = @{ Free = [int64](1200.0 * $GB); Total = [int64](7418.0 * $GB) }
$TempDir = ''; $snapSize = $SNAP
. ([scriptblock]::Create($t2))
Assert (($noTransitVolume -eq $false) -and ($TempDir -eq 'F:\qdrant-tmp')) "c) F: picked when it has room (got '$TempDir')"

# d) %TEMP% picked when it genuinely has room.
$script:log = @(); $script:drives = @{}
$script:drives['C:\'] = @{ Free = [int64](900.0 * $GB); Total = [int64](3722.0 * $GB) }
$TempDir = ''; $snapSize = $SNAP
. ([scriptblock]::Create($t2))
Assert (($noTransitVolume -eq $false) -and ($TempDir -eq $env:TEMP)) "d) %TEMP% picked when it has room (got '$TempDir')"

# e) explicit -TempDir: the loop is skipped, no refusal flag.
$script:log = @(); $script:drives = @{}
$TempDir = 'E:\somewhere'; $snapSize = $SNAP
. ([scriptblock]::Create($t2))
Assert (($noTransitVolume -eq $false) -and ($TempDir -eq 'E:\somewhere')) 'e) explicit -TempDir left untouched'

Write-Host 'T3  NO-TRANSIT decision (in place only on collection + name + exact size)'
# The `if ($directPath) {` block closes on a shared line (`        } else {`), not a unique one: take
# it through its last statement and close the block ourselves, then run it as a full statement.
$t3 = Get-BlockThrough '        $directPath = $null' '            Write-Log "NO-TRANSIT: fan-out reads the server-side snapshot file itself (no download, no temp copy): $directPath"' 0
$t3 = $t3 + "`n" + '        }'
Assert (([scriptblock]::Create($t3)).Ast.EndBlock.Statements.Count -ge 2) 'T3 block parses as a statement list'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("snap-selftest-" + [guid]::NewGuid().ToString('N'))
$Collection = 'c'
$null = New-Item -ItemType Directory -Path (Join-Path $work $Collection) -Force
try {
    $name = 'c-1-2026-11-26-01-17-06-0.snapshot'
    $f = Join-Path (Join-Path $work $Collection) $name
    [System.IO.File]::WriteAllBytes($f, (New-Object byte[] 4096))
    $ServerSnapshotLocalRoot = $work

    $snapName = $name; $snapSize = [int64]4096; $script:log = @(); $directPath = 'unset'; $tmpIsServerSide = $false; $tmp = $null; $sourceFile = $null; $newSnapshotSize = 0
    . ([scriptblock]::Create($t3))
    Assert (($directPath -eq $f) -and $tmpIsServerSide -and ($tmp -eq $f) -and ($sourceFile -eq $f) -and ($newSnapshotSize -eq 4096)) 'a) exact size -> read in place'
    Assert (@($script:log | Where-Object { $_ -match '^\[INFO\] NO-TRANSIT' }).Count -eq 1) 'a) NO-TRANSIT logged'

    $snapName = $name; $snapSize = [int64]4097; $script:log = @(); $directPath = 'unset'; $tmpIsServerSide = $false
    . ([scriptblock]::Create($t3))
    Assert (($null -eq $directPath) -and (-not $tmpIsServerSide)) 'b) size differs by 1 byte -> download path'
    Assert (@($script:log | Where-Object { $_ -match 'differs from the API' }).Count -eq 1) 'b) mismatch warned'

    $snapName = 'c-1-2026-11-26-01-17-07-0.snapshot'; $snapSize = [int64]4096; $script:log = @(); $directPath = 'unset'; $tmpIsServerSide = $false
    . ([scriptblock]::Create($t3))
    Assert ($null -eq $directPath) 'c) file absent -> download path'

    $snapName = $name; $snapSize = [int64]4096; $ServerSnapshotLocalRoot = '-'; $script:log = @(); $directPath = 'unset'; $tmpIsServerSide = $false
    . ([scriptblock]::Create($t3))
    Assert ($null -eq $directPath) 'd) root ''-'' disables the in-place path'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Write-Host 'T4  POST answered with an error: use the snapshot the server stored during the call'
# The catch body of the POST, minus its FATAL else-branch (an `exit 1` cannot run inside a test).
# Run it inside a real catch so `$_` is the POST error, as in the script.
$t4 = Get-BlockThrough '            $postErr = $_.Exception.Message' '                $createResp = [pscustomobject]@{ result = [pscustomobject]@{ name = $stored.name; size = $stored.size } }' 0
$t4 = $t4 + "`n" + '            }'
$t4sb = [scriptblock]::Create($t4)
$QdrantUrl = 'http://x'; $headers = @{}
$old  = 'c-1-2026-11-25-01-17-01-0.snapshot'      # yesterday's leftover, listed before AND after
$new  = 'c-1-2026-11-26-11-59-58-0.snapshot'      # built during the call (fixed clock = 12:00:00Z)
$late = 'c-1-2026-11-26-12-00-30-0.snapshot'      # built during the call too, later
# Dot-sourced INLINE (not inside a function: assignments there would stay function-local).

# a) the server stored an artifact during the call -> it is ours
$beforeNames = @($old)
$script:getResult = @{ result = @([pscustomobject]@{ name = $old; size = 5 }, [pscustomobject]@{ name = $new; size = 188416 }) }
$createResp = $null; $script:log = @()
try { throw 'Le code d etat de la reponse n a pas abouti : 500 (Internal Server Error).' } catch { . $t4sb }
Assert (($null -ne $createResp) -and ($createResp.result.name -eq $new) -and ($createResp.result.size -eq 188416)) "a) the artifact stored during the call is used (got '$($createResp.result.name)')"
Assert (@($script:log | Where-Object { $_ -match 'BUT the server stored' }).Count -eq 1) 'a) warned'

# b) timeout class: nothing new server-side (the build is still running) -> not tolerated
$beforeNames = @($old)
$script:getResult = @{ result = @([pscustomobject]@{ name = $old; size = 5 }) }
$createResp = $null; $script:log = @()
try { throw 'HttpClient.Timeout of 14400 seconds' } catch { . $t4sb }
Assert ($null -eq $createResp) 'b) nothing new -> stays FATAL (branch not executed here)'

# c) an artifact of today that ALREADY existed before the call is not credited to this call
$beforeNames = @($old, $new)
$script:getResult = @{ result = @([pscustomobject]@{ name = $old; size = 5 }, [pscustomobject]@{ name = $new; size = 188416 }) }
$createResp = $null; $script:log = @()
try { throw 'boom 500' } catch { . $t4sb }
Assert ($null -eq $createResp) 'c) pre-existing snapshot not credited to the call'

# d) two stored during the call -> the latest
$beforeNames = @($old)
$script:getResult = @{ result = @([pscustomobject]@{ name = $old; size = 5 }, [pscustomobject]@{ name = $new; size = 1 }, [pscustomobject]@{ name = $late; size = 2 }) }
$createResp = $null; $script:log = @()
try { throw 'boom 500' } catch { . $t4sb }
Assert (($null -ne $createResp) -and ($createResp.result.name -eq $late)) "d) latest of the call wins (got '$($createResp.result.name)')"

Write-Host ("{0} checks, {1} failure(s) under PowerShell {2}" -f $script:checks, $script:failures, $PSVersionTable.PSVersion)
if ($script:failures -gt 0) { exit 1 }
exit 0
