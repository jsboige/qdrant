# Phase A Mega-Task Cleanup — `claude-c--dev-CoursIA--11f2624e` — 2026-05-06

**Scope** : suite Phase A initiale. Cible la plus grosse task CC (3.43M points, dup factor ~942×).
**Operator** : myia-ai-01 (interactif, post-MCP redeploy #2018 Phase 1).
**Status** : SUCCESS — 3.45M deletes en 2 passes (15 min compute + drain async).

## Cumul Phase A (run initial + mega-task)

| Run | Deletes | Durée scroll+delete | Drain |
|---|---|---|---|
| Phase A initial (top 30 tasks 1K-100K) | 2,160,575 | 10.3 min | ~30 min |
| Mega-task pass 1 (avec SCROLL_FAIL 500 à iter=480) | 2,391,354 | 10.0 min | ~25 min |
| Mega-task pass 2 (clean) | 1,058,803 | 4.6 min | ~10 min |
| **TOTAL** | **5,610,732** | **24.9 min compute** | — |

## État avant/après session

| Métrique | T0 (11:24) | T1 (14:22) | Δ |
|---|---|---|---|
| Points collection | 60,425,272 | 55,124,783 | -5.30M |
| Disque VHDX used | 762 GB | 722 GB | **-40 GB libérés** |
| Disque VHDX free | 60 GB | **100 GB** | +40 GB |
| Status | green | green | — |
| Segments | 1194 | 1154 | optimizer rebuild fini |
| Search latency (3 queries) | n/a | 0.3-0.5 s | post-rebuild OK |

## Mega-task spécifique

| Métrique | Avant | Après |
|---|---|---|
| Points task_id `claude-c--dev-CoursIA--11f2624e` | 3,434,436 | 47,482 |
| Groupes uniques `(seq, ci, tc)` | — | 3,646 |
| **Factor de duplication** | — | **942×** (3.45M / 3.6K) |

Note : les 47,482 points résiduels = 3,646 chunks uniques + ~44K nouveaux chunks indexés pendant la fenêtre de 30 min de cleanup (l'indexation continue).

## Run details — pass 1

- Démarré 12:54:07
- SCROLL_FAIL Qdrant 500 Internal à iter=480 (2,395,000 points scrollés sur 3,434,436)
- Le script a continué avec le sous-ensemble : 2,395,000 → 3,646 groupes → 2,391,354 deletes
- Durée : 602.3s (10 min)
- failed_batches=0 (tous les batches DELETE acceptés)

## Run details — pass 2

- Démarré 13:40:57 (après drain de pass 1)
- Scroll complet : 1,062,449 points (drained baseline 1,085,956 + nouveaux pendant le scroll)
- 3,646 groupes (idem pass 1 — confirme idempotence du regroupement)
- 1,058,803 deletes
- Durée : 278.3s (4.6 min)

## Pourquoi 2 passes étaient nécessaires

Le 500 sur scroll iter=480 a coupé le 1er run au 2/3. Le script a quand même dédupé sur ce qu'il avait vu, mais ~1.04M points (la queue non scrollée) restaient duplicates. La 2e passe les a nettoyés une fois le drain de pass 1 terminé (Qdrant ne re-scrolle pas les points déjà supprimés en async, donc le 2e scroll voyait surtout les 1.04M restants + nouveaux).

## Smoke tests

3 queries sémantiques diversifiées :
- "Phase A Qdrant cleanup duplicate task_ids" → 3 hits, 0.81 score, 0.49s
- "Lean theorem proof Pareto efficiency" → 3 hits, 0.69 score, 0.24s
- "Docker container restart healthcheck" → 3 hits, 0.78 score, 0.31s

Toutes vertes. Latence excellente post-rebuild.

**Observation** : queries 1+2 retournent des doublons identiques sur des tasks **non-mega** (`claude-g--Mon-Drive-Maintenance--b96790e` 3× même chunk, `claude-d--dev-CoursIA--49e289d2` 2× même chunk). Confirme que la duplication intra-task est **généralisée**, pas limitée aux tasks >100K vues en Phase A.

## Reste à nettoyer

Per `cc_task_facets.json` (snapshot du 2026-05-06 pre-cleanup, à rafraîchir) :

| Task | Pts pré-Phase A | Status |
|---|---|---|
| `claude-c--dev-CoursIA--11f2624e` | 3,434,436 | ✅ DONE (47K résiduels) |
| `claude-c--dev-CoursIA--a6763512` | 1,606,331 | TODO mega-task #2 |
| `claude-c--dev-CoursIA--8dbbe590` | 1,304,837 | TODO mega-task #3 |
| `claude-d--nanoclaw--75acc9e8` | 1,039,776 | TODO mega-task #4 |
| `claude-c--dev-CoursIA--703a9350` | 993,466 | TODO mega-task #5 |
| Tasks 100K-500K (range exclu Phase A initial) | ~2M cumulés | TODO secondaire |

## Outils utilisés (committed dans `myia_qdrant/scripts/`)

- `dedup_cc_tasks.ps1` — moteur per-task dedup
- `cleanup_pipeline.ps1` — wrapper orchestrateur (facets → dedup → optimizer → smoke)
- `smoke_test_search.ps1` — 3 queries sémantiques de validation
- `trigger_optimizer.ps1` — force rebuild segments
- `capture_post_state.ps1` — snapshot état collection + disque

## Logs

- `mega_run.log` + `mega_progress.jsonl` — pass 1
- `mega_run2.log` + `mega_progress2.jsonl` — pass 2
- `mega_pre_state.json` + `mega_post_state.json` — snapshots avant/après

## Projection — combien de temps avant disque plein

Hypothèses : 60.4M points accumulés en ~9 jours depuis migration VHDX → ~6.7M pts/jour, ~85 GB/jour au rythme historique (essentiellement de la duplication).

| Scénario | Runway 100 GB libres |
|---|---|
| Statu quo (autres machines pas redéployées) | 1-3 jours |
| Tout redéployé Phase 1 (#339 chunk_id deterministic) | 30-70 jours |
| Phase 1bis (migration script) + Phase 2 (#351 preflight) déployés partout | 6-18 mois |

— claude/myia-ai-01/qdrant, 2026-05-06 14:30
