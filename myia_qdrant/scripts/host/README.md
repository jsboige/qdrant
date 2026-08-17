# Host-side VHDX mount + watchdog scripts

These are **host-side PowerShell scripts** (they run on the Windows host, not inside a
container) that keep `qdrant_production`'s VHDX storage mounted and self-healing.

**Source of truth = the deployed copies at `C:\ProgramData\maint-scripts\`** (referenced by
the scheduled tasks). This directory **mirrors them for version control** — captured from the
live deployed scripts on 2026-07-16. To change behavior: edit here, then redeploy the file to
`C:\ProgramData\maint-scripts\` (the schtasks read from there, not from the repo).

## Scripts

| Script | schtask | Trigger / cadence | RunLevel |
|--------|---------|-------------------|----------|
| `verify_qdrant_mount.ps1` | `Verify-Qdrant-Mount` | every 2 min, `-Remediate` | Limited |
| `mount_qdrant_vhdx.ps1` | `Mount-Qdrant-VHDX` | on-demand, fired by the watchdog | Highest |
| `embedding_watchdog.ps1` | `Watchdog-Embedding-API` | every 5 min, alert-only | Limited |

### `verify_qdrant_mount.ps1` — the watchdog (read-only + optional remediation)
Read-only health probe. With `-Remediate`, on **drift (exit 1–4)** or **container-down (exit 9)**
it fires `Mount-Qdrant-VHDX` via `schtasks /run` — no UAC popup (the Highest-level task carries
the elevation). Has a **90 s .NET self-timeout** (force-exit) so a hung `wsl`/`docker` call can't
wedge the 2-min chain.

Exit codes: `0` OK · `1` unmounted · `2` wrong label · `3` low collections · `4` device mismatch ·
`9` container down with mount OK.

> **Known cosmetic inconsistency (harmless):** the in-file exit-code *legend comment* still labels
> code `9` as "no remediation". The **actual `TryRemediate` function is authoritative** and DOES
> remediate 9 (eligible range `1–4, 9`, added 2026-05-28; the code-9 branch calls `TryRemediate`).
> Verified against the live 07-14 auto-recovery. Faithfully preserved here as it is in live.

### `mount_qdrant_vhdx.ps1` — the mounter (elevated, idempotent)
Mounts `E:\wsl-data\qdrant.vhdx` (label **`qdrant-e`**) into **PID-1's mount namespace** (Docker
resolves binds from systemd/PID-1, not a fresh `wsl` session), verifies **by device/label — never
by drive letter** (`sdX` is unstable across reboots), selectively clears stale `qdrant_data`
bind-shims, then `compose down`/`up`. **Phase 6** probes the Docker distro mount-service socket at
**both** paths — `/run/guest-services/distro-services/ubuntu.sock` (pre-29.5.x) and
`/mnt/wsl/docker-desktop/shared-sockets/guest-services/distro-services/ubuntu.sock` (Docker Desktop
29.5.x+) — via `wsl test -S`, with 3× retry + 15 s backoff on bind-mount-service errors.

### `embedding_watchdog.ps1` — the semantic-path watchdog (alert-only)
Closes the detection blind spot behind the 2026-08-16/17 "qdrant HS" reports: those were the
**semantic path** failing (`roosync_search` → `embedding_api_error` → text fallback), NOT qdrant
(qdrant was 200 everywhere). The embedding backend is a **SPOF on po-2026** (vLLM
`qwen3-4b-awq-embedding` :8004); when po-2026 dies, its own watchdogs die with it. This watchdog
runs on **ai-01** (a different machine) and alerts on the roosync dashboards
(workspace-qdrant + global) within 5 min of the cut.

Probes: backend `http://192.168.0.51:8004/health` (vLLM) · proxy `https://embeddings.myia.io/v1/models`
(**401/404 = alive**, 5xx/000 = down) · qdrant `http://localhost:6333/healthz` (alert context only,
to pre-empt misdiagnosis). State machine via `embedding-watchdog-state.json`:
UP→DOWN = `[ERROR]` alert, DOWN→DOWN = re-alert only after 30 min cooldown, DOWN→UP = `[DONE]`
recovery, UP→UP = silent. Exit codes: `0` OK · `1` backend down · `2` proxy down · `3` both ·
`124` self-timeout (60 s .NET force-exit, so a hung HTTP call can't wedge the 5-min chain).

**No remediation by design**: the po-2026 Docker restart requires the maint-admin password
(secret hygiene — never stored in a script). Watchdog role = DETECT + ALERT immediately; the
remediation route is user / Embeddings lane. Deployed 2026-08-17, state-machine tested
(up→down→cooldown→recovery→rearm), healthy run green (backend 200/41 ms, proxy 401/100 ms,
qdrant 200/5 ms).

## Not captured here (yet)

The **offline VHDX compaction toolchain** (`compact_qdrant_vhdx.ps1`,
`recover_mount_after_compact.ps1`, `run_compact_via_task.ps1`) is **intentionally excluded** — the
live compaction script (Qdrant-only `docker stop` design) has diverged from the earlier
Docker-quit-GATE design still referenced in `CLAUDE.md` and PR #2. It will be reconciled and
captured **at the time the compaction window is actually run** (compaction is deferred pending a
user maintenance window). See the `CLAUDE.md` mount-drift/compaction sections.

## Cross-references
- `CLAUDE.md` → "Mount-drift recovery (DEFINITIVE, hardened 2026-05-24)".
- Memory: `project_qdrant_mount_namespace_shims`, `project_durable_mount_fix_20260518`.
