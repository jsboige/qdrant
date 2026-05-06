## [PHASE A — RUN 2026-05-06] PARTIAL SUCCESS — diagnostic corrigé, 2.16 M points supprimés, root cause issue #2018 ouverte

### TL;DR

Phase A exécutée par claude/myia-ai-01 le 2026-05-06. **Résultat : succès partiel + correction de diagnostic majeure**.

| Métrique | Avant | Après (live) | Δ |
|---|---|---|---|
| Points | 60,425,272 | 60,157,069 | **-268K immédiats**, ~2.16M en queue async |
| Disque VHDX | 762 GB | 760 GB | -2 GB (optimizer pas fini) |
| Statut | green | yellow (optimizer working) | OK |
| Smoke tests | n/a | 3/3 PASS | OK |

### Correction du diagnostic — pattern réel = INTRA-task, pas cross-task

L'audit Phase 1 (po-2025) supposait que le pattern était **cross-task** (`/resume` et `/compact` créant des `task_ids` différents pour la même conversation). **C'est faux**.

Le pattern réel est **intra-task** : pour un même `task_id`, on a 3× à 1166× de duplication des MÊMES chunks (même `(sequence_order, chunk_index, total_chunks)`, même `content` byte-identique, mais points Qdrant différents).

**Si on avait DELETE par task_id filter** comme prévu initialement → on aurait perdu de vraies données (UNIQUE chunks). L'agent a donc pivoté vers du dedup point-level.

### Approche utilisée

1. **Profilage facets** : 2002 `task_id` CC distincts identifiés via `qdrant facet API`
2. **Sous-ensemble traité** : 30 top tasks de 1K-100K points chacune (excluant top 5 méga-tasks >500K et tail <1K — budget temps)
3. **Per-task dedup** : scroll → grouper par `(seq, ci, tc)` → garder 1 (lowest UUID) → DELETE le reste async batch=200
4. **Optimizer trigger** : PATCH `default_segment_number=8` pour forcer rebuild + reclaim disque
5. **Smoke tests** : 3 queries sémantiques → toutes OK (search fonctionnel)

### Numbers

- **30 tasks traités, 2,160,575 points supprimés en 10.3 min** (script script + setup ~25 min total)
- Median dup factor : ~50× (extrêmes : 3× à 1166×)
- Top tâche traitée : `claude-d--Dev-CoursIA--c3cd5d85` = 99,849 points → 1,656 unique → **98,193 supprimés**
- Sanity stop **PAS** déclenché (bien sous le ceiling 30M)

### Limitations rencontrées

1. **Mega-tasks différées** : 5 tasks >500K points (~7M total dont la plus grosse `claude-c--dev-CoursIA--11f2624e` à 3.43M) : trop lent à scroller dans le budget 30 min. Recommandé : runs séparés ~1-2h chacune.
2. **Schema payload** : `sequence_order`, `chunk_index`, `total_chunks` ne sont **pas indexés** côté Qdrant → impossible de filter directly, on doit scroller la task entière puis grouper en local. Ajouter des indexes accélérerait significativement les futurs runs.
3. **Async deletes** : `wait=false` sur les batches → `points_count` baisse progressivement après run (drain async). Le disque ne sera totalement reclaim qu'après optimizer rebuild complet (30-90 min sur 60M points).

### Root cause fix — Nouvelle issue #2018

Le pattern intra-task observé révèle un bug structurel **distinct de ce que #1985 décrivait**. Issue dédiée créée :

**#2018 bug(roo-state-manager): chunk_id non-déterministe → multiplication intra-task observée jusqu'à 1166x (correction de #1985)**

Cause racine : `ChunkExtractor.ts:211/252/311/477` utilisent `uuidv4()` (random) comme `chunk_id`, et `ChunkExtractor.ts:360-361` dérivent l'UUID Qdrant via `uuidv5(${chunk.chunk_id}_part_${chunkIndex})` — donc **ID effectivement aléatoire** entre runs. Combiné aux 12 instances MCP concurrentes, `dedupByContentHash` (#319 PR) perd la course → duplication systématique.

Fix proposé : `chunk_id = uuidv5("${task_id}|${seq}|${role}|${content_hash}", UUID_NAMESPACE)` → re-indexation idempotente.

Voir #2018 pour les options détaillées + plan de migration.

### Livrables côté repo `jsboige/qdrant`

- **`myia_qdrant/scripts/dedup_cc_tasks.ps1`** — script per-task dedup (utilisé pour ce run)
- **`myia_qdrant/scripts/cleanup_pipeline.ps1`** — wrapper orchestrateur (facets → dedup → optimizer → smoke)
- **`myia_qdrant/scripts/smoke_test_search.ps1`** — validation post-cleanup
- **`myia_qdrant/scripts/trigger_optimizer.ps1`** — force rebuild
- **`myia_qdrant/scripts/capture_post_state.ps1`** — capture état
- **`myia_qdrant/reports/phase-a-cleanup-2026-05-06.md`** — rapport complet
- **`myia_qdrant/reports/cc_task_facets.json`** — distribution complète des 2002 task_ids CC (pour runs futurs)
- **`myia_qdrant/reports/dedup_progress.jsonl`** — log per-task du run
- **`myia_qdrant/reports/dedup_run.log`** — log d'exécution complet

### Suite recommandée

1. **Court terme** : runs Phase A sur les 5 mega-tasks (>500K) en sessions dédiées (1-2h chacune). Estimation : ~6-7M points supplémentaires récupérables, ~80-100 GB.
2. **Moyen terme** : merge fix #2018 → empêche **toute future duplication** quel que soit le scénario d'indexation (concurrent, /resume, redémarrage MCP).
3. **Long terme** : ajouter payload index sur `sequence_order/chunk_index/total_chunks` pour accélérer les runs de cleanup futurs (de 30s/task à 1s/task).

— claude/myia-ai-01/qdrant-workspace, 2026-05-06 11:46
