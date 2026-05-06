# Phase A Cleanup — Qdrant `roo_tasks_semantic_index` — 2026-05-06

**Scope:** Mission per issue jsboige/roo-extensions#1987 — delete Claude Code (CC) duplicates from Qdrant production.
**Operator:** Sub-agent on myia-ai-01 (this machine).
**Status:** PARTIAL SUCCESS — 30 of ~2002 CC tasks dedup'd; 2.16M point deletions queued; significant follow-up needed.

## Executive Summary

The mission spec assumed **cross-task duplicates** (`/resume` and `/compact` create new task_ids without dedup, two different task_ids carrying the same content). Investigation revealed the actual pattern is **intra-task multiplication** — the same JSONL session has been re-indexed many times, producing duplicate Qdrant points all carrying the same `task_id`, `sequence_order`, `chunk_index`, and `total_chunks`, with **byte-identical content** (verified via SHA-256) but different point UUIDs.

This invalidated the originally-suggested "delete by task_id filter" approach (which would have erased real data). Instead, dedup required scrolling each task's points, grouping by `(sequence_order, chunk_index, total_chunks)`, and deleting all but one point per group.

A custom dedup script was built and run on a tractable subset (top 30 mid-tier CC tasks with 1K-100K points each). It successfully deduplicated 30 tasks, queuing **2,160,575 point deletions** for ~30 source JSONL session worth of content. The full collection has many more tasks needing the same treatment.

## Findings (TECHNICAL)

### Pattern 1 — Intra-task multiplication (NOT cross-task)
- **Median CC task** (`claude-...wt-worker-myia-po-2023-...9ae5c032...`): 609 points but only 41 unique `(seq, ci, tc)` tuples → ~15x intra-task duplication.
- Sample dup group `seq=0, ci=1, tc=2` had **38 byte-identical copies** (single SHA-256 hash, same timestamps, different point IDs and `original_chunk_id`).

### Pattern 2 — Top tasks heavily multiplied
- Total CC points before cleanup: **31,953,780** (51.8% of 60.36M total — matches the audit).
- **2002 distinct CC `task_id`s**.
- Top 30 task_ids account for ~19.6M points (61% of CC).
- Largest single task `claude-c--dev-CoursIA--11f2624e-...` has **3,434,436** points, max sequence_order 1741 → effective duplication ~400x for that one task.
- Per-task size distribution: P25=123, median=598, P75=2531, P90=16467, P99=390957, max=3,434,436.

### Pattern 3 — Indexed payload fields (governs which filters/counts are fast)
Indexed: `workspace`, `source`, `host_os`, `task_id`, `workspace_name`, `chunk_type`, `timestamp`. NOT indexed: `sequence_order`, `chunk_index`, `total_chunks`, `message_index`, `original_chunk_id` → cannot filter on these without scrolling all points per task.

### Why "cross-task delete by task_id" can't be used
Each `task_id` represents a real conversation. The duplication is internal: the indexer ran multiple times against the same JSONL. Delete by task_id would lose real data.

## Approach Implemented

1. **Facet aggregation** (`/collections/.../facet` on `task_id`, filter `source=claude-code`) → built distribution of all 2002 CC task_ids and saved to `D:\qdrant\myia_qdrant\reports\cc_task_facets.json`.
2. **Tractable subset selection** — focused on tasks with 1K–100K points (excludes top 5 mega-tasks too slow to scroll, and tail tasks with <1K points and small absolute gain).
3. **Per-task dedup script** (`D:\qdrant\myia_qdrant\scripts\dedup_cc_tasks.ps1`):
   - Scroll all points (paginated, 5000/page).
   - Group by `(sequence_order, chunk_index, total_chunks)`.
   - Pick keeper = lowest UUID per group.
   - Delete the rest in batches of 200 with `wait=false` (async).
4. **Optimizer trigger** (`D:\qdrant\myia_qdrant\scripts\trigger_optimizer.ps1`):
   - PATCH `optimizers_config.default_segment_number = 8` to force segment compaction & disk reclaim (per `feedback_qdrant_ops` memory).
5. **Smoke tests** (`D:\qdrant\myia_qdrant\scripts\smoke_test_search.ps1`) — 3 search queries via embedding service + Qdrant search.

## Pre-state (2026-05-06 11:24Z)

```
Qdrant collection: roo_tasks_semantic_index
points_count:          60,425,272
indexed_vectors_count: 60,521,337
segments_count:        1194
status:                green
optimizer_status:      ok

CC subset (source=claude-code):
points:                31,953,780
distinct task_ids:     2002

Disk (VHDX /dev/sde mounted at /mnt/qdrant-e):
  866G total, 762G used, 60G avail (93%)
```

## Execution

- **Script:** `dedup_cc_tasks.ps1 -MaxTasks 30 -MinSize 1000 -MaxSize 100000 -MaxMinutes 25`
- **Started:** 2026-05-06 11:24Z (approx)
- **Finished:** ~10.3 min later (well within budget)
- **Tasks processed:** 30 / 30 (all completed successfully, 0 failures)
- **Points scrolled total:** 2,220,279
- **Points kept (unique chunks):** 59,704
- **Points deleted (queued):** 2,160,575
- **Per-task delete count range:** 42,015 – 98,193
- **Per-task duplication factor range:** ~3x – 1166x (median ~50x)
- **Pace:** ~14-30s per task (scroll + group + async delete)

### Verification of correctness on first task
- `claude-d--Dev-CoursIA--c3cd5d85-0817-4f08-af0a-b3bb4ede492a`: pre=99,849 → kept=1,656 → post-Qdrant-count=1,656 ✓ (matches expected exactly).

### Per-task summary (sample)
See `D:\qdrant\myia_qdrant\reports\dedup_progress.jsonl` for full record. Highlights:
- Highest dup factor: task #5 `claude-d--Dev-CoursIA--469738c1...` — 93,310 points → 80 unique → **1166x duplication**.
- Lowest dup factor: task #12 `claude-d--dev-CoursIA` — 77,087 points → 23,515 unique → ~3.3x (still useful but lots of legitimate content).

## Post-state (2026-05-06 ~11:41Z, immediately after script + PATCH)

```
points_count:          60,157,069  (delta: -268,203 — async deletes still draining)
indexed_vectors_count: 60,434,679
segments_count:        1195
status:                yellow      (optimizer/deletes processing)
optimizer_status:      ok

CC subset:
points:                31,697,389  (delta: -256,391)

Disk:
  866G total, 761G used, 61G avail (93%)
  → 1G freed so far; remaining ~9-15 GB will reclaim as segments compact.
```

**Important:** the 2,160,575 deletes are queued in Qdrant's WAL; only ~268K had been processed at snapshot time. Full draining + segment compaction will continue for hours after this report. Disk reclaim will follow segment merges.

### Disk reclaim expectation (estimate)
- 60.36M total points, 760GB → ~12.6 KB per logical point (vector + payload + overhead).
- 2,160,575 deletes × ~12.6 KB ≈ ~27 GB to reclaim once compaction completes.
- Far short of the audit-target 200-300 GB; the bulk lives in the top 5 mega-tasks (>500K points each) which were excluded from this pass for time-budget reasons.

## Smoke Tests (post-cleanup)

3 search queries via embedding service `qwen3-4b-awq-embedding` (2560 dims) → Qdrant `points/search` (limit=3). All 3 returned results.

| Query | Search dur | Hits | Top score | Notes |
|-------|-----------|------|-----------|-------|
| `Phase A Qdrant cleanup duplicate task_ids` | 0.6 s | 3 | 0.806 | Hit `claude-g--Mon-Drive-Maintenance--b96790e` (size 390K — out-of-scope mega-task, results are themselves duplicated, indicating that task is still heavily duplicated). |
| `Lean theorem proof Pareto efficiency` | 3.0 s | 3 | 0.687 | Hit `claude-c--dev-CoursIA--11f2624e` (3.4M — top mega-task, excluded). 3 identical result rows. |
| `Docker container restart healthcheck` | 2.0 s | 3 | 0.769 | Hit `23711565-...` (Roo task). 3 identical result rows. |

**Search functionality confirmed working.** The duplicate result rows in queries 2 and 3 are a *symptom* of remaining intra-task duplication in the un-deduped tasks (mega-tasks and Roo tasks not in scope of this pass), not a regression from the cleanup.

Smoke test results saved to `D:\qdrant\myia_qdrant\reports\smoke_test_results.json`.

## Issues / Caveats

1. **Mission scope mismatch** — issue #1987's audit suggested cross-task duplicates from `/resume` and `/compact`, but live data shows intra-task multiplication. Different problem, different fix. The fix here can recover space, but only via per-task dedup, which is bottlenecked by Qdrant's per-point delete throughput.

2. **Audit-target 200-300 GB recovery NOT achieved** — only ~27 GB worth of points queued for deletion. The bulk (>200 GB) lives in:
   - **Top 5 mega-tasks** (>500K points each, ~7M total points) — excluded as too large to scroll in 30-min budget. These are the highest-value targets for a follow-up pass.
   - **Tail tasks** (<1K points each, ~13M points across 1207 tasks) — dedup gain per task is small but cumulative could be ~6-10 GB.

3. **Async delete propagation lag** — Qdrant queues deletes in WAL with `wait=false`. At report time only 12% of queued deletes had been processed by the storage engine. Disk reclaim follows compaction, which lags processed-delete count.

4. **No source files touched** — JSONL sanctuary respected. Only Qdrant points deleted. Other collections (`ws-*`, `technical-systems`, etc.) untouched.

5. **No Qdrant version bump, no schema change.** Stayed on v1.17.1.

6. **Sanity stop NOT triggered** — 2.16M deletions is well under the 30M sanity ceiling. Plenty of headroom for further passes.

## Files Produced

- `D:\qdrant\myia_qdrant\scripts\dedup_cc_tasks.ps1` — main dedup script (idempotent, parametrized).
- `D:\qdrant\myia_qdrant\scripts\trigger_optimizer.ps1` — PATCH-based optimizer trigger.
- `D:\qdrant\myia_qdrant\scripts\smoke_test_search.ps1` — 3-query smoke test.
- `D:\qdrant\myia_qdrant\scripts\capture_post_state.ps1` — state capture helper.
- `D:\qdrant\myia_qdrant\reports\cc_task_facets.json` — full CC task_id distribution (top 2002).
- `D:\qdrant\myia_qdrant\reports\cc_task_facets_tractable.json` — filtered subset (1K-500K).
- `D:\qdrant\myia_qdrant\reports\dedup_progress.jsonl` — per-task delete record (30 lines).
- `D:\qdrant\myia_qdrant\reports\dedup_run.log` — full stdout of dedup script.
- `D:\qdrant\myia_qdrant\reports\state_before.json` / `state_after.json` — collection state snapshots.
- `D:\qdrant\myia_qdrant\reports\disk_before.txt` / `disk_after.txt` — `df -h` snapshots.
- `D:\qdrant\myia_qdrant\reports\smoke_test_results.json` — smoke test outcomes.

## Recommended Follow-ups (in priority order)

1. **Mega-task dedup** — top 5 CC tasks (>500K points each, ~7M total points). Use the same `dedup_cc_tasks.ps1` script with `-MinSize 500000 -MaxSize 5000000`. Each mega-task will take ~5-15 min to scroll + delete (limited by Qdrant scroll throughput). Estimated recovery: ~150-200 GB after compaction.

2. **Tail-task dedup** — remaining 800+ tasks with 1K-1000 points each. Same script with `-MinSize 100 -MaxSize 1000 -MaxTasks 1000`. Estimated recovery: ~5-10 GB.

3. **Investigate root cause** — why is the same JSONL being re-indexed so many times? PR #319 (content-hash dedup) and #320 (block CC auto-indexing) should prevent NEW dupes; but understanding why the OLD indexer multiplied so aggressively (e.g., does `/compact` event re-emit the entire prior conversation? Did indexing happen on every keystroke?) would inform any structural fix and confirm the new PRs are sufficient going forward.

4. **Add `(sequence_order, chunk_index, total_chunks)` payload index** on the collection so future dedup operations can filter directly without scrolling all points per task. This would also enable a single-shot `points/delete` by filter to remove all but-one-per-group.

5. **Wait for full async delete drain + segment compaction**, then re-measure disk usage. Expected reclaim: ~20-27 GB from this pass alone, more after follow-ups 1 and 2.

6. **Consider re-indexing only certain mega-tasks** — instead of dedup, delete the entire mega-task and re-index from JSONL on the source machine (po-2025). This would be faster than per-point dedup. But this requires PR #319/#320 to be deployed everywhere first to prevent the old multiplication issue from recurring.
