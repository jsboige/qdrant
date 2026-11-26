# Binary quantization switch (2 bits) on `roo_tasks_semantic_index` — 2026-11-26

Decision: user arbitration of 26/11 on Q17 (registry `myia-ai-01:qdrant`), verbatim
« OK pour basculer en binary quant si tu as une méthode performante » — a GO conditional on a
method that performs. Incident context: `docs/incidents/incident_20261123_merge_loop.md` §10
(read path blocked by cold-page faults; process anonymous memory at the ceiling, VM swap full).

**Verdict: KEPT.** Gesture applied at 16:52:30Z, conversion complete in 1.27 h, both halves
measured. recall of the production path against the near-exact reference **0.888 → 0.946**
(criterion was ≥ 0.868), anonymous memory **53.49 → 23.19 Gio** (−30.30, criterion −20),
latency tail p90 **1.455 → 0.239 s**. The switch does **not** abolish the read-path blocks
(§4.5) — that is a separate finding, measured 4 minutes after the wave ended.

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

These numbers are taken **after** a host restart: the WSL VM booted at 15:40:25Z (the user's
Docker Desktop update), the container's previous run finished at 15:53:43Z and the current one
started at 15:55:16Z, cold recovery 93 s, sentinel OK. The swap figures had been worse earlier
the same day (VM `SwapFree` 0.03 Gio at the 12:17Z sample), so 19.27 Gio swapped here is a
**post-reboot** reading — comparable with the after half below, which is also post-reboot.

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

Not measured: 1.5 bit and 2 bits + `query_encoding: scalar8bits`. Two attempts read them on an
unconverted or mixed collection (see §6) and were discarded, not kept as "provisional". To
measure them, `.tmp/bq_bench2.py` still needs two changes: exclude the `plain` segment from the
mtime test (it is never rebuilt, so `old == 0` can never become true on the witness) and abort
a row when its conversion wait times out instead of measuring. Run it when no other collection
is optimising (the optimizer budget is node-wide, §1.2). Neither row changes the decision of
this report: 1.5 bit would save 2.5 more Gio of a heap that is no longer the constraint.

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

## 3. The wave — complete in 1.27 h

Observer `.tmp/bq_wave_watch.py` (one line every 5 min, exit on completion / optimizer error /
8 h; stall > 45 min reported). Samples (binary/scalar = `segment.json` counts by encoding,
`mem`/`swap` = container cgroup, `vmSwapFree` = WSL VM):

| UTC | binary | scalar | segments | status | container mem | container swap | VM SwapFree |
|---|---|---|---|---|---|---|---|
| 16:52:35 | 1 | 328 | 331 | yellow | 54.9 Gio | 17.9 Gio | 10.5 Gio |
| 16:57:35 | 24 | 305 | 329 | yellow | 51.8 | 16.7 | 11.4 |
| 17:07:36 | 70 | 260 | 330 | yellow | 48.0 | 14.7 | 13.5 |
| 17:12:37 | 97 | 251 | **348** | yellow | **57.0** | 14.3 | 13.6 |
| 17:18:37 | 114 | 246 | — | API timeout | **59.1** | 15.4 | 12.1 |
| 17:23:38 | 121 | 209 | 330 | yellow | 52.8 | 13.8 | 13.9 |
| 17:33:38 | 174 | 156 | 330 | yellow | 45.9 | 11.2 | 16.3 |
| 17:53:40 | 270 | 60 | 330 | yellow | 38.1 | 6.3 | 20.9 |
| 18:03:40 | 313 | 16 | 329 | yellow | 32.2 | 4.6 | 21.7 |
| 18:08:40 | **331** | **0** | 331 | **green** | 29.0 | 3.7 | 24.1 |

Completion criterion used: `scalar == 0` AND collection `green`, on a stable segment count.
331 segments before, 331 after, 0 scalar at the end — every indexed segment was rebuilt
(a `plain` segment would never be, but this collection had none).

Two readings the table carries:

- **The optimizer does not stop while a rebuild wave runs.** At 17:12:37 the directory count
  read 348 while the API reported 329 segments: 19 segment directories existed that the engine
  did not count yet, i.e. builds in flight (rebuilds, merges or both — the observer cannot tell
  them apart). At the same time container memory climbed back to 57.0 Gio and at 17:18:37 the
  observer's own `GET /collections/<n>` was too slow to answer (memory 59.1 Gio of a 60 Gio
  limit, `MEM-NEAR-MAX`). Real client traffic lost 6 defective minutes inside the wave (one
  block 17:10 → 17:21Z, access log, probes excluded).
- The cost of the switch is **paid in I/O twice**: once to rebuild every segment in the new
  encoding, again while the optimizer works off the backlog that rebuild leaves. The second
  wave is a *candidate* source for the block §4.5 records after the "done" line — an
  association, not a causal link.

## 4. After-measurement

`python .tmp/bq_prod_ab.py after default,ovs2,ref` — same 100 seeded queries, 18:09-18:11Z,
`Referer: lane-sweep-probe/binquant-after-*` (excluded from the traffic statistics).

### 4.1 Latency

| run | params | ok | p50 | p90 | max | mean |
|---|---|---|---|---|---|---|
| `before/default` (§1.4) | none (= what the RSM client sends) | 100/100 | 0.218 s | 1.455 s | 24.83 s | 0.957 s |
| **`after/default`** | none | 100/100 | **0.078 s** | **0.239 s** | **0.980 s** | **0.126 s** |
| `after/ovs2` | `quantization {oversampling: 2, rescore: true}` | 100/100 | 0.076 s | 0.090 s | 0.117 s | 0.076 s |
| `after/ref` | `quantization {oversampling: 10, rescore: true}` | 100/100 | 0.158 s | 0.404 s | 0.666 s | 0.204 s |

Before and after runs are minutes apart in a regime that changes by the minute: read the
direction (p90 ÷ 6, max ÷ 25), not a strict A/B.

### 4.2 Quality — recall@10 against the same near-exact reference

| pair | recall@10 | n |
|---|---|---|
| **`after/default` vs `before/ref`** — the acceptance metric | **0.9460** | 100 |
| `before/default` vs `before/ref` — the production path until 16:52Z | 0.8880 | 100 |
| `after/default` vs `after/ref` | 0.9650 | 100 |
| `after/ref` vs `before/ref` — the two near-exact references agree | 0.9520 | 100 |
| `after/ovs2` vs `after/ref` | 0.9580 | 100 |
| `after/default` vs `after/ovs2` | 0.9560 | 100 |
| `after/default` vs `before/default` | 0.8890 | 100 |

The production path **improved by 5.8 points** although the encoding is coarser. The reason is
in §1.2: binary quantization turns re-scoring against the original vectors **on** by default,
while the scalar path left it off, and the RSM client sends no `params` at all. The witness
table (§1.3) says the same thing from the other side: without `params`, int8 0.9820 and 2 bits
0.9790 against an exact oracle — a 0.3 pt gap; the 5.8 pt gain here comes from the re-scoring
default, not from the encoding.

### 4.3 Memory

| quantity | before (16:35Z) | after (18:21Z) | delta |
|---|---|---|---|
| process anonymous, resident | 34.22 Gio | 21.96 Gio | −12.26 |
| process anonymous, swapped | 19.27 Gio | 2.83 Gio | −16.44 |
| **process anonymous, total** | **53.49 Gio** | **24.80 Gio** | **−28.7** |
| at the wave's end (18:08Z) | — | 20.48 + 2.71 = **23.19 Gio** | **−30.30** |
| process file pages (`Pss_File`) | 18.85 Gio | 34.33 Gio | +15.5 |
| container `memory.current` | 53.59 Gio | 52.43-54.75 Gio | ~flat |
| container `memory.swap.current` | 19.50 Gio | 3.64 Gio | −15.9 |
| WSL VM `SwapFree` | 10.13 Gio | 23.41-23.53 Gio | +13.3 |

`memory.current` barely moves because the file cache took the freed heap: `Pss_File`
18.85 → 34.33 Gio. That is the point of the exercise — the cgroup's room for cacheable file
pages went from ~6.5 Gio (the 24/11 measure, when anonymous memory alone sat at the 60 Gio
limit) to ~35 Gio, and file pages are **evictable**, unlike the int8 cache that used to sit
in swap. The anonymous footprint is what the kernel had to swap; it is now a third of what it
was.

### 4.4 Verdict — KEEP

| criterion (written before the gesture) | measured | |
|---|---|---|
| recall(`after/default`, `before/ref`) ≥ 0.868 | **0.9460** | pass |
| anonymous memory down ≥ 20 Gio | **−30.30 Gio** | pass |
| latency tail not worse than the regime's variance | p90 1.455 → 0.239 s, max 24.83 → 0.98 s | pass |

`max_optimization_threads` was restored to `auto` at **18:11:58.731Z** (`PATCH
/collections/roo_tasks_semantic_index?timeout=600` → 48-byte body, **0.0136 s**; the read-back
GET 7 ms later shows `null`), which is the value the collection had before the switch. See
§4.5 for what followed.

Rollback, if ever needed, is the int8 body of §2 — a second rebuild wave of the same length.

### 4.5 What the switch did NOT fix — a block, 4 minutes after the wave ended

At **18:15:16Z** a `POST /points/count` answered 500 after **60.00 s** — the engine's own
operation timer, which the approximate path does not arm (dossier §10.16), so an exact count.
Then `GET /collections/roo_tasks_semantic_index` stopped answering altogether: the backup
script's poison-guard read timed out at 60 s (18:17:52Z), and two tagged info reads of this
lane timed out at 30 s each (18:19Z). By **18:22:41Z** none of the three had produced a
completion line in the access log — they were not slow, they were **hung**. Client writes show
the write-side form of the incident:

```
18:18:27  PUT /points?wait=true   200  60.01 s     18:17:26  scroll  200  0.016 s
18:18:44  PUT /points?wait=true   200  60.02 s     18:17:26  PUT ?wait=false 200 0.047 s
18:19:03  PUT /points?wait=true   200  60.02 s     18:20:20  PUT ?wait=false 200 0.049 s
18:19:54  PUT /points?wait=true   200  60.01 s
18:20:11  PUT /points?wait=true   200  60.01 s
18:20:30  PUT /points?wait=true   200  60.04 s
```

Fast submission, no application: `wait=true` returned 200 at exactly 60 s carrying
`wait_timeout` — the write is **not acknowledged**, and the client cannot tell from the status.
Meanwhile the VM had **52.7 Gio available and 23.5 Gio of swap free**, the container's
anonymous memory 24.8 Gio of a 60 Gio limit: the memory pressure that the 23/11 dossier
describes was **absent** and the block happened anyway.

Thread states sampled at 18:21Z (procfs only, no engine request): all threads sleeping, 14
named `optimization` parked in `futex_wait_queue`, one `update-17` in `hrtimer_nanosleep` (the
deferred-points retry loop), no thread in `D` state. `segment.json` mtimes: 18:11:42, 18:14:29
×2, 18:14:34, 18:17:27 — merge activity in and just before the block, nothing after 18:17:27
while writes stayed blocked.

Honest reading: **association, not causality**. The block begins 5 minutes after
`max_optimization_threads` returned to `auto` and inside the merge backlog left by the rebuild
wave (§3, second bullet) — the same shape as 26/11 morning, when the block's end coincided to
the second with the nightly snapshot build finishing (dossier §10.18). It does not follow that
the switch was a mistake: the memory and quality gains are measured; the block class is older
than the switch and survived it. What this measurement kills is the hypothesis that **swap /
anonymous memory alone** explains the blocks.

Consequence for the closure criterion: no 60-minute clean window can start before 19:09Z at
the earliest, and the read-path escalation stays **open**.

Consequence for the backup safety net, measured the same minute: the evening `-RetentionOnly`
pass (the lane's 19:45 duty, dry-run `-WhatIf` first) **aborted at its poison guard** — the
collection read it performs before deleting anything timed out, `exit 1`, and **nothing was
deleted** (fail-safe, the intended direction). An exact rotation can only run when the
collection answers, so the pass is deferred with that as its resume condition — not skipped by
choice. The same read opens the nightly at 01:17Z; "collection unreadable in 60 s" is how the
22/11 nightly failed (`CLAUDE.md`, paragraph Q68).

## 5. Client-side lever (ask to `roo-extensions`, owner of the search client) — corrected

The ask, as first published on `global`: add `params: { quantization: { oversampling: 2, rescore: true } }`
to the search. The witness table (§1.3) motivated it — there, oversampling 2 lifted both encodings
to 0.996-1.000 — but **that gain does not transfer to production, where it is already banked**:
binary quantization re-scores by default, so the production path sits at 0.946 of the near-exact
reference with no `params` at all. Measured on production after the switch, oversampling 2 moved
quality by **+0.2 pt** against the same reference (0.9560 → 0.9580, n = 100) — inside the noise
(standard error 0.010). The ask is therefore **withdrawn as a quality lever**.

What the same measurement does show is a **tail** effect, and that one is real: with the same
100 queries, p90 went 0.239 → 0.090 s and max 0.980 → 0.117 s with `oversampling: 2` (§4.1).
It is a single run in a changing regime, so it is a reason to look, not a result: worth a
re-measurement on a quiet hour before asking anything of `roo-extensions`.

The fact that stands regardless: the client sends no `params` (`task-searcher.js:143-150`), so
every default of the server decides quality and latency for it.

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
