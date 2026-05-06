## TL;DR

Chaque réindexation d'une tâche crée de **nouveaux Qdrant point IDs** pour des chunks au contenu **byte-identique**. Conséquence observée 2026-05-06 sur la collection prod `roo_tasks_semantic_index` : **multiplication intra-task de 3× à 1166×** (médiane ~50×) sur les sessions Claude Code, soit **~26 M points dupliqués (~300 GB)** parmi les 60 M.

L'effort #1985 / PRs #319 (dedup contentHash) + #320 (block CC auto-indexing) a réduit la création de **nouveaux** duplicates côté CC, mais la cause structurelle subsiste : **les point IDs ne sont pas dérivés du contenu**. Sous concurrence (12 instances MCP simultanées), le filtre `dedupByContentHash` perd la course → duplication redémarre dès qu'on réactive l'indexation.

## Diagnostic technique

### Fichier en cause

`mcps/internal/servers/roo-state-manager/src/services/task-indexer/ChunkExtractor.ts`

```ts
// Lignes 211, 252, 311, 477 — chunk_id randomisé
chunk_id: uuidv4(),

// Lignes 358-361 — UUID Qdrant dérivé du chunk_id randomisé
const compositeId = `${chunk.chunk_id}_part_${chunkIndex}`;
const deterministicUuid = uuidv5(compositeId, UUID_NAMESPACE);
```

Le mot "deterministic" en ligne 361 est **trompeur** : `uuidv5(seed)` est déterministe **mathématiquement**, mais comme `seed` contient `chunk.chunk_id` qui est `uuidv4()` (random), l'UUID résultant est **effectivement aléatoire** entre runs.

### Pattern observé (data live, 2026-05-06)

Sur 100 chunks samplés dans la tâche médiane `claude-D--dev-roo-extensions--claude-worktrees-...9ae5c032...` :

- **609 points Qdrant** pour seulement **41 tuples uniques** `(sequence_order, chunk_index, total_chunks)` → **~15× duplication intra-task**
- Une chunk single-tuple (`seq=0, ci=1, tc=2`) a **38 copies** Qdrant
- Toutes les copies : **SHA-256 du `content` identique**, **même timestamps**, mais **point IDs différents** ET **`original_chunk_id` différent**
- `original_chunk_id` différents → confirme que `uuidv4()` a été appelé à chaque indexation

### Pourquoi `dedupByContentHash` (#319 PR) ne couvre pas

`VectorIndexer.ts:370-450` (`dedupByContentHash`) protège contre la **réindexation d'un chunk dont le hash existe déjà** dans Qdrant. Mais :

1. **Race conditions** : 12 instances MCP concurrentes (1 par VS Code workspace) appellent toutes `qdrant.scroll(filter: contentHash=...)` quasi-simultanément. Aucune ne voit le hash → toutes upsertent. **Tous créent des points avec des IDs différents** (uuidv4 source) → les 12 points cohabitent.
2. **Données pré-#319** : tous les points indexés avant le merge de #319 n'ont **pas** de payload `contentHash`. Ils sont invisibles au filtre. La 13e indexation post-#319 voit "aucun match" et upserte un 13e point.
3. **Asymétrie** : `dedupByContentHash` **skip l'upsert** mais ne **DELETE pas les anciens duplicates**. Donc le passé contaminé reste contaminé.

### Impact mesuré

| Métrique | Valeur |
|---|---|
| Total points `roo_tasks_semantic_index` (06/05) | **60.43 M** |
| Points source `claude-code` | 31.95 M (51.8 %) |
| `task_id` CC distincts | 2002 |
| Top 30 task_ids = | 19.58 M points (61 % CC) |
| Plus grosse tâche (`...11f2624e...`) | 3.43 M points (~400× duplication) |
| Dup factor médian | ~50× |
| Espace dupliqué estimé | **~300 GB sur 700 GB total** |

Source : audit `D:\qdrant\myia_qdrant\reports\phase-a-cleanup-2026-05-06.md` (Phase A run 2026-05-06).

## Proposition de correction

### Option 1 (recommandée) — chunk_id déterministe par contenu+position

Remplacer les `uuidv4()` aux lignes 211, 252, 311, 477 par un UUID v5 dérivé de :

```ts
// Avant (lignes 211, 252, 311, 477) :
chunk_id: uuidv4(),

// Après :
chunk_id: uuidv5(`${task_id}|${sequence_order}|${role}|${content_hash}`, UUID_NAMESPACE),
```

Avec `content_hash = sha256(content).slice(0,16)` (déjà calculé en aval pour `contentHash` payload — récupérer plus tôt).

Effets :
- ✅ Re-indexation idempotente : même chunk → même ID → upsert overwrite, pas de duplication
- ✅ Race-condition immune : les 12 MCPs concurrents convergent sur le même ID → upsert dernière writer wins, pas 12 points
- ✅ Pas de payload index supplémentaire requis
- ⚠️  Migration : les points pré-fix ont des IDs random (orphelins) → cleanup script à part (cf. `dedup_cc_tasks.ps1` côté `jsboige/qdrant` repo)

### Option 2 (fallback simple) — DELETE par task_id avant chaque indexation

Avant la première upsert d'une tâche dans une session d'indexation, faire :

```ts
await qdrant.delete(COLLECTION_NAME, {
  filter: { must: [{ key: 'task_id', match: { value: task_id } }] }
});
```

Effets :
- ✅ Garantit pas de duplicates (table-rase)
- ❌ Gaspille des appels embedding sur les chunks inchangés (impact coût + latence)
- ❌ Window de "trou" de quelques secondes où la tâche n'est pas searchable
- ⚠️  Ne corrige pas la race entre 12 MCPs si plusieurs traitent la même tâche en même temps

### Option 3 (optimal mais plus de code) — diff-based incremental

1. Pre-index : `qdrant.scroll({filter: task_id=X, with_payload: ['sequence_order','chunk_index','total_chunks','contentHash']})` pour récupérer le set existant
2. Côté code : calculer le set local des `(seq, ci, tc, hash)` à indexer
3. Insert seulement les chunks nouveaux ; DELETE seulement les chunks orphelins (messages édités/supprimés)

Effets :
- ✅ Optimal en coût embedding (zéro appel sur l'inchangé)
- ✅ Détecte les éditions de messages (orphelin → DELETE)
- ❌ Plus de code, plus de tests
- ⚠️  Ne résout PAS la race-condition seule — l'Option 1 (chunk_id déterministe) reste prérequis

**Recommandation** : Option 1 en MVP. Option 3 en suivi si on veut optimiser le coût embedding.

## Plan de migration

### Phase 1 — fix code (cette PR/issue)

- [ ] Modifier `ChunkExtractor.ts` lignes 211, 252, 311, 477 → `chunk_id` déterministe (formule Option 1)
- [ ] Modifier `ChunkExtractor.ts:360-361` pour utiliser la nouvelle formule directement (sans passer par `${chunk.chunk_id}_part_${chunkIndex}`)
- [ ] Vérifier que `VectorIndexer.ts:541` (`id: subChunk.chunk_id`) propage bien
- [ ] Backfill `contentHash` payload sur tous les nouveaux upserts (déjà fait par `VectorIndexer.ts:543`, vérifier couverture)
- [ ] Test unitaire : indexer 2× la même tâche → vérifier que `qdrant.count(filter=task_id=X)` est stable
- [ ] Test concurrence : indexer même tâche depuis 3 instances en parallèle → vérifier idempotence

### Phase 1bis — script de migration des IDs existants (RECOMMANDÉ avant merge Phase 1)

Le fix Phase 1 prévient les **futures** duplications mais ne corrige pas l'état historique : ~60M points existants ont des IDs random. Sans migration, après merge #2018 :
- Les vieux points avec ID random et **sans `contentHash` payload** (pré-#319) sont invisibles à `dedupByContentHash`
- Une nouvelle indexation post-fix créerait un point déterministe à côté de l'ancien random → **co-habitation** au lieu d'overwrite
- Convergence imparfaite, le bug visible se prolonge

**Solution propre = migration des IDs existants en place, sans re-embedding** :

#### Spec du script `migrate_chunk_ids` (à écrire et committer dans `myia_qdrant/scripts/`)

**Inputs** :
- `--source-filter` : par défaut `source=claude-code` (cible le pattern observé), extensible à `source=roo`
- `--batch-size` : taille scroll (default 1000)
- `--max-points` : sanity stop
- `--max-minutes` : time budget
- `--dry-run` : log les opérations sans exécuter
- `--resume-from-offset` : reprise après interruption (depuis `migration_state.json`)
- `--pause-ms` : pacing entre batches (default 100ms)

**Algorithme** :

```pseudo
state = read_migration_state()
offset = state.last_offset or null

loop:
    batch = qdrant.scroll(filter=source_filter, with_payload=true, with_vector=true, offset=offset, limit=batch_size)

    upserts = []
    deletes = []
    for point in batch.points:
        payload = point.payload
        # Compute deterministic ID
        content_hash = sha256(payload.content).hex().slice(0, 16)
        composite = f"{payload.task_id}|{payload.sequence_order}|{payload.role or 'na'}|{content_hash}"
        new_id = uuid5(composite, UUID_NAMESPACE)

        if new_id == point.id:
            continue  # already migrated (or post-fix point), skip

        # Build new payload: add contentHash if missing
        new_payload = {**payload, "contentHash": content_hash}

        upserts.append({"id": new_id, "vector": point.vector, "payload": new_payload})
        deletes.append(point.id)

    if upserts:
        qdrant.upsert(collection, points=upserts, wait=False)  # async
    if deletes:
        qdrant.delete(collection, points=deletes, wait=False)  # async

    state.last_offset = batch.next_page_offset
    state.processed_count += len(batch.points)
    state.upserted_count += len(upserts)
    state.deleted_count += len(deletes)
    save_migration_state(state)

    if not batch.next_page_offset: break
    if elapsed > max_minutes: break
    if state.processed_count > max_points: break
    sleep(pause_ms)

# Final: trigger optimizer to physically reclaim
qdrant.update_collection(optimizers_config={"default_segment_number": 8})
```

**Garde-fous critiques** :
- **Race avec indexer actif** : un nouvel upsert pendant la migration peut créer (ID random, contentHash). Le `dedupByContentHash` côté indexer DOIT rester actif pour l'éviter — sinon co-habitation pendant la fenêtre de migration. Recommandation : tourner avec MCP arrêté ou en heures creuses.
- **Vector preserved** : `with_vector: true` doit être garanti dans le scroll. Sinon perte de l'embedding → le point devient inutilisable.
- **Atomicity per point** : si upsert réussit mais delete échoue → 2 points (acceptable, le 2e run finit le delete). Si delete réussit mais upsert échoue → perte définitive du point. Donc ORDER : upsert AVANT delete, et **vérifier le code retour upsert** avant de queue le delete.
- **Idempotent** : `new_id == old_id` skip. Si la migration est interrompue puis reprise, les points déjà migrés sont skip naturellement.

**Coût estimé** sur 60M points :
- Scroll avec_vector batch=1000 : 60K iters × ~3s = ~50h sequentielles, ~5-10h en parallèle multi-thread
- Upsert async batches : ~3-5h
- Delete async batches : ~3-5h
- Optimizer rebuild post-migration : 30-90 min
- **Total : ~10-15h sur une nuit, ZÉRO appel embedder**

**Livrables attendus** :
- [ ] `myia_qdrant/scripts/migrate_chunk_ids.ps1` (ou `.py` — Python plus adapté pour gérer les vectors 2560 dims efficacement)
- [ ] `myia_qdrant/scripts/migrate_chunk_ids.README.md` (usage + plan de rollback)
- [ ] Test unitaire : migrer 1 point en dry-run + live, vérifier round-trip search OK
- [ ] Pre-flight check : verify backup snapshot exists OU disk free > 200 GB pour fallback restore

**Comparatif des approches de migration** :

| Approche | Coût embedding | Convergence | Disponibilité search | Reversible |
|---|---|---|---|---|
| Migration IDs in-place (cette section) | **0** | ✅ complète | ✅ continue | ❌ ID changé |
| Pre-DELETE par task_id pré-indexation | 5-10% | partielle (active tasks only) | ❌ trous | n/a |
| Backfill `contentHash` payload seul | 0 | partielle (suffit si IDs random sont OK) | ✅ | ✅ |
| Réindexation totale | 100% (~9 jours) | ✅ | ❌ | n/a |

**Recommandation** : migration IDs in-place. Coût compute pur, zero $ embedding, convergence complète, search continue. Risque : race condition avec indexer actif → mitiger en arrêtant les MCPs OU en heures creuses (mais le `dedupByContentHash` couvre la fenêtre une fois `contentHash` backfilled).

### Phase 2 — cleanup duplicates intra-task pré-existants (déjà entamé)

Script `D:\qdrant\myia_qdrant\scripts\dedup_cc_tasks.ps1` (côté repo `jsboige/qdrant`) traite déjà les duplicates intra-task observés. Run 2026-05-06 a supprimé 2.16 M points en 10.3 min sur top 30 tasks. Reste à passer sur les 5 mega-tasks (>500K points) en runs séparés (~1-2h chacune).

**Note** : la Phase 2 (dedup intra-task) et la Phase 1bis (migration IDs) sont **complémentaires** :
- Phase 2 réduit le volume de points à migrer (60M → 35M post-cleanup) → réduit le coût Phase 1bis
- Phase 1bis garantit que la dedup ne se reformera pas après merge Phase 1

**Ordre suggéré** : Phase 2 (cleanup, libère du disque immédiatement) → Phase 1 (merge fix code) → Phase 1bis (migration IDs, finalise convergence) → Phase 3 (vérification).

### Phase 3 — vérification

- Mesurer `points_count` sur 7 jours après merge Phase 1bis pour confirmer absence de croissance par duplication
- Smoke test sémantique régulier (`smoke_test_search.ps1` côté qdrant repo)
- Vérifier qu'aucun point n'a `contentHash` manquant après backfill : `qdrant.count(filter: must_not: [{is_empty: { key: 'contentHash' }}])` → doit être 0

## Tests reproductibles

```typescript
// Test à ajouter à VectorIndexer.test.ts
test('re-indexation idempotente — même contenu → mêmes points Qdrant', async () => {
  await indexTask(taskId);
  const before = await qdrant.count(COLLECTION_NAME, { filter: { must: [{ key: 'task_id', match: { value: taskId } }] } });
  await indexTask(taskId); // re-index
  const after = await qdrant.count(COLLECTION_NAME, { filter: { must: [{ key: 'task_id', match: { value: taskId } }] } });
  expect(after.count).toBe(before.count); // pas de duplication
});
```

## Références

- Issue parent : #1985 (correction du diagnostic — il ne s'agit PAS de cross-task `/resume` mais d'intra-task)
- Issue triage : #1987 (Phase A run 2026-05-06 a confirmé le pattern)
- Audit complet : `D:\qdrant\myia_qdrant\reports\phase-a-cleanup-2026-05-06.md` (côté repo `jsboige/qdrant`)
- Dashboard `workspace-qdrant` 2026-05-06 11:08-11:14 (myia-ai-01)
- PRs préventives mergées (insuffisantes seules) : roo-state-manager #319 (contentHash dedup), #320 (block CC auto-indexing)

## Sévérité

**P1** (en pratique P0 sur cette infra) — 49% du stockage `roo_tasks_semantic_index` (~300 GB) est de la dup, contribue à la pression disque qui a causé l'incident #1987. Sans ce fix, le problème reviendra toujours dès qu'un chunk se ré-indexe (croissance de tâche, /resume, redémarrage MCP).

— myia-ai-01 / Claude Code Opus 4.7, 2026-05-06
