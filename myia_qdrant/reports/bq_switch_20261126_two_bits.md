# Binary quantization switch (2 bits) on `roo_tasks_semantic_index` — 2026-11-26

Decision: user arbitration of 26/11 on Q17 (registry `myia-ai-01:qdrant`), verbatim
« OK pour basculer en binary quant si tu as une méthode performante » — a GO conditional on a
method that performs. Incident context: `docs/incidents/incident_20261123_merge_loop.md` §10
(read path blocked by cold-page faults; process anonymous memory at the ceiling, VM swap full).

**Status of this report: BEFORE half measured, gesture applied at 16:52Z, AFTER half pending
(the conversion wave must finish first). Sections marked PENDING are filled by the same lane.**

## 1. What was measured before the gesture

### 1.1 Memory (16:35Z, `docker exec … cat /proc/7/smaps_rollup`, `qdrant_cgroup_sample.py`)

| quantity | value |
|---|---|
| process anonymous memory, resident | 34.22 Gio |
| process anonymous memory, swapped | 19.27 Gio |
| **process anonymous memory, total** | **53.49 Gio** |
| process file pages resident (`Pss_File`) | 18.85 Gio |
| container `memory.current` / `memory.max` | 53.59 / 60.00 Gio (`memory.peak` = 60.00) |
| container `memory.swap.current` | 19.50 Gio |
| WSL VM `SwapFree` / `SwapTotal` | 10.13 / 32.0 Gio |
| free space `/qdrant/storage` (ext4 in the VHDX) | 435 GiB of 866 |

Sizes of the quantized cache at 16 711 517 points × 2560 dims (computed by script):

| encoding | bytes/dim | size |
|---|---|---|
| int8 scalar (production until 26/11 16:52Z) | 1 | 42.78 GB = **39.84 Gio** |
| binary 2 bits (production since) | 0.25 | 10.70 GB = **9.96 Gio** |
| binary 1.5 bit | 0.1875 | 8.02 GB = 7.47 Gio |
| binary 1 bit | 0.125 | 5.35 GB = 4.98 Gio |

int8 → 2 bits gives back **29.88 Gio (75.0 %)** of anonymous memory.

### 1.2 Engine facts the method rests on (code at tag `v1.20.2`)

- `always_ram: true` means `Memory::Pinned`, and `Pinned.is_heap()` is true — the int8 cache is
  **heap anonymous memory**, which is why 39.8 Gio of it can sit in swap
  (`lib/segment/src/types.rs:1017`, `:5072`). `Memory::Cached` would be mmap page cache
  (evictable, never swapped) — not chosen: under pressure the kernel evicts file pages first,
  so `pinned` keeps the scoring path free of faults, as the int8 cache is today.
- A quantization change is a **full rebuild of every indexed segment**, largest first — not a
  flag flip (`lib/shard/src/optimizers/config_mismatch_optimizer.rs:86-149, 203-222`).
- For every binary encoding, **re-scoring against the original vectors is ON by default**
  (false for scalar); `oversampling` defaults to 1.0
  (`lib/segment/src/vector_storage/quantized/quantized_vectors/accessors.rs::default_rescoring`,
  `lib/segment/src/types.rs:605-628`).
- PATCH body: `optimizer_config` is an accepted alias of `optimizers_config`; diffs are applied
  in that order (optimizer params **before** quantization) and the optimizers are recreated in
  the background (`lib/storage/src/content_manager/toc/collection_meta_ops.rs:150-233, 357-366`).
- `Can't notify optimizers, assume process is dead. Restart is required` is logged when the
  optimizer signal channel is closed — i.e. by that recreate. It is not a restart request
  (`lib/collection/src/update_workers/optimization_worker.rs:521-524`).
- The optimizer CPU/IO budget is **node-wide**: a second collection's optimizations wait while
  another one is optimizing (`optimization_worker.rs:509-519`).

### 1.3 Witness collection — same 100 real queries for every encoding

`bench_bq_20261126` = 12 000 real vectors of the production collection; 100 queries drawn with
seed 20261126 from that sample; reference = `params {exact: true}`; `limit` 11, the query's own
point dropped by id, top-10 compared.

| encoding | recall@10, client defaults | delta vs int8 | recall@10, oversampling 2 + rescore | delta vs int8 |
|---|---|---|---|---|
| int8 quantile 0.99 (production until 16:52Z) | 0.9820 | — | 1.0000 | — |
| binary 1 bit | 0.9570 | −0.0250 | 0.9910 | −0.0090 |
| **binary 2 bits (production since 16:52Z)** | **0.9790** | **−0.0030** | **0.9960** | **−0.0040** |

Not validated, to be re-run after the wave: 1.5 bit and 2 bits + `query_encoding: scalar8bits`.
Two attempts read them on an unconverted or mixed collection (see §6): a content test on
`segment.json` cannot gate a binary → binary transition, and measuring after a timed-out wait
labels the row with the previous encoding.

The first bench of the day (queries = first 100 points of the sample, a different set) had read
int8 0.995 / binary 2 bits 0.991 at client defaults: same direction, −0.4 pt. Its output was
not archived; the table above supersedes it.

### 1.4 Production collection, before the gesture (16:37-16:44Z)

Same 100 query vectors, `with_payload: false`, `Referer: lane-sweep-probe/binquant-before-*`.

| run | params | ok | p50 | p90 | max | mean |
|---|---|---|---|---|---|---|
| `before/default` | none (= what the RSM client sends) | 100/100 | 0.218 s | 1.455 s | 24.83 s | 0.957 s |
| `before/ref` | `quantization {oversampling: 10, rescore: true}` | 100/100 | 0.526 s | 0.748 s | 0.929 s | 0.538 s |

**recall@10 of the production path against the near-exact reference: 0.888** (n = 100).
The two runs were minutes apart in a changing regime: the latency columns are not an A/B.

Exact search over 16.7 M points does not fit the 60 s operation timeout (report of 19/11 §2),
so the oracle is a 10× oversampled, re-scored search.

### 1.5 What the client sends

`roo-state-manager` build `1202619048dd8c61`, `services/task-searcher.js:143-150`:
`qdrant.search(collection, { vector, limit, filter, score_threshold, with_payload: true, timeout })`
— **no `params`**, hence `ef` = limit, oversampling 1.0, and (with binary) re-scoring of the
top-limit candidates against original vectors.

## 2. The gesture

1. Dry-run on the witness: int8 → binary → int8 → binary, HTTP 200 each time, segments
   rebuilt each way, config read back identical.
2. Announcement with bodies, side effects and acceptance criterion on `workspace-qdrant`
   (messageId `bq-switch-20261126-announce`, stamped 16:55Z by rounding — the PATCH itself ran
   at **16:52:30Z**) and on `global` with a cross-post to `workspace-roo-extensions`.
3. `PATCH /collections/roo_tasks_semantic_index?timeout=600`

   ```json
   {"optimizer_config": {"max_optimization_threads": 2},
    "quantization_config": {"binary": {"memory": "pinned", "encoding": "two_bits"}}}
   ```

   HTTP 200 in 0.017 s. Read back: config as above, 16 711 517 points, 330 segments.

Rollback, same path, validated on the witness:

```json
{"optimizer_config": {"max_optimization_threads": "auto"},
 "quantization_config": {"scalar": {"type": "int8", "quantile": 0.99, "always_ram": true}}}
```

`max_optimization_threads: 2` caps the concurrent optimizations of this collection. Without it
there is **no per-collection limit** — `max_handles.unwrap_or(usize::MAX)`
(`lib/collection/src/update_workers/optimization_worker.rs:67`) — only the node-wide resource
budget (`:146-150`, each optimization asks for `max_indexing_threads` IO units). The cap was
set because the container had 6.4 Gio of headroom; it goes back to `auto` once the wave is
over. Do **not** use `0` as a pause lever on a collection receiving writes: the optimizer then
skips without notifying, and updates waiting for deferred points hang until their timeout
(`lib/collection/src/update_workers/update_worker.rs:313-316`).

Acceptance criterion, written before the gesture: **keep** if
recall(`after/default`, `before/ref`) ≥ 0.868 (= 0.888 − 2 pt; the standard error of a recall@10
over 100 × 10 items is 0.010) and anonymous memory is down by at least 20 Gio and the latency
tail is not worse than the regime's variance; **otherwise roll back**.

## 3. The wave — PENDING

Observer `.tmp/bq_wave_watch.py` (one line every 5 min, exit on completion / optimizer error /
8 h; stall > 45 min reported). First samples:

| UTC | binary | scalar | segments | status | container mem | container swap | VM SwapFree |
|---|---|---|---|---|---|---|---|
| 16:52:35 | 1 | 328 | 331 | yellow | 54.9 Gio | 17.9 Gio | 10.5 Gio |
| 16:57:35 | 24 | 305 | 329 | yellow | 51.8 Gio | 16.7 Gio | 11.4 Gio |

## 4. After-measurement — PENDING

`python .tmp/bq_prod_ab.py after default,ovs2,ref`, same 100 queries, same reference.

## 5. Client-side lever (ask to `roo-extensions`, owner of the search client)

Adding `params: { quantization: { oversampling: 2, rescore: true } }` lifted **both** encodings
to 0.996-1.000 on the witness (table §1.3). On production the current path returns 88.8 % of
the near-exact top-10. Asked on `global` + cross-posted to `workspace-roo-extensions`.

## 6. Instruments and pitfalls

- `.tmp/bq_prod_ab.py` — before/after probe on production (100 seeded queries, self dropped by
  id, pause-and-retry on failure, written after every query, tagged `Referer`).
- `.tmp/bq_patch.py` — the single PATCH instrument (`dryrun` / `pre` / `apply --yes` /
  `rollback --yes`); the production body and the rollback body live in one place.
- `.tmp/bq_wave_watch.py` — the wave observer.
- `.tmp/bq_bench2.py` — witness bench. Its conversion wait is **wrong** as written for a
  binary → binary PATCH; fix before reuse: gate on the four HNSW segments' `segment.json`
  being newer than the PATCH, and abort the row on timeout instead of measuring.
- `GET /collections/<name>` returns `quantization_config`, `optimizer_config`, `hnsw_config`
  under `result.config`, not at the top of `result`.
- A `plain` (unindexed) segment is not rebuilt by a config change; a count like "4/5" on the
  int8 rows is that segment, not a failed conversion.
