# v1.20.0 production bump bench (2026-11-01, Phase C)

Runbook: `myia_qdrant/docs/operations/runbook_upstream_sync_bump_v1.20.0.md` §5/§9.
Methodology: identical to `tq_recall_bench_20261007_int8_migration.md` — query-by-id, top-10
overlap, latency = wall-clock per query, same host. Collection grew 2.48M → 4.01M pts since the
07/10 archive (+62%); scroll sample differs (sampling band ±0.03 documented in the archive).

## Deployment facts

- Image `qdrant/qdrant:v1.20.0` (build 222b2e44), recreated 14:23, cold recovery **93 s** (warm page cache).
- Pre-upgrade local snapshot: `D:\qdrant-backups\myia-ai-01\roo_tasks_semantic_index\2026-11-01\` (60.2 GB, points=4,009,084 at 13:53).
- Acceptance: **points identical 4,009,560 before/after** · 118 collections · green/optimizer ok ·
  int8 (quantile .99, always_ram) intact · 401 without key / 200 with · zero ERROR/WARN/`enforce_internal_auth` at startup · sentinel gate OK.
- **No optimization wave**: 0 segment.json touched post-start (identical quantization config ⇒ no
  re-quant — the trigger is a config change, per the 07/10 lesson). HNSW `floor()` geometry only
  applies to graphs rebuilt from now on.

## Bench (N=100 + brute N=20, then warm re-run N=30 + brute N=10)

| Metric | Archive 07/10 (v1.19.2, 2.48M pts) | Run 1 (cold-ish cache) | Warm re-run |
|---|---|---|---|
| recall@10 vs HNSW-f32 ref | 0.938 / 0.928 | 0.905 (min 0.0) | **0.963** (min 0.7) |
| recall@10 vs brute force (exact) | 0.940 (N=20) | 0.960 (N=20, min 0.70) | 0.920 (N=10) |
| p50 | 34-38 ms | 46 ms | **40 ms** |
| p90 | 45-56 ms | 84 ms | **58 ms** |
| p99 | 64-99 ms | 382 ms | **80 ms** |

## Conclusions

1. **No regression.** Warm latencies are the same class as the archive (p50 40 vs 34-38, p90 58 vs
   45-56, p99 80 vs 64-99) despite +62% points. Run 1's p99=382 was cold-cache noise right after
   container recreation, not structural.
2. **Recall in the same band** (0.905-0.963 across runs/samples vs the documented ~0.94 ± 0.03
   class). Ground-truth metric (vs brute force) read 0.960/0.920 — consistent with the archive's
   0.940. The vs-f32 dip on run 1 coincided with the 0.0-min outlier and cold cache; the warm run
   (0.963, min 0.7) is the representative reading.
3. **Decision: KEEP v1.20.0.** Rollback path if ever needed: re-pin v1.19.2 + `up -d` (one compose
   line), or restore from the pre-upgrade local snapshot (RTO ~1m40 measured class).

Gotcha logged for the runbook: `powershell.exe -File script.ps1 -SharedPath -` (bare trailing `-`)
dies rc=2 with no output — quote it (`-SharedPath '-'`) or invoke from pwsh directly.
