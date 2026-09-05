<#
.SYNOPSIS
    Qdrant lane surveillance sweep (6h cadence) — local probes only, read-only.

.DESCRIPTION
    One-shot probe bundle for the myia-ai-01:qdrant surveillance lane. Covers:
    healthz x3 (prod/students/external), roo_tasks point-count (floor alert is
    judged by the CALLING agent, not here), VHDX mount via the canonical
    -u root namespace probe (label check), container health, today's backup
    log tail, watchdog schtask states, DNS-vs-public-IP coherence, and the
    embedding watchdog log tail.

    Non-goals (agent-side, see .claude/skills/qdrant-sweep): sentinel probe
    (nsenter), real embedding inference POST, semantic KPI, inbox triage,
    dashboard [DONE].

.NOTES
    Read-only; never echoes API keys (reads QDRANT__SERVICE__API_KEY from
    myia_qdrant/.env.production, uses it in-memory only).
    Proven in production every 6h since 2026-08-17.
#>
$ErrorActionPreference = 'SilentlyContinue'

Write-Output '=== 1. HEALTHZ ==='
foreach ($u in @('http://localhost:6333/healthz','http://localhost:6335/healthz','https://qdrant.myia.io/healthz')) {
    try {
        $r = Invoke-WebRequest -Uri $u -Method GET -TimeoutSec 15 -SkipHttpErrorCheck -UseBasicParsing
        Write-Output "$u -> $($r.StatusCode)"
    } catch { Write-Output "$u -> 000 ($($_.Exception.Message))" }
}

Write-Output '=== 2. POINT-COUNT roo_tasks ==='
$envFile = 'D:\qdrant\myia_qdrant\.env.production'
$key = ''
if (Test-Path $envFile) {
    $line = (Get-Content $envFile | Where-Object { $_ -match '^QDRANT__SERVICE__API_KEY=' } | Select-Object -First 1)
    if ($line) { $key = ($line -replace '^QDRANT__SERVICE__API_KEY=', '').Trim().Trim('"').Trim("'") }
}
if ($key) {
    $h = @{ 'api-key' = $key }
    try {
        $info = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers $h -Method Get -TimeoutSec 30
        Write-Output "points=$($info.result.points_count) status=$($info.result.status)"
    } catch { Write-Output "collection read FAILED: $($_.Exception.Message)" }
} else { Write-Output 'KEY MISSING (env file)' }

Write-Output '=== 3. MOUNT VHDX (sonde canonique -u root) ==='
$out = & wsl.exe --cd / -d Ubuntu -u root -- bash -c "mountpoint -q /mnt/qdrant-e && findmnt -n -o SOURCE /mnt/qdrant-e || echo UNMOUNTED" 2>&1
Write-Output "probe=$out"
if ($out -match '/dev/') {
    $dev = ($out -split " ")[0]
    $lbl = & wsl.exe --cd / -d Ubuntu -u root -- bash -c "blkid -s LABEL -o value $dev 2>/dev/null" 2>&1
    Write-Output "device=$dev label=$lbl"
}
$dp = docker ps --filter "name=qdrant_production" --format "{{.Names}} {{.Status}}" 2>&1
Write-Output "docker: $dp"

Write-Output '=== 4. BACKUP DU JOUR ==='
$d = Get-Date -Format 'yyyyMMdd'
$log = "D:\qdrant\myia_qdrant\backups\snapshot-logs\snapshot-backup-$d.log"
if (Test-Path $log) {
    $last = (Get-Content $log -Tail 3) -join ' | '
    Write-Output "log($d): $last"
} else { Write-Output "LOG $d ABSENT (normal avant ~03:20, le run schtask est a 03:17)" }
schtasks /query /tn "Qdrant-Snapshot-Daily" /v /fo LIST 2>&1 | Select-String 'R.sultat|Derni.re ex.cution'

Write-Output '=== 5. SCHTASKS WATCHDOGS ==='
foreach ($t in @('Verify-Qdrant-Mount','Mount-Qdrant-VHDX','Watchdog-Embedding-API')) {
    $r = schtasks /query /tn $t /v /fo LIST 2>&1 | Select-String 'R.sultat|Derni.re ex.cution|Prochaine ex.cution'
    Write-Output "--- $t"
    $r
}

Write-Output '=== 8. DNS vs IP PUBLIQUE (IPv4 force) ==='
$ip = (curl.exe -4 -s --max-time 15 https://ifconfig.me/ip).Trim()
Write-Output "public_ip4=$ip"
try {
    $dns = (Resolve-DnsName qdrant.myia.io -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
    Write-Output "dns_qdrant=$dns"
} catch { Write-Output "dns_qdrant=FAIL ($($_.Exception.Message))" }

Write-Output '=== WATCHDOG LOG (embedding, 6 dernieres lignes) ==='
Get-Content 'C:\ProgramData\maint-scripts\logs\embedding-watchdog.log' -Tail 6
