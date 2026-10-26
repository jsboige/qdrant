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
      3) Sauf -RegisterOnly : declenche la tache et affiche le log a suivre.

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
    [int]$TimeLimitHours = 4
)

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
    exit 0
}

Start-ScheduledTask -TaskName $TaskName
Write-Host ""
Write-Host "Tache DECLENCHEE (detachee sous Task Scheduler)." -ForegroundColor Green
Write-Host "Log : $deployDir\logs\compact-qdrant-vhdx-<timestamp>.log" -ForegroundColor Cyan
Write-Host "Suivi : Get-Content (Get-ChildItem '$deployDir\logs\compact-qdrant-vhdx-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Wait -Tail 40" -ForegroundColor Cyan
Write-Host "Backstop si interruption : recover_mount_after_compact.ps1 + Enable-ScheduledTask Verify-Qdrant-Mount" -ForegroundColor Yellow
exit 0
