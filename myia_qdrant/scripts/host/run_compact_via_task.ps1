<#
.SYNOPSIS
    Lanceur ROBUSTE de la compaction VHDX via une tache planifiee detachee (one-shot).
.DESCRIPTION
    Pourquoi ce lanceur existe (lecon 2026-06-07) :
      Lancer compact_qdrant_vhdx.ps1 via `Start-Process -Verb RunAs` depuis la session
      d'un agent (outil) n'est PAS robuste pour une op longue : le process eleve, enfant
      de la session, est mort 2x en plein GATE 1 (attente "Docker down"). qdrant s'est
      retrouve down, watchdog desactive (le finally Phase 7 n'a jamais tourne).

      La correction : executer la compaction comme une TACHE PLANIFIEE detachee, sous le
      service Task Scheduler -- exactement comme Mount-Qdrant-VHDX qui, lui, tourne
      parfaitement en detache (remediation mount le 2026-06-07). La tache survit a la
      session de l'agent et aux fermetures de fenetre ; elle ne meurt pas en plein wait.

    Ce que fait ce lanceur (operations INSTANTANEES uniquement -> robuste meme en self-eleve) :
      1) Self-elevation UAC (une seule popup, ops instantanees).
      2) Deploie les scripts a jour vers C:\ProgramData\maint-scripts\ (copie stable,
         decouplee de l'arbre git / du checkout -- comme Mount-Qdrant-VHDX).
      3) (Re)cree la tache one-shot 'Compact-Qdrant-VHDX' :
            principal = MYIA / Interactive / Highest   (calque sur Mount-Qdrant-VHDX,
              Interactive car le user agit sur le tray Docker + docker CLI = contexte user)
            action    = powershell ... -File ...\compact_qdrant_vhdx.ps1 [-SkipOptimize] -OptimizeMode <mode>
            limite    = PT8H (Optimize Full d'un VHDX ~877 GB + 2 gates de 15 min)
            pas de trigger -> declenchee a la demande via Start-ScheduledTask.
      4) Sauf -RegisterOnly : declenche la tache (Start-ScheduledTask) et affiche le log a suivre.

    DEROULEMENT cote operateur (jour J) :
      - Lancer ce script (1 UAC). La compaction demarre detachee.
      - Suivre le log indique. Quand le log dit ">>> QUITTE DOCKER DESKTOP" : quitter Docker
        via le tray (Quit Docker Desktop). Le script detecte l'arret et continue offline.
      - Quand le log dit ">>> RELANCE DOCKER DESKTOP" : relancer Docker. Le script re-attache
        le VHDX, remonte, et valide (72 collections + roo_tasks green).
      - Le watchdog est re-active dans tous les cas (finally Phase 7).

.PARAMETER DryRun
    Passe -SkipOptimize au script de compaction : teste tout le demontage/remontage SANS
    l'Optimize lui-meme (validation a blanc de la sequence + des gates).
.PARAMETER OptimizeMode
    Full (defaut, recupere tout le slack) | Quick | Retrim.
.PARAMETER RegisterOnly
    (Re)cree la tache mais NE la declenche PAS. Pour preparer sans lancer.
.REQUIRES
    Admin (Register-ScheduledTask / deploiement ProgramData). Self-elevation incluse.
.MACHINES
    myia-ai-01
.EXAMPLE
    # Jour J -- compaction complete, detachee, robuste :
    powershell -ExecutionPolicy Bypass -File D:\qdrant\myia_qdrant\scripts\host\run_compact_via_task.ps1
.EXAMPLE
    # Validation a blanc (demontage/remontage sans Optimize) :
    powershell -ExecutionPolicy Bypass -File D:\qdrant\myia_qdrant\scripts\host\run_compact_via_task.ps1 -DryRun
.EXAMPLE
    # Preparer la tache sans la lancer :
    powershell -ExecutionPolicy Bypass -File D:\qdrant\myia_qdrant\scripts\host\run_compact_via_task.ps1 -RegisterOnly
.NOTES
    Cree le 2026-06-07. Remplace le lancement Start-Process -Verb RunAs (fragile) par une
    tache planifiee detachee. Voir compact_qdrant_vhdx.ps1 pour la sequence reelle.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet("Full","Quick","Retrim")]
    [string]$OptimizeMode = "Full",
    [switch]$RegisterOnly
)

# ---------------------------------------------------------------------------
# Self-elevation (UAC) -- ops instantanees seulement (deploy + register + trigger)
# ---------------------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ELEVATION] Privileges Admin requis -- relance avec UAC..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"",
                 '-OptimizeMode', $OptimizeMode)
    if ($DryRun)       { $argList += '-DryRun' }
    if ($RegisterOnly) { $argList += '-RegisterOnly' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

$ErrorActionPreference = "Stop"
$TaskName  = 'Compact-Qdrant-VHDX'
$repoHost  = Split-Path $PSCommandPath -Parent                 # ...\myia_qdrant\scripts\host
$deployDir = 'C:\ProgramData\maint-scripts'
if (-not (Test-Path $deployDir)) { New-Item -ItemType Directory -Path $deployDir -Force | Out-Null }

function Say { param([string]$m,[string]$c='Gray') Write-Host $m -ForegroundColor $c }

# ---------------------------------------------------------------------------
# 1) Deploiement des scripts a jour vers ProgramData (stable, decouple du checkout)
# ---------------------------------------------------------------------------
$toDeploy = @('compact_qdrant_vhdx.ps1','mount_qdrant_vhdx.ps1','recover_mount_after_compact.ps1')
foreach ($f in $toDeploy) {
    $src = Join-Path $repoHost $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $deployDir $f) -Force
        Say "  deploye: $f -> $deployDir" 'DarkGray'
    } else {
        Say "  (absent du repo, non deploye): $f" 'Yellow'
    }
}
$compactLive = Join-Path $deployDir 'compact_qdrant_vhdx.ps1'
$mountLive   = Join-Path $deployDir 'mount_qdrant_vhdx.ps1'
if (-not (Test-Path $compactLive)) { throw "compact_qdrant_vhdx.ps1 introuvable apres deploiement: $compactLive" }

# ---------------------------------------------------------------------------
# 2) (Re)creation de la tache one-shot 'Compact-Qdrant-VHDX'
#    Principal calque sur Mount-Qdrant-VHDX : MYIA / Interactive / Highest.
#    Le script de compaction pointe sur les copies ProgramData (MountScript) pour
#    rester independant de l'arbre git pendant la fenetre de maintenance.
# ---------------------------------------------------------------------------
$actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$compactLive`" -OptimizeMode $OptimizeMode -MountScript `"$mountLive`""
if ($DryRun) { $actionArgs += ' -SkipOptimize' }

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$task      = New-ScheduledTask -Action $action -Principal $principal -Settings $settings `
                -Description "One-shot OFFLINE compaction de E:\wsl-data\qdrant.vhdx (detachee, robuste). Cree par run_compact_via_task.ps1."

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
Say "Tache '$TaskName' (re)creee." 'Green'
Say ("  action : powershell.exe {0}" -f $actionArgs) 'DarkGray'
Say ("  mode   : {0}{1} | limite PT8H | MYIA/Interactive/Highest" -f $OptimizeMode, $(if($DryRun){' (DryRun/-SkipOptimize)'}else{''})) 'DarkGray'

# ---------------------------------------------------------------------------
# 3) Declenchement (sauf -RegisterOnly)
# ---------------------------------------------------------------------------
if ($RegisterOnly) {
    Say "`n-RegisterOnly : tache PREPAREE, NON declenchee." 'Cyan'
    Say "Pour lancer le jour J :  Start-ScheduledTask -TaskName '$TaskName'" 'Cyan'
    Say "                  ou :  schtasks /run /tn `"$TaskName`"" 'Cyan'
    exit 0
}

Start-ScheduledTask -TaskName $TaskName
Say "`nTache DECLENCHEE (detachee sous le service Task Scheduler)." 'Green'
Say "Le dernier log apparaitra dans : $deployDir\logs\compact-qdrant-vhdx-*.log" 'Cyan'
Say "Suivre :  Get-Content (Get-ChildItem '$deployDir\logs\compact-qdrant-vhdx-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Wait -Tail 40" 'Cyan'
Say "`nRAPPEL operateur :" 'Yellow'
Say "  - quand le log dit >>> QUITTE DOCKER  : Quit Docker Desktop (tray)" 'Yellow'
Say "  - quand le log dit >>> RELANCE DOCKER : relancer Docker Desktop" 'Yellow'
exit 0
