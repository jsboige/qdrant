# Host-side maintenance scripts (Windows)

These scripts run on the Windows host (not inside the qdrant container) and own the lifecycle of the VHDX mount that backs qdrant_production's storage. Per the project-level `CLAUDE.md` mandate ("`myia_qdrant/` IS the canonical home for Qdrant-specific tooling on this machine"), they are versioned here.

## Layout

| Script | Purpose | Scheduled task | RunLevel |
|--------|---------|----------------|----------|
| `mount_qdrant_vhdx.ps1` | Mount E:\wsl-data\qdrant.vhdx into WSL Ubuntu (`/mnt/qdrant-e`) via Hyper-V + `wsl --mount` + PID-1 nsenter + `make-shared` + compose recreate. Idempotent. | `Mount-Qdrant-VHDX` (onlogon) | Highest |
| `verify_qdrant_mount.ps1` | Watchdog. Read-only checks for mount drift, wrong label, container down, device mismatch. With `-Remediate`, triggers `Mount-Qdrant-VHDX` via `schtasks /run`. | `Verify-Qdrant-Mount` (every 2 min, `-Remediate`) | Limited (no UAC) |

## Deployment

Scripts are deployed to `C:\ProgramData\maint-scripts\` on each MYIA host. The path is intentionally machine-local — these are not invoked from inside the fork tree; they're invoked by Task Scheduler / boot-time, so they need to live somewhere `schtasks` can reach with predictable permissions.

```powershell
# Deploy from the fork to the machine-local path (requires admin)
Copy-Item -Force d:\qdrant\myia_qdrant\scripts\host\mount_qdrant_vhdx.ps1   C:\ProgramData\maint-scripts\
Copy-Item -Force d:\qdrant\myia_qdrant\scripts\host\verify_qdrant_mount.ps1 C:\ProgramData\maint-scripts\
```

## Exit codes (verify_qdrant_mount.ps1)

| Code | Status | Remediate-eligible? |
|------|--------|---------------------|
| 0 | OK | n/a |
| 1 | mountpoint absent | YES |
| 2 | mounted on wrong-label device | YES |
| 3 | container sees < MinCollections | YES |
| 4 | container device != Ubuntu mount device | YES |
| 9 | container down (REMOVED/stopped) with mount OK | YES (since 2026-05-28) |
| 124 | self-timeout (force-exit on hung wsl/docker) | n/a |

## History

- **2026-04-27** — created post VHDX migration.
- **2026-05-04** — Phase 4 fstab + Phase 6 UNC probe (postmortem 5e hang Docker).
- **2026-05-17/18** — `-Remediate` added (closing the loop after 25h silent split-brain).
- **2026-05-24** — Phase 5 device-by-label check + selective shim clearing (post-GPU-crash drift). Watchdog self-timeout (`.NET` thread force-exit) after a hung wsl/docker call wedged the chain for hours under `ExecutionTimeLimit=PT72H`.
- **2026-05-28** — (this PR) Phase 6 `ubuntu.sock` socket probe + retry-with-backoff on `compose up`; watchdog `TryRemediate` accepts exit 9 (container REMOVED). Root cause: 2 hard crashes Windows in 8h → on reboot, Docker bind-mount service (`/run/guest-services/distro-services/ubuntu.sock`) comes up later than the plan9 UNC proxy → `compose up` failed with "stat ubuntu.sock: no such file or directory" → container REMOVED → watchdog WARN'd code 9 indefinitely (not eligible for remediation) → human intervention required.

## Task Scheduler settings

Both tasks should have `ExecutionTimeLimit=PT90S` (NOT the schtasks default `PT72H`). A hang under `PT72H` + `MultipleInstances=IgnoreNew` blocks every subsequent trigger. To set (elevated shell, once per machine):

```powershell
foreach ($n in 'Mount-Qdrant-VHDX','Verify-Qdrant-Mount') {
    $t = Get-ScheduledTask $n
    $t.Settings.ExecutionTimeLimit = 'PT90S'
    Set-ScheduledTask -TaskName $n -Settings $t.Settings
}
```
