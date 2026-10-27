<#
.SYNOPSIS
    Lanceur de la fenetre de compaction VHDX (v2, 2026-10-26) : enregistre + declenche la
    tache one-shot 'Compact-Qdrant-VHDX' pointant sur les scripts DEPLOYES.
.DESCRIPTION
    Pourquoi une v2 (remplace run_compact_via_task.ps1 de la branche host-mount-scripts-20260528) :
      - la v1 DEPLOYAIT compact/mount/recover depuis le repo vers C:\ProgramData\maint-scripts :
        elle aurait ecrase mount_qdrant_vhdx.ps1 deploye (21/09, durci) par la version de branche
        (pre-pathfix). DOWNGRADE INTERDIT : la v2 ne deploie RIEN, elle pointe sur les copies
        deployees, seules verites actives (compact 20/06 qdrant-only + mount 21/09 + recover 07/06).
      - la v1 decrivait le flux a gates "QUITTE DOCKER / RELANCE DOCKER" (compact 7-phases de
        branche). Le compact DEPLOYE (20/06) est qdrant-only : Docker Desktop et les autres
        conteneurs restent up, aucune action tray user, pas de gate. Impact fenetre = chemin
        semantique seul.

    Ce que fait cette v2 (operations instantanees, robustes en self-eleve) :
      1) Self-elevation UAC (une seule popup).
      2) (Re)cree la tache one-shot 'Compact-Qdrant-VHDX' :
            principal = user courant / Interactive / Highest (calque Mount-Qdrant-VHDX)
            action    = powershell -File C:\ProgramData\maint-scripts\compact_qdrant_vhdx.ps1
                        -OptimizeMode <mode> [-SkipOptimize si -DryRun]
            limite    = PT4H (qdrant-only : fstrim + Optimize Full 703 GB + remount + cold start)
            pas de trigger -> declenchee via Start-ScheduledTask (ou schtasks /run, non-eleve,
            meme pattern que la remediation quotidienne Verify->Mount).
      3) Sauve l'etat AVANT fenetre (etat des deux gardes, point-count roo_tasks, taille VHDX)
         dans C:\ProgramData\maint-scripts\state\compact_window_state.json.
      4) SUSPEND LES DEUX gardes (Verify-Qdrant-Mount ET Mount-Qdrant-VHDX) : le script
         deploye (20/06) ne desactive que Verify et ATTEND la fin d'une instance Mount en
         cours -- si elle tire pendant le detach, elle peut remonter le VHDX au mauvais moment.
      5) Enregistre la tache de CLOTURE 'Compact-Qdrant-VHDX-Close' (repetition 10 min, 8 h)
         -> close_compact_window.ps1 : re-arme les deux gardes dans leur etat d'avant fenetre
         et verifie les CRITERES D'ACCEPTATION (device par LABEL, sentinelle 285 o en PID-1,
         >= 117 collections, roo_tasks green + optimizer ok, point-count avant/apres compare).
         Elle ne fait RIEN tant que la compaction tourne.
      6) Sauf -RegisterOnly : declenche la tache et affiche le log a suivre.

    Fenetre type (qdrant-only, ~1-2,5 h) : arret watchdog + autoheal + qdrant_prod, fstrim
    (GO/NO-GO), clear shims qdrant_data, umount PID-1, wsl --unmount, Dismount-VHD,
    Mount-RO + Optimize-VHD -Mode Full, puis FINALLY TOUJOURS : remontage via le script
    deploye, autoheal, re-enable watchdog, bilan. Backstop si mort avant le finally :
    C:\ProgramData\maint-scripts\recover_mount_after_compact.ps1 puis Enable-ScheduledTask
    -TaskName Verify-Qdrant-Mount.

    A EVITER pendant la fenetre : le creneau backup 03:17-03:45 (Qdrant-Snapshot-Daily).
    Filet : snapshot GDrive quotidien + sentinelle anti-split-brain (le conteneur refuse de
    servir un store vide) + garde label qdrant-e (exit 6) dans le script de remontage.

.PARAMETER DryRun
    Passe -SkipOptimize au compact deploye : valide toute la sequence demontage/remontage
    SANS l'Optimize (fenetre ~15 min au lieu de 1-2,5 h).
.PARAMETER OptimizeMode
    Full (defaut) | Quick | Retrim.
.PARAMETER RegisterOnly
    Prepare la tache sans la declencher (le declenchement se fait ensuite non-eleve via
    schtasks /run /tn "Compact-Qdrant-VHDX").
.PARAMETER TimeLimitHours
    Limite d'execution de la tache (defaut 4).
.REQUIRES
    Admin (Register-ScheduledTask RunLevel Highest). Self-elevation incluse (1 UAC).
.MACHINES
    myia-ai-01
.EXAMPLE
    # Jour J - fenetre complete (1 UAC) :
    powershell -ExecutionPolicy Bypass -File C:\ProgramData\maint-scripts\run_compact_window.ps1
.EXAMPLE
    # Preparer sans lancer, puis declencher non-eleve :
    powershell -ExecutionPolicy Bypass -File .\run_compact_window.ps1 -RegisterOnly
    schtasks /run /tn "Compact-Qdrant-VHDX"
.NOTES
    Cree 2026-10-26 (lane myia-ai-01:qdrant). Contexte : VHDX 702,9 GB / 200 GB utilises,
    ~500 GB recuperables ; vague d'ingest +756 k pts 25-26/10.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet("Full","Quick","Retrim")]
    [string]$OptimizeMode = "Full",
    [switch]$RegisterOnly,
    [int]$TimeLimitHours = 4,
    [switch]$SelfTest
)

# --- Mode -SelfTest : validation SANS admin et SANS AUCUN effet de bord ---
#     (regle UAC 2a : la chaine entiere doit echouer sur la SEULE privilege ; on verifie
#      d'abord la syntaxe et la presence des fichiers pour ne pas consommer la fenetre UAC
#      sur un script qui ne demarre pas.)
if ($SelfTest) {
    Write-Host "=== SELF-TEST du lanceur de fenetre de compaction (aucune modif) ===" -ForegroundColor Cyan
    $candidates = @(
        @{ Label = 'lanceur (ce fichier)'; Path = $PSCommandPath },
        @{ Label = 'compact deploye';      Path = 'C:\ProgramData\maint-scripts\compact_qdrant_vhdx.ps1' },
        @{ Label = 'mount deploye';        Path = 'C:\ProgramData\maint-scripts\mount_qdrant_vhdx.ps1' },
        @{ Label = 'recover deploye';      Path = 'C:\ProgramData\maint-scripts\recover_mount_after_compact.ps1' },
        @{ Label = 'cloture (repo)';       Path = (Join-Path $PSScriptRoot 'close_compact_window.ps1') }
    )
    $errors = 0
    foreach ($c in $candidates) {
        if (-not (Test-Path $c.Path)) { Write-Host ("  [ABSENT ] {0} : {1}" -f $c.Label, $c.Path) -ForegroundColor Red; $errors++; continue }
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($c.Path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Write-Host ("  [SYNTAXE] {0} : {1}" -f $c.Label, $c.Path) -ForegroundColor Red
            foreach ($e in $parseErrors) { Write-Host ("      ligne {0} : {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
            $errors++
        } else {
            Write-Host ("  [OK     ] {0} : {1}" -f $c.Label, $c.Path) -ForegroundColor Green
        }
    }
    Write-Host ""
    Write-Host ("  action compacter  : powershell.exe -File C:\ProgramData\maint-scripts\compact_qdrant_vhdx.ps1 -OptimizeMode {0}{1}" -f $OptimizeMode, $(if ($DryRun) {' -SkipOptimize'} else {''})) -ForegroundColor DarkGray
    Write-Host ("  gardes a suspendre : Verify-Qdrant-Mount + Mount-Qdrant-VHDX (re-armes a la cloture)") -ForegroundColor DarkGray
    Write-Host ("  tache de cloture  : Compact-Qdrant-VHDX-Close (repetition 10 min) -> close_compact_window.ps1") -ForegroundColor DarkGray
    Write-Host ("  limite tache      : PT{0}H" -f $TimeLimitHours) -ForegroundColor DarkGray
    if ($errors -gt 0) { Write-Host "SELF-TEST EN ECHEC : $errors probleme(s)." -ForegroundColor Red; exit 1 }
    Write-Host "SELF-TEST OK." -ForegroundColor Green
    exit 0
}

# --- Self-elevation (UAC) : ops instantanees seulement (register + trigger) ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ELEVATION] Privileges Admin requis -- relance avec UAC..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"",
                 '-OptimizeMode', $OptimizeMode, '-TimeLimitHours', $TimeLimitHours)
    if ($DryRun)       { $argList += '-DryRun' }
    if ($RegisterOnly) { $argList += '-RegisterOnly' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

$ErrorActionPreference = "Stop"
$TaskName   = 'Compact-Qdrant-VHDX'
$CloseTaskName = 'Compact-Qdrant-VHDX-Close'
$deployDir  = 'C:\ProgramData\maint-scripts'
$compactLive = Join-Path $deployDir 'compact_qdrant_vhdx.ps1'

foreach ($f in @($compactLive, (Join-Path $deployDir 'mount_qdrant_vhdx.ps1'), (Join-Path $deployDir 'recover_mount_after_compact.ps1'))) {
    if (-not (Test-Path $f)) { throw "Script deploye manquant (ne rien deployer depuis le repo) : $f" }
}

$actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$compactLive`" -OptimizeMode $OptimizeMode"
if ($DryRun) { $actionArgs += ' -SkipOptimize' }

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
$principal = New-ScheduledTaskPrincipal -UserId $id.Name -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours $TimeLimitHours) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$task      = New-ScheduledTask -Action $action -Principal $principal -Settings $settings `
                -Description "One-shot compaction VHDX qdrant (qdrant-only downtime). Lanceur v2 2026-10-26, NE DEPLOYE RIEN (scripts ProgramData)."

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
Write-Host "Tache '$TaskName' (re)creee." -ForegroundColor Green
Write-Host "  action : powershell.exe $actionArgs" -ForegroundColor DarkGray
Write-Host ("  mode   : {0}{1} | limite PT{2}H | {3}/Interactive/Highest" -f $OptimizeMode, $(if ($DryRun) {' (-SkipOptimize)'} else {''}), $TimeLimitHours, $id.Name) -ForegroundColor DarkGray

if ($RegisterOnly) {
    Write-Host ""
    Write-Host "-RegisterOnly : tache PREPAREE, NON declenchee." -ForegroundColor Cyan
    Write-Host "Declenchement non-eleve (pattern watchdog) :  schtasks /run /tn `"$TaskName`"" -ForegroundColor Cyan
    Write-Host "ATTENTION : les gardes ne sont suspendus et la tache de cloture n'est enregistree qu'AU DECLENCHEMENT." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Suspension des DEUX gardes + etat AVANT fenetre + tache de cloture.
# (Ordre : on prepare tout AVANT de declencher, sinon la fenetre ouvre avec un garde actif.)
# ---------------------------------------------------------------------------
$stateDir  = Join-Path $deployDir 'state'
$stateFile = Join-Path $stateDir 'compact_window_state.json'
$closeLive = Join-Path $deployDir 'close_compact_window.ps1'

# Le script de cloture est le SEUL fichier deploye par ce lanceur (nouveau fichier).
# compact/mount/recover deployes ne sont JAMAIS ecrases (interdit de downgrade).
if ($PSScriptRoot -ne $deployDir) {
    Copy-Item -Path (Join-Path $PSScriptRoot 'close_compact_window.ps1') -Destination $closeLive -Force
}
if (-not (Test-Path $closeLive)) { throw "Script de cloture deploye manquant : $closeLive" }

# Etat avant fenetre
$guardsState = @()
foreach ($n in @('Verify-Qdrant-Mount','Mount-Qdrant-VHDX')) {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    $guardsState += [pscustomobject]@{ name = $n; wasEnabled = [bool]($t -and $t.State -ne 'Disabled') }
}
$pointsBefore = 0
try {
    $envFile = 'D:\qdrant\myia_qdrant\.env.production'
    if (Test-Path $envFile) {
        $m = [regex]::Match((Get-Content $envFile -Raw), '(?m)^QDRANT__SERVICE__API_KEY=(.+)$')
        if ($m.Success) {
            $r = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' `
                                   -Headers @{ 'api-key' = $m.Groups[1].Value.Trim() } -TimeoutSec 30
            $pointsBefore = [long]$r.result.points_count
        }
    }
} catch { Write-Host "  (point-count avant fenetre non lu : $($_.Exception.Message))" -ForegroundColor Yellow }
$vhdxBeforeGB = 0
if (Test-Path 'E:\wsl-data\qdrant.vhdx') { $vhdxBeforeGB = [math]::Round((Get-Item 'E:\wsl-data\qdrant.vhdx').Length / 1GB, 1) }

if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
[pscustomobject]@{
    startedAt    = (Get-Date).ToString('s')
    mode         = $OptimizeMode
    dryRun       = [bool]$DryRun
    guards       = $guardsState
    pointsBefore = $pointsBefore
    vhdxBeforeGB = $vhdxBeforeGB
} | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8

foreach ($g in $guardsState) {
    Disable-ScheduledTask -TaskName $g.name -ErrorAction Stop | Out-Null
    Write-Host "  garde SUSPENDUE : $($g.name) (etat avant = enabled=$($g.wasEnabled))" -ForegroundColor Yellow
}

# Tache de cloture : re-arme les 2 gardes + verifie les criteres d'acceptation.
# Repetee toutes les 10 min : elle ne fait RIEN tant que la compaction tourne.
$closeAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$closeLive`""
$closeTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                -RepetitionInterval (New-TimeSpan -Minutes 10) `
                -RepetitionDuration (New-TimeSpan -Hours 8)
$closeSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$closeTask = New-ScheduledTask -Action $closeAction -Trigger $closeTrigger -Principal $principal -Settings $closeSettings `
                -Description "Cloture fenetre compaction : re-armement des DEUX gardes + criteres d'acceptation (label, sentinelle, collections, points avant/apres)."
Register-ScheduledTask -TaskName $CloseTaskName -InputObject $closeTask -Force | Out-Null
Write-Host "  tache de cloture enregistree : $CloseTaskName (repetition 10 min, 8 h)" -ForegroundColor Cyan
Write-Host "  etat avant fenetre ecrit : $stateFile" -ForegroundColor DarkGray

Start-ScheduledTask -TaskName $TaskName
Write-Host ""
Write-Host "Tache DECLENCHEE (detachee sous Task Scheduler)." -ForegroundColor Green
Write-Host "Log : $deployDir\logs\compact-qdrant-vhdx-<timestamp>.log" -ForegroundColor Cyan
Write-Host "Suivi : Get-Content (Get-ChildItem '$deployDir\logs\compact-qdrant-vhdx-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Wait -Tail 40" -ForegroundColor Cyan
Write-Host "Cloture : $deployDir\logs\compact-closure-<timestamp>.log + $stateFile" -ForegroundColor Cyan
Write-Host "Backstop si interruption : recover_mount_after_compact.ps1 + Enable-ScheduledTask Verify-Qdrant-Mount + Enable-ScheduledTask Mount-Qdrant-VHDX" -ForegroundColor Yellow
exit 0
