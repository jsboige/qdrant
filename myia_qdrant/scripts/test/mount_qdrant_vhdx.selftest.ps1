# mount_qdrant_vhdx.selftest.ps1 -- non-regression du script de montage (host, elevated schtask).
#
# Defauts deja pris par ce script (un par semaine) : CRLF dans les payloads bash (31/10),
# ErrorActionPreference=Stop + stderr natif (03/11), alias /srv masque (02/11, 13/11),
# umount sur sonde sourde (23/11). Ce selftest execute le CODE REEL extrait du fichier
# (jamais une copie) contre un wsl.exe factice, et optionnellement le payload bash en vrai.
#
# Modes :
#   (defaut)          parse + tests unitaires (aucun processus wsl lance pour les unitaires)
#   -Real             + execution REELLE du payload sur l'alias courant (non destructif s'il est sain)
#   -Real -TestRepair + demontage/re-bind REEL de l'alias /srv/qdrant-e dans PID-1 (sans effet
#                     sur le conteneur ; ne pas lancer pendant un compose up)
# -Source <chemin>    teste la copie DEPLOYEE (C:\ProgramData\maint-scripts\...) au lieu du depot
# Exit code = nombre d'echecs. Interpreteur de production = powershell.exe 5.1 : tester les deux.
param([switch]$Real, [switch]$TestRepair, [string]$Source = '')
if ($TestRepair -and -not $Real) { $Real = $true }
$ErrorActionPreference = "Stop"
$src = if ($Source) { $Source } else { (Resolve-Path (Join-Path $PSScriptRoot '..\host\mount_qdrant_vhdx.ps1')).Path }
$probeSrvAlias = '/mnt/d/qdrant/myia_qdrant/scripts/monitoring/probe_srv_alias.sh'
$fail = 0

# --- 1) parse ---
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errors) | Out-Null
Write-Host "[1] parse ($($PSVersionTable.PSVersion)) errors=$($errors.Count)"
foreach ($e in $errors) { Write-Host "    $($e.Message) @ line $($e.Extent.StartLineNumber)"; $fail++ }

# --- 2) payload bash : syntaxe + cas sain REEL ---
$text = Get-Content -Raw -Encoding UTF8 $src
$m = [regex]::Match($text, "(?s)\`$aliasScript = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { Write-Host "[2] here-string aliasScript INTROUVABLE"; exit 1 }
$payload = $m.Groups[1].Value -replace "`r", ""
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
if ($Real) {
    $syn = & wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- bash -c "echo $b64 | base64 -d | bash -n && echo SYNTAX_OK" 2>&1
    Write-Host "[2] bash -n : $syn"
    $real = & wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- bash -c "echo $b64 | base64 -d | bash" 2>&1
    Write-Host "[2] execution reelle (alias attendu SAIN) : $real"
    if ("$real" -notmatch 'alias-ok:sain') { Write-Host "    FAIL : verdict inattendu"; $fail++ }
    $after = & wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- stat -c '%s' /srv/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>&1
    Write-Host "[2] sentinel via alias apres execution : $after"
    if ("$after".Trim() -ne '285') { Write-Host "    FAIL : sentinel != 285"; $fail++ }
}

# --- 2b) chemin de REPARATION en reel : alias demonte dans PID-1 (sans effet sur le conteneur,
# prouve de 18:21Z a 18:55Z), payload, attendu alias-ok:repare ---
if ($TestRepair) {
    $proxyBefore = (& wsl.exe -d Ubuntu -u root -- bash $probeSrvAlias 2>&1 | Out-String).Trim()
    Write-Host "[2b] proxy-alias avant : $proxyBefore"
    & wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- umount /srv/qdrant-e 2>&1 | Out-Null
    $gone = (& wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- stat -c '%s' /srv/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>&1 | Out-String).Trim()
    Write-Host "[2b] alias PID-1 apres umount manuel : $gone"
    $real2 = & wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- bash -c "echo $b64 | base64 -d | bash" 2>&1
    Write-Host "[2b] payload sur alias ABSENT : $real2"
    if ("$real2" -notmatch 'alias-ok:repare') { Write-Host "    FAIL : attendu alias-ok:repare"; $fail++ }
    $after2 = (& wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- stat -c '%s' /srv/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>&1 | Out-String).Trim()
    Write-Host "[2b] sentinel via alias apres reparation : $after2"
    if ($after2 -ne '285') { Write-Host "    FAIL : sentinel != 285"; $fail++ }
    $mi = & wsl.exe -d Ubuntu -u root -- nsenter -t 1 -m -- cat /proc/self/mountinfo 2>&1 | Select-String -Pattern 'qdrant-e|/srv'
    Write-Host "[2b] mountinfo PID-1 :"; $mi | ForEach-Object { Write-Host "      $(($_.Line -split ' - ')[0])" }
    $proxyAfter = (& wsl.exe -d Ubuntu -u root -- bash $probeSrvAlias 2>&1 | Out-String).Trim()
    Write-Host "[2b] proxy-alias apres : $proxyAfter"
    if ($proxyAfter -notmatch 'proxy-alias-ok') { Write-Host "    FAIL : alias proxy perdu"; $fail++ }
}

# --- 3) tests unitaires du code PS reel ---
$startMark = '$aliasVerdict = ""'
$endMark = '# --- Phase 5:'
$s = $text.IndexOf($startMark); $e = $text.IndexOf($endMark)
if ($s -lt 0 -or $e -lt 0) { Write-Host "[3] marqueurs de bloc INTROUVABLES"; exit 1 }
$block = $text.Substring($s, $e - $s)

function Log { param($msg, $lvl = 'INFO') $script:Logs += "[$lvl] $msg" }
$script:Mode = ''
$script:Calls = 0
function wsl.exe {
    # factice : simule wsl.exe selon $script:Mode ; ne lance AUCUN processus
    $script:Calls++
    $global:LASTEXITCODE = -1
    switch ($script:Mode) {
        'sain'    { $global:LASTEXITCODE = 0; 'alias-ok:sain' }
        'repare'  { $global:LASTEXITCODE = 0; 'alias-ok:repare' }
        'ko'      { $global:LASTEXITCODE = 0; 'alias-ko:0' }
        'sourd'   { }                                   # sortie vide, rc -1 (0x8007274c)
        'flaky'   { if ($script:Calls -eq 1) { } else { $global:LASTEXITCODE = 0; 'alias-ok:sain' } }
        'bruit'   { $global:LASTEXITCODE = -1; 'Une tentative de connexion a echoue'; ''; 'alias-ok:sain' }
    }
}
$Distro = 'Ubuntu'; $aliasPoint = '/srv/qdrant-e'; $MountPoint = '/mnt/qdrant-e'
$cases = @(
    @{ Mode = 'sain';   ExpCalls = 1; ExpLvl = 'OK';   ExpTxt = 'sain' },
    @{ Mode = 'repare'; ExpCalls = 1; ExpLvl = 'OK';   ExpTxt = 'repare' },
    @{ Mode = 'ko';     ExpCalls = 1; ExpLvl = 'ERR';  ExpTxt = 'NON VERIFIE' },
    @{ Mode = 'sourd';  ExpCalls = 3; ExpLvl = 'WARN'; ExpTxt = 'sonde sourde' },
    @{ Mode = 'flaky';  ExpCalls = 2; ExpLvl = 'OK';   ExpTxt = 'sain' },
    @{ Mode = 'bruit';  ExpCalls = 1; ExpLvl = 'OK';   ExpTxt = 'sain' }
)
foreach ($c in $cases) {
    $script:Mode = $c.Mode; $script:Calls = 0; $script:Logs = @()
    Invoke-Expression $block
    $last = $script:Logs | Select-Object -Last 1
    $ok = ($script:Calls -eq $c.ExpCalls) -and $last.StartsWith("[$($c.ExpLvl)]") -and ($last -like "*$($c.ExpTxt)*")
    Write-Host ("[3] cas {0,-7} appels={1} -> {2}" -f $c.Mode, $script:Calls, $last)
    if (-not $ok) { Write-Host "    FAIL (attendu appels=$($c.ExpCalls), [$($c.ExpLvl)] *$($c.ExpTxt)*)"; $fail++ }
}
# --- 4) Phase 4 : label illisible => AUCUN umount (code PS reel extrait) ---
$p4s = $text.IndexOf('$mountInfo = & wsl.exe'); $p4e = $text.IndexOf('if ($needMount) {')
if ($p4s -lt 0 -or $p4e -lt 0) { Write-Host "[4] marqueurs Phase 4 INTROUVABLES"; exit 1 }
$p4 = $text.Substring($p4s, $p4e - $p4s)
$Label = 'qdrant-e'
$script:Umount = 0
function wsl.exe {
    $a = ($args -join ' ')
    $global:LASTEXITCODE = 0
    if ($a -match 'findmnt') { '/dev/sdd' }
    elseif ($a -match 'blkid') { if ($script:Mode -eq 'vide') { '' } else { $script:Mode } }
    elseif ($a -match 'umount') { $script:Umount++; 'UMOUNT-EXECUTE' }
}
$p4cases = @(
    @{ Mode = 'qdrant-e'; ExpUmount = 0; ExpNeed = $false; ExpTxt = 'deja monte' },
    @{ Mode = 'vide';    ExpUmount = 0; ExpNeed = $false; ExpTxt = 'sonde sourde' },
    @{ Mode = 'autre';   ExpUmount = 1; ExpNeed = $true;  ExpTxt = 'umount + remount' }
)
foreach ($c in $p4cases) {
    $script:Mode = $c.Mode; $script:Umount = 0; $script:Logs = @()
    Invoke-Expression $p4
    $last = $script:Logs | Select-Object -Last 1
    $ok = ($script:Umount -eq $c.ExpUmount) -and ($needMount -eq $c.ExpNeed) -and ($last -like "*$($c.ExpTxt)*")
    Write-Host ("[4] label={0,-9} umount appele={1} needMount={2} -> {3}" -f "'$($c.Mode)'", $script:Umount, $needMount, $last)
    if (-not $ok) { Write-Host "    FAIL (attendu umount=$($c.ExpUmount), needMount=$($c.ExpNeed), *$($c.ExpTxt)*)"; $fail++ }
}
# --- 5) Phase 6 : decision de restart fail-closed (Maintenance #380) ---
# Code REEL extrait (bloc "Preuve par le chemin Docker"), docker.exe factice, aucun compose.
$p6s = $text.IndexOf('# --- Preuve par le chemin Docker')
$p6e = $text.IndexOf('# Force restart pour rafraichir bind-mount cache')
if ($p6s -lt 0 -or $p6e -lt 0) { Write-Host "[5] marqueurs Phase 6 INTROUVABLES"; exit 1 }
$p6 = $text.Substring($p6s, $p6e - $p6s) -replace '(?m)^(\s*)exit (\d+)\s*$', '$1throw "EXIT:$2"'
function NotifyEvent { param([int]$EventId, [string]$Type = 'ERROR', [string]$Message) }
function FailExit { param([int]$Code, [int]$EventId, [string]$Message) $script:Logs += "[ERROR] $Message"; throw "EXIT:$Code" }
function docker.exe {
    $a = ($args -join ' ')
    if ($a -match 'State.Running') {
        switch ($script:Mode) {
            'absent'     { $global:LASTEXITCODE = 1; 'Error: No such object: qdrant_production'; return }
            'stopped'    { $global:LASTEXITCODE = 0; 'false'; return }
            'bad-engine' { $global:LASTEXITCODE = 1; 'Cannot connect to the Docker daemon'; return }
            default      { $global:LASTEXITCODE = 0; 'true'; return }
        }
    }
    if ($a -match 'State.Health.Status') { $global:LASTEXITCODE = 0; 'healthy'; return }
    if ($a -match 'wc -l') {
        if ($script:Mode -eq 'bad-exec') { $global:LASTEXITCODE = 1; 'Error response from daemon: exec failed'; return }
        $global:LASTEXITCODE = 0; $script:Coll; return
    }
    $global:LASTEXITCODE = 0
}
$p6cases = @(
    @{ Id = 'C';  Mode = 'bad-engine'; Coll = ''; Alias = $false; Exit = 10; Note = 'moteur injoignable => refus, AUCUN compose' },
    @{ Id = 'D';  Mode = 'bad-exec';   Coll = ''; Alias = $false; Exit = 10; Note = 'healthy + docker exec en echec => refus, AUCUN compose' },
    @{ Id = 'D2'; Mode = 'bad-exec';   Coll = ''; Alias = $true;  Exit = 0;  Note = 'idem MAIS sentinel alias lu 285 => store prouve, exit 0 sans geste' },
    @{ Id = 'D3'; Mode = 'bad-exec';   Coll = ''; Alias = $false; Exit = 10; Note = 'idem sans preuve => exit 10' },
    @{ Id = 'F';  Mode = 'absent';     Coll = ''; Alias = $false; Exit = 0;  Note = 'conteneur supprime => compose up voulu (chemin restart atteint)' },
    @{ Id = 'F2'; Mode = 'stopped';    Coll = ''; Alias = $false; Exit = 0;  Note = 'conteneur arrete => compose up voulu' },
    @{ Id = 'G';  Mode = 'healthy';    Coll = '118'; Alias = $false; Exit = 0; Note = 'healthy + 118 collections => idempotent, exit 0' },
    @{ Id = 'H';  Mode = 'healthy';    Coll = '3';   Alias = $false; Exit = 0; Note = 'healthy + compteur LU 3 => preuve positive, recreate voulu' },
    @{ Id = 'I';  Mode = 'healthy';    Coll = '';    Alias = $false; Exit = 10; Note = 'compteur VIDE (aucun chiffre) => non mesure, refus' }
)
foreach ($c in $p6cases) {
    $script:Mode = $c.Mode; $script:Coll = $c.Coll; $script:Logs = @()
    $AliasVerified = $c.Alias
    $rc = 0; $err = ''
    try { & ([ScriptBlock]::Create($p6)) } catch { $err = $_.Exception.Message; if ($err -match '^EXIT:(\d+)$') { $rc = [int]$matches[1] } else { $rc = -99 } }
    $recreate = ($script:Logs -match 'compose up voulu|recreate voulu|preuve positive d.un mauvais store').Count -gt 0
    $expRecreate = $c.Id -match '^F|^H'
    $ok = ($rc -eq $c.Exit) -and ($recreate -eq $expRecreate)
    Write-Host ("[5] cas {0,-3} exit={1,3} recreate={2} -> {3} ({4})" -f $c.Id, $rc, $recreate, $(if ($ok) { 'PASS' } else { 'FAIL' }), $c.Note)
    if (-not $ok) { $fail++; Write-Host "    erreur: $err"; $script:Logs | ForEach-Object { Write-Host "      $_" } }
}
Write-Host "RESULTAT : $(if ($fail -eq 0) { 'TOUT PASS' } else { "$fail ECHEC(S)" })"
exit $fail
