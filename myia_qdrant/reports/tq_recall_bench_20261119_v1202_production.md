# v1.20.2 production bump bench (2026-11-19)

Runbook: `myia_qdrant/docs/operations/runbook_upstream_sync_bump_v1.20.0.md` §5/§9, adapted
for a same-family patch bump. GO user 18/11 evening (after full validation of the 18/11 backup
cycle — direct upload + first permanent rotation).

## Deployment facts

- Image `qdrant/qdrant:v1.20.2` (build **23065a0b**), both tenants. Students first
  (350 collections, 401/200, search 3 hits/26 ms, zero ERROR/WARN), production after.
- Pre-upgrade **local** snapshot: `D:\qdrant-backups\...\2026-11-18\` (199,761,715,712 bytes,
  byte-exact vs server, points=13,307,794 at creation 23:29; local retention keep=1 applied,
  2026-11-01 folder rotated out).
- Production cold recoveries: **90 s** (v1.20.2 recreate), 110 s (v1.20.0 A/B), 110 s (final
  v1.20.2) — same class as the 93 s of 01/11.
- Acceptance (final state): **points 13,639,755** (no loss; +6k = ingest during the A/B window)
  · 118 collections · green/optimizer ok (transient `yellow` for ~2 min post-recreate — known
  startup-optimization class, Q13) · int8 (quantile .99, always_ram) intact · 401 without key /
  200 with key · healthz ×3 = 200 · sentinel gate OK · **no optimizer wave** (269 segment.json
  mtimes = segment open/validate at load + recovery ingest; count STABLE over 3 min, CPU 0.67 %,
  zero optimization log lines — same no-config-change/no-re-quant mechanism as 01/11).
- RAM vigilance: container **48.8/60 GiB** steady (int8 always_ram cache scales with points;
  13.6M × 2560 × 1 B ≈ 35 GB cache). This is now the primary scaling constraint → binary quant
  bench is the next lever, with increased urgency.

## Bench — and two methodology findings

1. **Top-level `"exact": true` is silently ignored** by the search API — it belongs in
   `params: {exact: true}`. Symptom: "recall 1.000" because both searches ran the same
   approximate path. (Fixed in the bench script.)
2. **Full-universe brute force no longer fits the 60 s operation timeout**: exact search over
   13.6M pts × 2560 dims needs the on-disk f32 originals (~139 GB, mostly outside RAM) →
   `Service internal error: Operation 'Search' timed out after 60 s` (HTTP 500). At 4M pts
   (01/11 bench) it completed in seconds. **The archive methodology (recall vs full brute) is
   not reproducible at this scale on this box** without raising the timeout (recreate) or using
   filtered-universe proxies. Not attempted: the A/B below answers the decision question.

## A/B latency (same collection, same sampled ids, same day, same warm-up protocol)

| metric | v1.20.0 (A/B pass) | v1.20.2 (warm pass) | delta |
|---|---|---|---|
| p50 | 176 ms | 182 ms | +3 % |
| p90 | 208 ms | 232 ms | +12 % |
| p99 | 255 ms | 280 ms | +10 % |

**Verdict: same class — no engine regression.** v1.20.2 was pinned back temporarily
(one recreate), benched, then restored (working tree = master `ceec5eb75`).

## Context vs the 01/11 archive (p50 40 / p90 58 / p99 80 ms warm)

The 4.5× gap vs the archive is a **scale effect, not a regression**: 13.6M pts vs 4.01M (+240 %),
int8 cache at the RAM ceiling (48.8/60 GiB) → disk on the hot path. Cross-check: yesterday's
sweeps already measured the ~180-200 ms class under v1.20.0 at 13M+ pts. The `#10743` fix
(halved COLD reads) targets cold start — warm steady state shows no delta, as expected;
`#11553` (classic HNSW for NEW graphs) accrues progressively as segments optimize.

## Decisions

1. **KEEP v1.20.2 on both tenants.** No regression (A/B), HNSW build speed fix (#11343) pays on
   every optimizer wave on this 24-thread host, snapshot hardening retained.
2. **Latency lever = quantization/RAM**, not engine: bench `binary` + rescore (≈4 GB vs ≈35 GB
   cache) and/or `hnsw_config.inline_storage` next — one change at a time, bench before/after
   with the A/B protocol from this report (same ids, same day).
3. Brute-force recall at 13.6M: use `params.timeout` bump or filtered-universe proxy next time a
   ground-truth recall number is needed; document the reference universe with the number.
