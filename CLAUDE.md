# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **fork of Qdrant** (vector similarity search engine) customized for MyIA deployment. The upstream Qdrant codebase is in Rust. Our customizations are in `myia_qdrant/` and focus on Docker deployment and operational tooling.

**Two Docker instances:**
- **Production** (`qdrant_production`): Port 6333/6334, data on WSL (`\\wsl.localhost\Ubuntu\home\jesse\qdrant_data\`)
- **Students** (`qdrant_students`): Port 6335/6336, Docker volumes, lighter workload

## Key Directories

```
myia_qdrant/           # All MyIA customizations (configs, scripts, docs)
├── config/            # Qdrant YAML configs (production.optimized.yaml, students.yaml)
├── scripts/           # PowerShell operational scripts
│   ├── qdrant_*.ps1   # Unified scripts (backup, monitor, restart, verify, etc.)
│   ├── diagnostics/   # Troubleshooting scripts
│   └── utilities/     # Helper scripts
├── docs/              # Documentation
│   ├── incidents/     # Post-mortems (freeze incidents, resolutions)
│   └── diagnostics/   # Diagnostic reports
└── docker-compose.*.yml  # Docker Compose files
```

## ⚠️ Operational Tooling — Discovery Before Build (MANDATORY)

**`myia_qdrant/` IS the canonical home for Qdrant-specific tooling on this machine.** Before proposing, delegating, or building any new operational script (backup, restore, monitor, migration, snapshot, verify, etc.), you MUST:

1. **List existing scripts** : `Get-ChildItem d:\qdrant\myia_qdrant\scripts\ -Recurse -Filter *.ps1` — these are CONSOLIDATED (cf. `CONSOLIDATION_REPORT.md`), not legacy.
2. **Grep for the function name** before re-implementing : `Grep -path d:/qdrant/myia_qdrant -pattern "New-QdrantSnapshot\|Backup-\|Restore-"`.
3. **Check schtasks separately** : a script existing on disk does NOT mean it runs. `schtasks /query | findstr -i qdrant` to verify scheduling.
4. **Reject duplication in adjacent repos** : if another agent proposes putting Qdrant tooling in `roo-extensions/scripts/qdrant/` or similar, push back — it belongs here in the fork.

**Why this rule exists (Incident 2026-05-19) :** A backup PR was built in `roo-extensions/scripts/qdrant/` (PR #2283, 633 LOC) duplicating `qdrant_backup.ps1` (353 LOC, consolidated 2025-10-13). The original was complete — it just lacked a scheduled task. **Result : two parallel codepaths across two repos for the same operation.** The right action would have been : install a schtask pointing at the existing `qdrant_backup.ps1` + add GDrive push.

**Subtle gap pattern :** A consolidated script with logs from October 2025 + zero logs since = the script works, the scheduling was never wired up. **Look for that gap before building.** Cf. `myia_qdrant/backups/backup_*.log` mtimes.

**Companion rule from global CLAUDE.md :** "Consolider != Archiver" — same spirit, applied to tooling lifecycle, not just file deletion.

## Common Operations

### Container Management
```powershell
# Start/stop production
docker compose -f myia_qdrant/docker-compose.production.yml up -d
docker compose -f myia_qdrant/docker-compose.production.yml down

# Start/stop students
docker compose -f myia_qdrant/docker-compose.students.yml up -d
docker compose -f myia_qdrant/docker-compose.students.yml down

# Check status
docker ps -a --filter "name=qdrant"
docker logs qdrant_production --tail 100
```

### Health & Monitoring
```powershell
# Quick health check
curl http://localhost:6333/healthz   # Production
curl http://localhost:6335/healthz   # Students

# Unified monitoring
.\myia_qdrant\scripts\qdrant_monitor.ps1

# Analyze issues
.\myia_qdrant\scripts\diagnostics\analyze_issues.ps1 -ExportReport
```

### Backup & Recovery

**CANONICAL backup (guarded, consolidated into the fork 2026-05-21):**

```powershell
# Snapshots roo_tasks_semantic_index -> GDrive offsite + D:\qdrant-backups local.
# Poison-guard (abort if points < MinPoints), size-guard (skip retention if new < 50% of largest),
# 7 daily + 4 weekly Mondays retention PER destination, idempotent per day.
.\myia_qdrant\scripts\qdrant_snapshot_backup.ps1                  # all defaults
.\myia_qdrant\scripts\qdrant_snapshot_backup.ps1 -SharedPath -    # local-only (skip offsite)

# Restore (SAFE by default — uploads into the named collection, never touches volumes):
.\myia_qdrant\scripts\qdrant_snapshot_restore.ps1 -SnapshotPath <file> -Collection <name>
.\myia_qdrant\scripts\qdrant_snapshot_restore.ps1 -SnapshotPath <file> -Collection <name> -RecreateCollection -Force  # DESTRUCTIVE drop first
```

`qdrant_snapshot_backup.ps1` is wired to schtask **`Qdrant-Snapshot-Daily`** (~03:17 daily, repointed from the roo-extensions duplicate on 2026-05-21). It is the single canonical backup codepath. Reads the API key from `.env.production` (`QDRANT__SERVICE__API_KEY`), never prints it.

**Backup landscape (verified 2026-05-21):**

| Layer | Script | Target | Status |
|-------|--------|--------|--------|
| **Offsite + Local (ACTIVE, guarded)** | `myia_qdrant/scripts/qdrant_snapshot_backup.ps1` | GDrive `$ROOSYNC_SHARED_PATH/qdrant-snapshots/<machine>/roo_tasks_semantic_index/<date>/` **and** `D:\qdrant-backups/<machine>/...` | **Canonical.** schtask `Qdrant-Snapshot-Daily`. Poison-guard + size-guard. Still `roo_tasks` ONLY (1 of 71 colls — the irreplaceable one; the ~70 `ws-*` code indexes are regenerable). 3 healthy offsite snapshots (05-19/20/21, ~4.5–4.9 GB); local layer populated 05-21. |
| **roo-extensions duplicate (DORMANT)** | `roo-extensions/scripts/qdrant/backup-snapshot.ps1` | (same GDrive path) | No longer scheduled (schtask repointed to the fork). Kept until cross-repo cleanup; **do not re-point to it** (no poison-guard, reads single-underscore `QDRANT_API_KEY`). |
| **Old local (DEPRECATED, BROKEN)** | `myia_qdrant/scripts/qdrant_backup.ps1` | same-disk VHDX `/qdrant/snapshots` + config export | Deprecated header added. Broken for production (`.env` vs `.env.production`; stale compose path). Kept only for its un-ported students path + config/collection-list export. |
| **Local distro copy** | `C:\ProgramData\maint-scripts\backup_vhdx_simple.ps1` | `D:\WSL-recovery\ext4.vhdx.bak` | NOT scheduled. Copies the **Ubuntu rootfs vhdx** (open-webui homes etc.), NOT qdrant data — qdrant lives on `E:\wsl-data\qdrant.vhdx`. |

**Restore:** use `myia_qdrant/scripts/qdrant_snapshot_restore.ps1` (canonical; round-trip tested 2026-05-21). `roo-extensions/scripts/qdrant/restore-snapshot.ps1` also works (it was the port source). `myia_qdrant/scripts/utilities/restore.ps1` is **DEPRECATED + DISARMED** (early `exit 1`) — it was a footgun (`docker-compose down -v` destroys volumes; `finally` with no `try`; undefined `$latestSnapshot`); kept on disk for forensics only.

```powershell
# Safe restart with backup
.\myia_qdrant\scripts\qdrant_restart.ps1
```

**Mount-drift recovery (DEFINITIVE, hardened 2026-05-24):** if qdrant binds the empty rootfs leftover instead of the VHDX (collections drop to ~1), the recovery is automated by `C:\ProgramData\maint-scripts\mount_qdrant_vhdx.ps1` (schtask `Mount-Qdrant-VHDX`, RunLevel Highest). The naive `compose down && up -d` alone is **INCOMPLETE** — proven by the 2026-05-22 and 2026-05-24 drifts. The full recovery, now baked into the script, is:
1. **Mount into PID-1's namespace** via `nsenter -t 1 -m -- mount` (Docker resolves binds from systemd/PID-1's mount ns, not a fresh `wsl` session) + `mount --make-shared` (a bare nsenter mount is PRIVATE → no cross-distro `/mnt/wsl` propagation).
2. **Verify by DEVICE, not collection count** (Phase 5): `findmnt SOURCE` → `blkid -s LABEL` must equal `qdrant-e`. The rootfs leftover has ~14 stale collection dirs and PASSED the old count>0 check → bound the wrong store. Wrong label ⇒ refuse (anti-split-brain, exit 6).
3. **`compose down`**, then **selectively clear the stale qdrant bind-shims** in `/mnt/wsl/docker-desktop-bind-mounts/Ubuntu/<hash>` (compose down does NOT remove them; a shim captured against rootfs keeps the empty bind even after the VHDX mounts). ROBUST filter: shims whose `/proc/1/mountinfo` source contains `qdrant_data` AND whose device ≠ the VHDX device → clears only DRIFTED qdrant shims, never the ~8 open-webui/vllm shims, idempotent on a healthy host.
4. **`compose up -d`** → fresh shims resolve to the VHDX.

Device letters are UNSTABLE (sde→sdg→sdf across reboots) — always resolve by label. The companion watchdog `verify_qdrant_mount.ps1` (schtask `Verify-Qdrant-Mount`, every 2 min, `-Remediate`) now has a **self-timeout** (90s .NET thread → force-exit) so a hung `wsl`/`docker` call can't wedge the chain for hours (the 2026-05-24 failure mode; its task `ExecutionTimeLimit` was the schtasks default `PT72H`). Recommended once in an elevated shell: lower that to `PT90S`.

**Lesson from 2026-05-16 data loss :** the offsite schtask only started **2026-05-19** (PR #2283) — at the moment of the wipe there was NO backup at all. The canonical `qdrant_backup.ps1` had no schtask (last logs 2025-10-08). Always check BOTH script existence AND schtask presence — a consolidated script without scheduling is a half-built safety net.

**Anti-split-brain (IMPLEMENTED 2026-05-21, user mandate 2026-05-20):** the production `docker-compose.production.yml` now has an **entrypoint gate**: it checks for a sentinel file `/qdrant/storage/.qdrant_vhdx_sentinel` (which lives ON the VHDX) and `exit 1`s if absent — so when the VHDX is unmounted and the bind resolves to the empty rootfs leftover, qdrant REFUSES to start instead of serving an empty store and re-indexing into the void (the exact mechanism of the 2026-05-16 loss — "on ne réindexe pas dans le vide"). `exec ./entrypoint.sh` keeps entrypoint.sh as PID 1 so SIGTERM/graceful-stop are preserved. Gate proven both ways (present → `[SENTINEL] OK`; absent → FATAL `exit 1`). The poison-guard now also lives in `qdrant_snapshot_backup.ps1` (abort `exit 2` + skip retention if point-count < `-MinPoints`, default 100000), so a refusing/empty qdrant can never rotate good snapshots out.

### E2E Semantic Search Test
Validates the full pipeline: embedding service -> Qdrant search.
Use after any change to Qdrant config, embedding service, or RooSync env.
```bash
# Default query
./myia_qdrant/scripts/test/e2e_semantic_search.sh

# Custom query
./myia_qdrant/scripts/test/e2e_semantic_search.sh "my search query"
```
Exits non-zero if embedding service down, Qdrant down, dim mismatch, or no results.
Reads env from `myia_qdrant/.env.production` (`EMBEDDING_API_*`, `QDRANT__SERVICE__API_KEY`).

## API Authentication

Each instance has its own API key. Keys are stored in env files (never commit them):
- **Production**: `myia_qdrant/.env.production` → variable `QDRANT__SERVICE__API_KEY`
- **Students**: `myia_qdrant/.env.students` → variable `QDRANT__SERVICE__API_KEY`

```bash
# Production (port 6333, also exposed via qdrant.myia.io:443)
source myia_qdrant/.env.production
curl -H "api-key: $QDRANT__SERVICE__API_KEY" http://localhost:6333/collections
# Students (port 6335)
source myia_qdrant/.env.students
curl -H "api-key: $QDRANT__SERVICE__API_KEY" http://localhost:6335/collections
```

## Known Issues & Patterns

### Freeze/Crash Causes (from incident history)
1. **Vector dimension mismatch**: Collection created with wrong dimension vs embedding model
2. **Thread over-subscription**: Too many threads vs Docker CPU limits causes contention
3. **HNSW indexing under load**: Heavy concurrent writes + indexation = freeze
4. **cgroup cleanup issues**: WSL2/Docker can leave stale cgroup resources (exit code 128)

### Recovery Patterns
- **Container won't start (exit 128)**: Remove stale container, restart Docker/WSL if needed
- **Freeze during indexation**: Reduce `max_indexing_threads` in config
- **OOM**: Reduce `memory` limit or `wal_capacity_mb`

## Configuration Key Points

Production config (`config/production.optimized.yaml`):
- 12 CPUs max, 60G RAM (Docker limits — raised from 24G → 40G → 60G on 2026-04-18; 40G saturated at 96%)
- `indexing_threshold_kb: 6000` (index at ~1000 points)
- HNSW on disk, 10 indexing threads max
- **TurboQuant 4-bit** quantization with `always_ram: true` on `roo_tasks_semantic_index` (migrated 2026-05-24 on engine v1.18.1; PATCH `{"quantization_config":{"turbo":{"bits":"bits4","always_ram":true}}}`). 8× compression, **score-recall@10 = 1.0** vs exact (no quality loss); rescore is a query-time param (`params.quantization.rescore`), not collection config. Replaced the binary 1-bit config that was lost in the 2026-05-16 recreate (collection ran un-quantized until this migration). Footprint ~2.6 GB for the current 461K-point collection.
- Engine pinned to **`qdrant/qdrant:v1.18.2`** (bumped 2026-06-26 from v1.18.1; TurboQuant requires ≥ 1.18.0). v1.18.2 is a patch within the 1.18 minor — security fixes (REST auth whitelist bypass on crafted paths, OOB heap read via malicious snapshot) + optimizer infinite-loop fix; no breaking change, no migration, TurboQuant format unchanged (recall@10=1.0 preserved). **Students** (`docker-compose.students.yml`) is now pinned to the same **v1.18.2** (was the mutable `:latest` tag frozen on the locally-cached 1.17.1 — pinning removes the surprise-jump risk on any recreate).
- GRPC timeout: 60s

## Upstream Sync

This is a fork. To sync with upstream Qdrant:
```bash
git remote add upstream https://github.com/qdrant/qdrant.git
git fetch upstream
git merge upstream/master
```

Our commits are identifiable by paths in `myia_qdrant/` and Docker configurations.

## Embedding Models & Migration

### Current Status (Jan 2026)
- **Production**: Using OpenAI text-embedding-3-small (1536 dims) - **obsolete, costly**
- **Planned migration**: To open-source embeddings (abandoned Qwen 8B - too heavy for RTX 3080)

### Recommended Embedding Models (2026)

| Model | Params | Dims | MTEB | VRAM | Best For |
|-------|--------|------|------|------|----------|
| **BGE-M3** | 560M | 1024 | 63.0 | ~2GB | Best quality open-source |
| **Nomic-embed-v1.5** | 137M | 768 | 59.4 | <1GB | Best cost/quality ratio |
| **EmbeddingGemma-300M** | 300M | 128-768 | ~57 | <1GB | Ultra-lightweight, MRL |
| **Qwen3 0.6B** | 600M | 1024 | ~58 | ~2GB | Lighter Qwen alternative |

**Migration implications**:
- Changing embedding model = **recreate all collections** (different dimensions)
- Save payloads → delete collections → recreate with new dims → re-embed → re-index
- See `myia_qdrant/docs/migration/` for detailed plans

## Semantic Search Integration (MCP)

### Claude Code Semantic Search
Claude Code can be enhanced with semantic codebase search via MCP servers:

#### Option 1: Official Qdrant MCP (uses existing Qdrant)
```json
{
  "mcpServers": {
    "qdrant": {
      "command": "uvx",
      "args": ["mcp-server-qdrant"],
      "env": {
        "QDRANT_URL": "http://localhost:6333",
        "QDRANT_API_KEY": "<see myia_qdrant/.env.production>",
        "COLLECTION_NAME": "code_search",
        "EMBEDDING_MODEL": "sentence-transformers/all-MiniLM-L6-v2"
      }
    }
  }
}
```

#### Option 2: claude-context-local (zero cost, local)
- Uses EmbeddingGemma
- Auto-indexes codebase
- No API costs

#### Option 3: @iflow-mcp/qdrant-mcp-server (AST-aware)
- Intelligent code chunking (functions/classes)
- 35+ languages supported
- Can use Ollama for local embeddings

**Tools available in Claude Code with MCP**:
- `qdrant-store`: Index code snippets with descriptions
- `qdrant-find`: Semantic search across codebase

See `myia_qdrant/docs/MCP_SETUP.md` for detailed setup.

## Building Qdrant (Rust)

Only needed if modifying Qdrant core (rare):
```bash
cargo build --release
cargo test
```

See `docs/DEVELOPMENT.md` for Rust development setup.
