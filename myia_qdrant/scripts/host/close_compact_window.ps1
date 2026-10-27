<#
.SYNOPSIS
    Cloture de la fenetre de compaction VHDX : re-arme les DEUX gardes + verifie les
    criteres d'acceptation (pas seulement le health).
.DESCRIPTION
    S'execute en tache planifiee repetee (toutes les 10 min) pendant la fenetre. Tant que la
    tache de compaction tourne, il ne fait RIEN (sortie 0, la repetition repartira).

    Quand la compaction est terminee :
      1) Re-armement des deux gardes dans l'etat AVANT fenetre (lu dans le state file ecrit
         par run_compact_window.ps1) : Verify-Qdrant-Mount ET Mount-Qdrant-VHDX.
         Le FINALLY du script deploye ne reactive QUE Verify -> d'ou ce backstop.
      2) Criteres d'acceptation STRICTS :
           - device resolu par LABEL 'qdrant-e' (jamais par lettre de peripherique)
           - montage /mnt/qdrant-e present dans le NAMESPACE PID-1
           - sentinelle anti-split-brain = 285 octets, lue dans le namespace PID-1
           - >= MinCollections collections
           - roo_tasks_semantic_index : status green, optimizer_status ok, points >= plancher
           - point-count AVANT/APRES compare (le vrai controle : une compaction qui 'reussit'
             mais ou le conteneur a reecrit sa raft_state ailleurs ne se voit pas au health)
           - taille du VHDX avant/apres (gain attendu)

    Sortie : 0 = tout OK | 3 = echec d'acceptation (gardes re-armes quand meme) | 1 = erreur.
    Le resultat est ecrit dans $StateFile (remplace par le bilan de cloture) et dans le log.

.PARAMETER StateFile
    Fichier JSON ecrit par run_compact_window.ps1 avant de desactiver les gardes.
.PARAMETER MinCollections
    Nombre minimal de collections attendu (defaut 117, etat mesure 26/10).
.PARAMETER MinPoints
    Plancher absolu de points roo_tasks (defaut 1 500 000, plancher du skill qdrant-sweep).
.PARAMETER CompactTask
    Nom de la tache de compaction a surveiller (defaut Compact-Qdrant-VHDX).
.PARAMETER CloseTask
    Nom de la tache de cloture (auto-suppression a la reussite) (defaut Compact-Qdrant-VHDX-Close).
.MACHINES
    myia-ai-01
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\ProgramData\maint-scripts\close_compact_window.ps1
#>
[CmdletBinding()]
param(
    [string]$StateFile     = "C:\ProgramData\maint-scripts\state\compact_window_state.json",
    [int]$MinCollections   = 117,
    [long]$MinPoints       = 1500000,
    [string]$CompactTask   = "Compact-Qdrant-VHDX",
    [string]$CloseTask     = "Compact-Qdrant-VHDX-Close"
)

$ErrorActionPreference = "Stop"
$logDir = "C:\ProgramData\maint-scripts\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "compact-closure-$(Get-Date -f yyyyMMdd-HHmmss).log"

function Log {
    param([string]$msg, [string]$lvl = "INFO", [string]$ForegroundColor = "Gray")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "HH:mm:ss"), $lvl, $msg
    Write-Host $line -ForegroundColor $ForegroundColor
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# --- Admin (Enable-ScheduledTask) ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p  = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "Privileges Admin requis (re-armement des gardes) -- relance en eleve." "ERROR"; exit 1
}

# ---------------------------------------------------------------------------
# 0) La compaction tourne-t-elle encore ? -> on ne touche à rien.
# ---------------------------------------------------------------------------
$compact = Get-ScheduledTask -TaskName $CompactTask -ErrorAction SilentlyContinue
if ($compact -and $compact.State -eq 'Running') {
    Log "Compaction encore en cours (etat=Running) -- on ne touche pas aux gardes, repetition reprogrammee."
    exit 0
}

# --- Lecture du state (etat avant fenetre) ---
$state = $null
if (Test-Path $StateFile) {
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { Log "State file illisible : $($_.Exception.Message)" "WARN" }
}

# La compaction n'a-t-elle jamais demarre depuis l'ouverture de la fenetre ?
# (tache enregistree mais pas declenchee : la fenetre n'est pas ouverte -> ne rien toucher)
if ($state -and ($state.PSObject.Properties.Name -contains 'startedAt') -and $compact) {
    try {
        $started = [datetime]::Parse($state.startedAt)
        $lastRun = $compact.LastRunTime
        if ($lastRun -and $lastRun.ToLocalTime() -lt $started) {
            Log "Compaction jamais declenchee depuis l'ouverture de la fenetre (LastRunTime=$lastRun < startedAt=$started) -- on ne touche a rien."
            exit 0
        }
    } catch { Log "Comparaison LastRunTime impossible : $($_.Exception.Message)" "WARN" }
}

# ---------------------------------------------------------------------------
# 1) Re-armement des DEUX gardes, dans l'etat d'avant fenetre
# ---------------------------------------------------------------------------
$guards = @(
    @{ Name = 'Verify-Qdrant-Mount';  WasEnabled = $true },
    @{ Name = 'Mount-Qdrant-VHDX';    WasEnabled = $true }
)
if ($state -and $state.PSObject.Properties.Name -contains 'guards') {
    foreach ($g in $state.guards) {
        foreach ($d in $guards) { if ($d.Name -eq $g.name) { $d.WasEnabled = [bool]$g.wasEnabled } }
    }
}
foreach ($g in $guards) {
    $t = Get-ScheduledTask -TaskName $g.Name -ErrorAction SilentlyContinue
    if (-not $t) { Log "Garde $($g.Name) : INTROUVABLE" "WARN"; continue }
    if ($g.WasEnabled) {
        if ($t.State -eq 'Disabled') {
            try { Enable-ScheduledTask -TaskName $g.Name | Out-Null; Log "Garde $($g.Name) : RE-ARMEE (etat avant fenetre = Enabled)" "OK" }
            catch { Log "Garde $($g.Name) : ECHEC re-armement : $($_.Exception.Message)" "ERROR" }
        } else { Log "Garde $($g.Name) : deja active (etat=$($t.State))" }
    } else {
        if ($t.State -ne 'Disabled') {
            try { Disable-ScheduledTask -TaskName $g.Name | Out-Null; Log "Garde $($g.Name) : laissee DESACTIVEE (etat avant fenetre = Disabled)" }
            catch { Log "Garde $($g.Name) : ECHEC deactivation : $($_.Exception.Message)" "WARN" }
        }
    }
}

# ---------------------------------------------------------------------------
# 2) Criteres d'acceptation
# ---------------------------------------------------------------------------
$checks = @()
function Add-Check { param([string]$Name, [bool]$Ok, [string]$Detail) $script:checks += [pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail } }

# 2a) Label + montage PID-1
$device = $null
$lsblk = (wsl.exe -u root -- lsblk -no LABEL,NAME 2>&1 | Out-String)
foreach ($line in ($lsblk -split "`r?`n")) {
    $p2 = ($line.Trim() -split '\s+')
    if ($p2.Count -ge 2 -and $p2[0] -eq 'qdrant-e') { $device = $p2[1]; break }
}
Add-Check "device resolu par LABEL qdrant-e" ([bool]$device) $(if ($device) { "device=$device" } else { "aucun device porte le label qdrant-e" })

$mountSrc = (wsl.exe -u root -- nsenter -t 1 -m -- findmnt -n -o SOURCE,TARGET /mnt/qdrant-e 2>&1 | Out-String).Trim()
$mountOk = ($mountSrc -match '/dev/sd' -and $mountSrc -match 'qdrant-e')
Add-Check "montage /mnt/qdrant-e dans le namespace PID-1" $mountOk "findmnt -> $(if($mountSrc){$mountSrc}else{'VIDE'})"

# 2b) Sentinelle anti-split-brain (285 o) lue dans PID-1
$sentinel = (wsl.exe -u root -- nsenter -t 1 -m -- stat -c %s /mnt/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>&1 | Out-String).Trim()
$sentinelOk = ($sentinel -eq '285')
Add-Check "sentinelle anti-split-brain = 285 o (PID-1)" $sentinelOk "stat = $(if($sentinel){$sentinel}else{'ABSENTE'})"

# 2c) API : collections + roo_tasks
$envFile = "D:\qdrant\myia_qdrant\.env.production"
$apiKey = $null
if (Test-Path $envFile) {
    $m = [regex]::Match((Get-Content $envFile -Raw), '(?m)^QDRANT__SERVICE__API_KEY=(.+)$')
    if ($m.Success) { $apiKey = $m.Groups[1].Value.Trim() }
}
$collections = $null; $roo = $null
if ($apiKey) {
    $H = @{ 'api-key' = $apiKey }
    try { $collections = Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $H -TimeoutSec 30 } catch { Log "API collections : $($_.Exception.Message)" "WARN" }
    try { $roo = Invoke-RestMethod -Uri "http://localhost:6333/collections/roo_tasks_semantic_index" -Headers $H -TimeoutSec 30 } catch { Log "API roo_tasks : $($_.Exception.Message)" "WARN" }
}
$nbColl = 0
if ($collections -and $collections.result) { $nbColl = @($collections.result.collections).Count }
Add-Check "collections >= $MinCollections" ($nbColl -ge $MinCollections) "count=$nbColl"

$status = ''; $opt = ''; $pts = 0
if ($roo -and $roo.result) {
    $status = [string]$roo.result.status
    $opt    = [string]$roo.result.optimizer_status
    $pts    = [long]$roo.result.points_count
}
Add-Check "roo_tasks status=green" ($status -eq 'green') "status=$status"
Add-Check "roo_tasks optimizer_status=ok" ($opt -eq 'ok') "optimizer_status=$opt"
Add-Check "roo_tasks points >= $MinPoints" ($pts -ge $MinPoints) "points=$pts"

# 2d) Point-count AVANT / APRES compare (le vrai controle de non-regression)
$ptsBefore = 0
if ($state -and $state.PSObject.Properties.Name -contains 'pointsBefore') { $ptsBefore = [long]$state.pointsBefore }
if ($ptsBefore -gt 0) {
    Add-Check "point-count non regresse (avant/apres)" ($pts -ge $ptsBefore) "avant=$ptsBefore apres=$pts"
} else {
    Add-Check "point-count avant/apres compare" $false "etat avant fenetre introuvable ($StateFile)"
}

# 2e) Gain de taille du VHDX (information, pas un critere bloquant si l'Optimize a ete saute)
$vhdx = "E:\wsl-data\qdrant.vhdx"
$vhdxAfter = 0
if (Test-Path $vhdx) { $vhdxAfter = [math]::Round((Get-Item $vhdx).Length / 1GB, 1) }
$vhdxBefore = 0
if ($state -and $state.PSObject.Properties.Name -contains 'vhdxBeforeGB') { $vhdxBefore = [double]$state.vhdxBeforeGB }
Log "vhdx : $(if($vhdxBefore){$vhdxBefore}else{'?'}) GB -> $vhdxAfter GB"

# ---------------------------------------------------------------------------
# 3) Bilan
# ---------------------------------------------------------------------------
$failed = @($checks | Where-Object { -not $_.ok })
Log "=== BILAN CLOTURE ===" "OK"
foreach ($c in $checks) { Log ("  {0} {1} : {2}" -f $(if($c.ok) {'[OK]'}else{'[ECHEC]'}), $c.name, $c.detail) -ForegroundColor $(if($c.ok){'Green'}else{'Red'}) }

$result = [pscustomobject]@{
    closedAt       = (Get-Date).ToString('s')
    ok             = ($failed.Count -eq 0)
    failedCount    = $failed.Count
    checks         = $checks
    pointsBefore   = $ptsBefore
    pointsAfter    = $pts
    collections    = $nbColl
    vhdxBeforeGB   = $vhdxBefore
    vhdxAfterGB    = $vhdxAfter
    logFile        = $logFile
}
try {
    $stateDir = Split-Path $StateFile -Parent
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
    Log "Bilan ecrit : $StateFile" "OK"
} catch { Log "Ecriture du bilan impossible : $($_.Exception.Message)" "ERROR" }

# Auto-suppression de la tache de cloture : uniquement si TOUT est OK.
# En cas d'echec, elle reste active (repetition 10 min) pour re-controler et tenter un
# re-armement des gardes a chaque passage -- les gardes sont deja re-armes ci-dessus.
if ($failed.Count -eq 0) {
    try {
        Unregister-ScheduledTask -TaskName $CloseTask -Confirm:$false -ErrorAction Stop
        Log "Tache de cloture '$CloseTask' supprimee (auto) -- fenetre close." "OK"
    } catch { Log "Auto-suppression de '$CloseTask' impossible (benign) : $($_.Exception.Message)" "WARN" }
} else {
    Log "Tache de cloture '$CloseTask' MAINTENUE (re-check toutes les 10 min jusqu'a la fin de la repetition)." "WARN"
}

if ($failed.Count -gt 0) { Log "CLOTURE EN ECHEC : $($failed.Count) critere(s) non satisfaits -- a investiguer." "ERROR"; exit 3 }
Log "CLOTURE OK : tous les criteres sont satisfaits." "OK"
exit 0
