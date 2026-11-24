# verify_qdrant_mount.selftest.ps1 -- fail-closed (jsboige/Maintenance#380).
#
# Executes the REAL guard against fake wsl.exe / docker.exe, in the current process so no
# real process (wsl, docker, schtasks, eventcreate) is ever launched: the fake commands are
# PowerShell functions, and the state writes are recorded in memory instead of the real
# scheduled-task log directory.
#
# Method: read the guard file, strip the functions that do I/O (Log, TryRemediate, WriteState,
# NotifyEvent) and replace them by in-memory versions, then Invoke-Expression the remaining
# REAL code. exit() is converted into a terminating throw so a test case cannot kill the host.
# Scenarios are built by wrapping the fake wsl.exe/docker.exe, never by editing the guard.
#
# Tests A-F requested by Maintenance#380 + healthy baseline, UNMOUNTED, wrong label, empty label.
# Exit code = number of failures. Run under BOTH powershell.exe (5.1, production) and pwsh.
param(
    [string]$Guard = (Join-Path $PSScriptRoot '..\host\verify_qdrant_mount.ps1')
)
$ErrorActionPreference = 'Stop'
$guardPath = (Resolve-Path $Guard).Path
$text = [IO.File]::ReadAllText($guardPath) -replace "`r", ""
$fail = 0

# --- tokens/parse of the shipped file (both editions) ---
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($guardPath, [ref]$tokens, [ref]$errors) | Out-Null
Write-Host "[parse] errors=$($errors.Count)"
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Host "    $($_.Message)" }; exit 1 }

# --- scenario: blind wsl.exe, as PowerShell captures it ---
# wsl.exe writes its failure text as UTF-16 on stdout, so the captured string carries a NUL
# between every character and never contains the PROBE_RAN marker. Built the same way.
$blindRaw = -join ('Wsl/Service/0x8007274c Une tentative de connexion a echoue.'.ToCharArray() | ForEach-Object { [string]$_ + [char]0 })

$stateDir = Join-Path $PSScriptRoot '..\..\..\.tmp\verify-selftest'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$stateFile = Join-Path $stateDir 'qdrant-mount-state.json'

# The guard body, minus the functions replaced below, exits turned into throws.
$body = $text
foreach ($fn in 'Log', 'TryRemediate', 'WriteState', 'NotifyEvent') {
    $m = [regex]::Match($body, "(?m)^function $fn \{")
    if (-not $m.Success) { Write-Host "function $fn not found"; exit 1 }
    $depth = 0; $end = -1
    for ($i = $m.Index + $m.Length - 1; $i -lt $body.Length; $i++) {
        if ($body[$i] -eq '{') { $depth++ } elseif ($body[$i] -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { Write-Host "function $fn unterminated"; exit 1 }
    $body = $body.Remove($m.Index, $end - $m.Index + 1)
}
$body = $body -replace '(?m)^(\s*)exit (\d+)\s*$', '$1throw "EXIT:$2"'

function Log { param($msg, $lvl = 'INFO') $script:Logs += "[$lvl] $msg" }
function TryRemediate { param([int]$ExitCode, [string]$Status) $script:Triggers += "exit=$ExitCode status=$Status" }
function WriteState { param([int]$ExitCode, [string]$Status, [hashtable]$Data = @{}) $script:State = @{ code = $ExitCode; status = $Status; data = $Data } }
function NotifyEvent { param([int]$EventId, [string]$Type = 'ERROR', [string]$Message) $script:Events += "id=$EventId type=$Type" }

# Fake commands: exactly the same call shapes as the guard uses.
$script:Mode = ''
function wsl.exe {
    switch ($script:Mode) {
        'blind' { $global:LASTEXITCODE = -1; $script:Blind }
        'unmounted' { $global:LASTEXITCODE = 0; @('PROBE_RAN', 'UNMOUNTED') }
        default {
            $global:LASTEXITCODE = 0
            $a = ($args -join ' ')
            if ($a -match 'findmnt') { @('PROBE_RAN', '/dev/sdd') }
            elseif ($a -match 'blkid') {
                @('PROBE_RAN')
                if ($script:Mode -eq 'empty-label') { } elseif ($script:Mode -eq 'wrong-label') { 'other-label' } else { 'qdrant-e' }
            } else { @('PROBE_RAN') }
        }
    }
}
function docker.exe {
    $a = ($args -join ' ')
    if ($a -match '^inspect') {
        switch ($script:Docker) {
            'absent' { $global:LASTEXITCODE = 1; 'Error: No such object: qdrant_production'; return }
            'stopped' { $global:LASTEXITCODE = 0; 'false'; return }
            'bad-engine' { $global:LASTEXITCODE = 1; 'Cannot connect to the Docker daemon'; return }
            default { $global:LASTEXITCODE = 0; 'true'; return }
        }
    }
    if ($a -match '^exec') {
        if ($script:Docker -eq 'bad-exec') { $global:LASTEXITCODE = 1; 'Error response from daemon: container is not running'; return }
        $global:LASTEXITCODE = 0
        if ($a -match 'wc -l') { $script:Coll } elseif ($a -match 'df ') { if ($script:Docker -eq 'drift-device') { '/dev/sde' } else { '/dev/sdd' } }
    }
}

$cases = @(
    @{ Id = 'A1'; mode = 'blind'; docker = 'bad-engine'; coll = ''; prev = 0; exit = 5; trig = 0; esc = 0; note = 'sonde aveugle + Docker injoignable' },
    @{ Id = 'A2'; mode = 'blind'; docker = 'bad-engine'; coll = ''; prev = 1; exit = 5; trig = 0; esc = 0; note = '2e passe' },
    @{ Id = 'A3'; mode = 'blind'; docker = 'bad-engine'; coll = ''; prev = 2; exit = 5; trig = 0; esc = 1; note = '3e passe : ESCALADE, pas DRIFT' },
    @{ Id = 'A4'; mode = 'blind'; docker = 'bad-engine'; coll = ''; prev = 9; exit = 5; trig = 0; esc = 0; note = '10e passe : toujours PROBE_ERROR, jamais de remediation' },
    @{ Id = 'B';  mode = 'blind'; docker = 'healthy'; coll = '118'; prev = 0; exit = 0; trig = 0; status = 'OK_DOCKER_PROOF'; note = 'aveugle mais docker exec rend 118 => pas de derive' },
    @{ Id = 'C';  mode = 'healthy'; docker = 'bad-engine'; coll = ''; prev = 0; exit = 5; trig = 0; note = 'docker inspect en erreur => PROBE_ERROR' },
    @{ Id = 'D';  mode = 'healthy'; docker = 'bad-exec'; coll = ''; prev = 0; exit = 5; trig = 0; note = 'healthy + docker exec en echec => PROBE_ERROR, jamais -1 collections' },
    @{ Id = 'E';  mode = 'healthy'; docker = 'healthy'; coll = '3'; prev = 0; exit = 3; trig = 1; note = 'derive reelle : compteur LU 3 (< 50) => remediation' },
    @{ Id = 'E3'; mode = 'healthy'; docker = 'drift-device'; coll = '118'; prev = 0; exit = 4; trig = 1; note = 'derive reelle : device du conteneur != device du montage => remediation' },
    @{ Id = 'E2'; mode = 'blind'; docker = 'healthy'; coll = '3'; prev = 2; exit = 3; trig = 1; esc = 1; note = 'aveugle + compteur LU 3 : preuve positive de derive (code 3), meme apres escalation' },
    @{ Id = 'F';  mode = 'healthy'; docker = 'absent'; coll = ''; prev = 0; exit = 9; trig = 1; note = 'conteneur supprime => code 9 inchange' },
    @{ Id = 'G';  mode = 'healthy'; docker = 'healthy'; coll = '118'; prev = 0; exit = 0; trig = 0; status = 'OK'; note = 'baseline saine' },
    @{ Id = 'H';  mode = 'unmounted'; docker = 'healthy'; coll = '118'; prev = 0; exit = 1; trig = 1; note = 'Linux repond UNMOUNTED => vraie derive' },
    @{ Id = 'I';  mode = 'wrong-label'; docker = 'healthy'; coll = '118'; prev = 0; exit = 2; trig = 1; note = 'label different => derive' },
    @{ Id = 'J';  mode = 'empty-label'; docker = 'healthy'; coll = '118'; prev = 0; exit = 0; trig = 0; status = 'OK_DOCKER_PROOF'; note = 'blkid sans reponse = ILLISIBLE ; la preuve Docker tranche : pas de derive' },
    @{ Id = 'J2'; mode = 'empty-label'; docker = 'bad-exec'; coll = ''; prev = 0; exit = 5; trig = 0; note = 'blkid sans reponse + Docker illisible => PROBE_ERROR, jamais DRIFT_WRONG_LABEL' }
)

foreach ($c in $cases) {
    $script:Mode = $c.mode; $script:Docker = $c.docker; $script:Coll = $c.coll
    $script:Blind = $blindRaw
    $script:Logs = @(); $script:Triggers = @(); $script:Events = @(); $script:State = $null
    $rc = 0; $thrown = ''
    # The streak of consecutive blind probes is carried by the state file, as in the real task.
    if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
    if ($c.prev -gt 0) {
        [IO.File]::WriteAllText($stateFile, (@{ timestamp = '2026-11-24T00:00:00'; exit_code = 5; status = 'PROBE_ERROR'; details = @{ probe_error_streak = $c.prev } } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    }
    $argMap = @{
        Distro = 'Ubuntu'; MountPoint = '/mnt/qdrant-e'; ExpectedLabel = 'qdrant-e'
        MinCollections = 50; Container = 'qdrant_production'; Remediate = $true
        CooldownMinutes = 15; SelfTimeoutSeconds = 0; ProbeErrorEscalateAfter = 3
        LogDir = $stateDir
    }
    $sb = [ScriptBlock]::Create($body)
    try {
        & $sb @argMap | Out-Null
    } catch {
        $thrown = $_.Exception.Message
        if ($thrown -match '^EXIT:(\d+)$') { $rc = [int]$matches[1] } else { $rc = -99; Write-Host "      ERREUR: $thrown" }
    }
    $esc = @($script:Logs | Where-Object { $_ -match 'ESCALADE' }).Count
    $escExp = 0; if ($null -ne $c.esc) { $escExp = [int]$c.esc }
    $ok = ($rc -eq $c.exit) -and ($script:Triggers.Count -eq $c.trig) -and ($esc -eq $escExp)
    if ($c.status) { $ok = $ok -and ($script:State -and $script:State.status -eq $c.status) }
    if (($script:Logs -join ' ') -match 'DRIFT.*(tentative de connexion|Wsl/Service)') { $ok = $false }
    # the streak must grow by exactly one per blind pass
    if ($c.mode -eq 'blind' -and $script:State -and $script:State.data['probe_error_streak'] -ne ($c.prev + 1)) { $ok = $false }
    # the wsl.exe text may be kept as a diagnostic (details.raw) but never used as a state value
    foreach ($k in 'label', 'device', 'container_device', 'ubuntu_device', 'collections_seen') {
        if ($script:State -and "$($script:State.data[$k])" -match '(tentative de connexion|Wsl/Service)') { $ok = $false }
    }
    Write-Host ("[{0,-3}] exit={1,3} triggers={2} escalade={3} -> {4} ({5})" -f $c.Id, $rc, $script:Triggers.Count, $esc, $(if ($ok) { 'PASS' } else { 'FAIL' }), $c.note)
    if (-not $ok) { $fail++; $script:Logs | Select-Object -Last 8 | ForEach-Object { Write-Host "      $_" } }
    else { $script:Logs | Where-Object { $_ -match 'PROBE_ERROR|OK:|DRIFT|container|Docker prouve' } | ForEach-Object { Write-Host "      $_" } }
}
Write-Host "RESULTAT ($($PSVersionTable.PSVersion)) : $(if ($fail -eq 0) { 'TOUT PASS' } else { "$fail ECHEC(S)" })"
exit $fail
