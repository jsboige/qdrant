# Quantization migration turbo4 → scalar int8 + recall ceiling forensics (2026-10-07)

Trigger: registry Q5 (recall ~0.95 at 2.48M pts). User GO 07/10 ("mesurer les perfs").
Methodology: query-by-id, top-10 overlap, N=100 (recall), N=20 (brute-force probe); latency = wall-clock per query (same host, comparable loads).

## Migration measurements (before → after)

| Metric | turbo bits4 (baseline, 07/10 11:50) | scalar int8 (07/10 12:10, wave settled) |
|---|---|---|
| recall@10 vs HNSW-f32 reference | 0.943 (81/100, min 0.2) | 0.938 / 0.928 (runs 1/2) — same class |
| latency p50 | 28 ms | 34-38 ms (slightly up) |
| latency p90 | 92 ms | 45-56 ms (**down**) |
| latency p99 | 566 ms | **64-99 ms (6-9× better tail)** |
| container RAM | 4.85 GiB | 8.63 GiB (+3.8, of 60 limit) |
| config | turbo bits4 always_ram | scalar int8 quantile .99 always_ram |

Decision: **KEEP scalar int8** — identical quality class, much better latency tail (real fleet-facing win), RAM affordable. Reversible: PATCH turbo bits4 + re-quant wave.

## The decisive brute-force probe (N=20, `exact:true` full scan as ground truth)

| Path | recall vs brute force |
|---|---|
| **Production (int8 + rescore)** | **0.940** (17/20, min 0.1) |
| Bench reference (HNSW f32, quant ignored) | 0.945 (18/20, min 0.1) |

## Conclusions

1. **The ~0.95 ceiling is HNSW graph traversal, not quantization.** Both the quantized production path AND the unquantized HNSW reference miss ~5-6% vs brute force, equally. Quantization costs ~0.5 pt. Earlier hypotheses (4-bit error — disproved by int8; search params — disproved by ef/oversampling sweep 06/10) are settled: the bench's two approximate traversals overlap at ~0.94-0.95, and each is ~0.94-0.945 vs true brute force.
2. The May 2026 "recall = 1.0" was real — at 461K pts the graph was easy. At 2.5M dense near-duplicate conversation chunks, HNSW-vs-exact ≈ 0.94 is standard approximation behavior, not a defect.
3. **Options to raise quality further** (if ever needed): rebuild HNSW with higher m / ef_construct (m=32→48, ef_construct=200→400) — better graph, cost = bigger index + multi-hour rebuild; or `exact:true` per critical query (brute force, slow). Default posture: **accept** — 0.94 on near-duplicate-dense data is normal and search quality is subjectively good (KPI fallback false throughout).

## Migration mechanics (validated again)
PATCH `{"scalar":{"type":"int8","quantile":0.99,"always_ram":true}}` → status **yellow** (visible this time, unlike same-type turbo waves) → settle in ~8 min (51 segments) → green. Rollback snapshot: 07/10 03:17 offsite (zero drift: point count identical pre-PATCH).
