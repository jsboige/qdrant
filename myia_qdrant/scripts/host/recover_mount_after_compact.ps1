<#
.SYNOPSIS
    Recuperation one-shot apres une compaction VHDX avortee.
.DESCRIPTION
    Si compact_qdrant_vhdx.ps1 meurt AVANT son finally (Phase 7) -- p.ex. le process eleve
    enfant d'une session d'agent qui se fait tuer en plein GATE (incident 2026-06-07) --
    deux choses restent dans un mauvais etat :
      - les schtasks watchdog (Verify-Qdrant-Mount + Mount-Qdrant-VHDX) restent DISABLED
        (Phase 1 les a desactives, le finally Phase 7 ne les a jamais reactivees) ;
      - qdrant est down (compose down de la Phase 2 a tourne).

    Ce script re-active le watchdog et declenche la remediation canonique Mount-Qdrant-VHDX,
    qui tourne DETACHEE sous le service Task Scheduler (re-mount idempotent + verify + compose up).
    Le re-attach n'est PAS fait en ligne ici : on delegue a la tache detachee (robuste).

    Note : si le VHDX a deja ete detache (Phase 4 atteinte) mais Docker tourne encore avec
    des binds, NE PAS Dismount a l'aveugle -- Mount-Qdrant-VHDX gere le re-mount idempotent
    depuis l'etat attache OU detache.
.REQUIRES
    Admin (*-ScheduledTask). Lancer depuis une console elevee, ou via la tache si besoin.
.MACHINES
    myia-ai-01
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File D:\qdrant\myia_qdrant\scripts\host\recover_mount_after_compact.ps1
.NOTES
    Cree le 2026-06-07 (apres le dry-run compaction avorte). Copie live : C:\ProgramData\maint-scripts\.
#>
$ErrorActionPreference = 'Continue'
Enable-ScheduledTask -TaskName 'Verify-Qdrant-Mount' | Out-Null
Enable-ScheduledTask -TaskName 'Mount-Qdrant-VHDX'   | Out-Null
Start-ScheduledTask  -TaskName 'Mount-Qdrant-VHDX'
Write-Host 'recovery-triggered: watchdog re-enabled (Verify + Mount) + Mount-Qdrant-VHDX started (detache)'
Write-Host 'Suivre : C:\ProgramData\maint-scripts\logs\mount-qdrant-vhdx-*.log'
