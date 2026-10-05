# TurboQuant recall@10 bench archive — v1.19.2 upgrade forensics (2026-10-05/06)

Methodology: `tq_recall_bench.py` (exact = `quantization.ignore=true` vs quant = `rescore:true, oversampling:2.0`), N as noted, roo_tasks_semantic_index.

| # | Engine | Data state | N | recall@10 | perfect | min |
|---|--------|-----------|---|-----------|---------|-----|
| 1 | 1.19.2 (1st deploy) | pre-upgrade quant data (1.18-quantized) | 50 | 0.958 | 42 | 0.1 |
| 2 | 1.19.2 (1st deploy) | same | 100 | 0.962 | 90 | 0.0 |
| 3 | 1.18.2 (rollback 1) | mixed (1 appendable segment re-quantized by 1.19 at 23:40) | 50 | 0.954 | 44 | 0.0 |
| 4 | fresh 500-pt test coll (tq_probe_v1192), 1.19 end-to-end | fresh 1.19 quant | 40 | 1.000 | 40 | 1.0 |
| 5 | 1.19.2 (2nd deploy), mid re-quant wave | in-flux | 100 | 0.930 | 83 | 0.0 |
| 6 | 1.19.2 (2nd deploy), post-wave (same params, seed 7 sample) | re-quantized by 1.19 | 30 | 0.9967 | 29 | 0.9 |
| 7 | 1.19.2, no-rescore probe (worst-case mode, never our default) | re-quantized by 1.19 | 30 | 0.920 | 19 | 0.2 |
| 8 | 1.19.2 (2nd deploy), settled | re-quantized by 1.19 | 100 | 0.964 | 89 | 0.1 |
| 9 | 1.18.2 (final rollback) + re-quant wave under 1.18 | re-quantized by 1.18 | 100 | 0.938 | 85 | 0.0 |
| 10 | 1.18.2 (final rollback), run 2 | re-quantized by 1.18 | 100 | 0.980 | 90 | 0.6 |
| 11 | **1.18.2, PRISTINE pre-upgrade snapshot restored to side collection `roo_tasks_baseline_check`** (snapshot 2026-10-05 23:04, before any 1.19 container) | pre-upgrade quant data | 100 | **0.916** | 82 | 0.0 |

## Verdict
**No v1.19.2 recall regression.** Runs 1-10 span both engines and every data state: all read 0.92-0.98 (sampling noise on a heavy-tailed distribution; run-to-run spread up to ±0.05 at N=100). The definitive control is run 11: pristine pre-upgrade data on 1.18.2 benches 0.916 — *lower* than most 1.19.2 runs. The documented "recall@10 = 1.0" was last archived 2026-05-24 at 461K points; the collection is now 2.48M and the true baseline is **~0.95 ± 0.03, engine-independent**.

## Open question (registry)
TurboQuant recall@10 at 2.48M pts is ~0.95, not 1.0. Options: accept / raise client rescore-oversampling params (roo-extensions change) / re-tune quantization (bits8) / raise HNSW ef. Fleet impact: occasional slightly-off top-10 neighborhoods; search quality remains good (fallback_used stays false).

## Operational notes
- Re-quant trigger: PATCH `quantization_config` with a real diff (e.g. `always_ram` false→true). Identical re-PATCH = no-op.
- Optimizer wave is near-silent: `optimizer_status` stays `ok`, `segments_count` unchanged; track via `find <storage>/collections/<c> -name segment.json -newermt <T0>`; settle ≈ 10 min on 2.5M pts. Benches mid-wave read low.
- Pre-upgrade snapshot: `D:\qdrant-backups\pre-upgrade-v1192` (32.4 GB, kept).
