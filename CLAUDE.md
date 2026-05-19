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
```powershell
# Manual backup (use this — script exists since Oct 2025, supports prod + students)
.\myia_qdrant\scripts\qdrant_backup.ps1 -Environment production
.\myia_qdrant\scripts\qdrant_backup.ps1 -Environment students -SkipSnapshot

# Safe restart with backup
.\myia_qdrant\scripts\qdrant_restart.ps1
```

**Scheduled backup status (2026-05-19) :** `Qdrant-Snapshot-Daily` schtask installed by roo-extensions PR #2283. Calls a duplicate script in `roo-extensions/scripts/qdrant/`, NOT the canonical `qdrant_backup.ps1` in this fork. Pending consolidation. Until then: the canonical script + the schtask coexist; verify both are healthy.

**Lesson from 2026-05-16 data loss :** `qdrant_backup.ps1` existed and worked, but no schtask was ever set up to run it. Last automatic backup logs date from **2025-10-08** (~7 months before the wipe). Always check BOTH script existence AND schtask presence — a consolidated script without scheduling is a half-built safety net.

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
- Binary quantization with `always_ram: true` on `roo_tasks_semantic_index` (~7.6 GB in RAM for 23.8M × 2560 dims)
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
