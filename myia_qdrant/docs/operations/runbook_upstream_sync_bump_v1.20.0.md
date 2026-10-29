# Runbook — Sync upstream + montée d'image Qdrant v1.19.2 → v1.20.0 (2 tenants)

Lane `myia-ai-01:qdrant` · rédigé 2026-10-28 00:35 · **Phase A exécutée 29/10 (PR #6) · Phase B exécutée 29/10 17:15 (students) · Phase C en attente (compaction Q7 + soak 24 h)**

## 0. Mesures de départ (faites le 28/10 00:30)

| Élément | Valeur mesurée |
|---|---|
| Image épinglée, les **deux** tenants | `qdrant/qdrant:v1.19.2` (prod ligne 13, students ligne 5) |
| Dernière version amont | **v1.20.0**, publiée **2026-10-22** |
| `HEAD` (master) vs `upstream/master` | **41 commits de nous / 172 d'upstream** |
| Commits upstream depuis `v1.19.2` | **172** |
| Fichiers **Rust** modifiés par nos commits | **0** (aucun fichier sous `lib/ src/ tests/ config/`) |
| Nos seuls fichiers hors `myia_qdrant/` | `CLAUDE.md`, `.gitignore` |
| Prod | `Up 21 h (healthy)`, 117 collections, 3 553 762 pts green |
| Students | `Up 21 h (healthy)`, **347 collections** `ws-*`, healthz 6335 = 200 |
| E: libre | 208,6 Go · VHDX 702,91 Go |

**Lecture** : nos 41 commits sont quasi exclusivement de l'outillage ops dans `myia_qdrant/`. Le merge upstream **ne devrait produire aucun conflit** ; le risque réel n'est pas le merge, c'est **le changement de comportement du moteur**.

## 1. Ce que v1.20.0 change et qui nous concerne

Trois points, classés par impact réel sur notre déploiement :

1. **Géométrie HNSW modifiée** — `floor()` dans l'assignation de niveau (PR #11166) : 6,25 % des points au niveau 1 à `m=16`, au lieu de 25 %. **C'est le point qui compte** : un rebuild produit un graphe différent, donc **le recall peut bouger**. Les segments existants gardent leur graphe jusqu'à optimisation ; l'effet est donc progressif, pas immédiat.
   → **Conséquence de méthode : ne pas comparer le bench post-bump au chiffre de mai. Comparer au bench ARCHIVÉ du 07/10 (`tq_recall_bench_20261007_int8_migration.md`), même N, même `ef`.**
2. **`service.enforce_internal_auth` passe à `true` par défaut dès qu'une clé API est configurée** (PR #10854, §Security). En **mono-nœud sans P2P interne**, c'est vraisemblablement sans effet — mais **vérifier au démarrage** : absence d'erreur `enforce_internal_auth`, et `/collections` répond 200 avec la clé.
3. **TurboQuant `turbo8` / `turbo16`** et **`hnsw_config.inline_storage`** (vecteurs stockés dans le fichier HNSW, moins de disque). **On ne touche à rien** : on reste en `scalar int8 always_ram`. `inline_storage` est une piste pour plus tard — **un changement à la fois**.

Bénéfices attendus et vérifiables : recherche int8 plus rapide (kernels AVX512-VNNI, #10975), snapshots plus sûrs (noms uniques, jamais d'écrasement, timeout 60 s, #11206/#11221) — utile à notre script de backup.

## 2. Ordre des opérations — la compaction AVANT le bump

**Raison** : le bump déclenche une vague d'optimisation/re-quantification qui **écrit** dans le VHDX. Compacter d'abord rend ~500 Go et laisse de la marge pour cette vague. Faire l'inverse gonfle le VHDX puis il faut re-compacter.

1. Compaction VHDX (fenêtre dédiée, 1 UAC, qdrant-only)
2. Sync git (aucune coupure)
3. Bump **students** (coupure de quelques secondes)
4. Bump **production** (coupure de quelques secondes + vague d'optimisation en ligne)

## 3. Phase A — Sync git (aucune coupure, réversible)

```bash
cd /d/qdrant
git checkout -b sync/upstream-v1.20.0 master
git merge upstream/master            # attendu : 0 conflit (0 fichier Rust touché de notre côté)
git diff --stat HEAD~1                # relire ce qui entre
git push -u origin sync/upstream-v1.20.0
gh pr create --repo jsboige/qdrant --base master --head sync/upstream-v1.20.0
```
- **CI désactivée sur le fork** → la validation est locale, pas par la CI.
- **Pas de build Rust** : on consomme l'image **officielle** `qdrant/qdrant:v1.20.0` de Docker Hub. Le fork ne sert qu'à l'outillage ops. *(C'est le point qui simplifie tout : pas de `cargo build`.)*
- Si conflit inattendu : **lire les marqueurs, comprendre les deux côtés, décider**. Jamais de résolution aveugle, jamais de `-X ours/theirs` global.

## 4. Phase B — Students d'abord (risque le plus faible)

Students = **347 collections `ws-*`, toutes régénérables**, pas de baseline de recall à protéger.

```bash
docker pull qdrant/qdrant:v1.20.0
# éditer docker-compose.students.yml : image -> qdrant/qdrant:v1.20.0
docker compose -f myia_qdrant/docker-compose.students.yml up -d
```
**Critères d'acceptation** : healthz 6335 = 200 · **347 collections** · `401` sans clé / `200` avec · une recherche renvoie des hits · aucune erreur `enforce_internal_auth` dans les logs. Laisser tourner **24 h** avant de toucher à la prod.

## 5. Phase C — Production

**Pré-requis bloquants** :
- backup du jour **`Backup done`** (jamais dans la fenêtre 02:17-02:50) ;
- débit d'ingest mesuré (**pas** pendant une vague — leçon du 26/10) ;
- bench de référence **archivé** disponible ;
- E: avec de la marge (viser > 400 Go après compaction).

```bash
# 1) snapshot AVANT (l'opération touche le code de stockage -> snapshot justifié, contrairement à un PATCH de quantization)
.\myia_qdrant\scripts\qdrant_snapshot_backup.ps1 -SharedPath     # copie locale D:\qdrant-backups
# 2) bump
#    éditer docker-compose.production.yml : image -> qdrant/qdrant:v1.20.0
docker compose -f myia_qdrant/docker-compose.production.yml up -d
```
**Critères d'acceptation** (les mêmes que la clôture de compaction, plus le recall) :
- healthz ×3 = 200 ; **117 collections** ; `roo_tasks` **green**, `optimizer=ok` ;
- **point-count AVANT/APRÈS comparé** (pas seulement le health) ;
- `/dev/sdd` **par LABEL** `qdrant-e`, **sentinelle 285 o** en namespace PID-1 ;
- **point-count identique** avant/après (aucune perte) ;
- **bench latence + recall vs bench ARCHIVÉ du 07/10**, même N, même `ef` ;
- surveiller la **vague d'optimisation** : `optimizer_status` reste `ok` même en pleine vague — le seul témoin est le **mtime des `segment.json`** (`find .../segments -name segment.json -newermt <t0>`), retombée en ~10 min à 1 h.

## 6. Rollback

| Situation | Geste |
|---|---|
| Erreur au démarrage, conteneur instable | re-épingler `v1.19.2`, `up -d --force-recreate`, revérifier les critères |
| Perte de points | **ne pas réparer à chaud** : snapshot du jour → `qdrant_snapshot_restore.ps1` (RTO mesuré ~1 min 40) |
| Recall effondré | rollback image, **conserver** le bench comme preuve |
| Students cassé | rollback image ; données régénérables, pas de restauration nécessaire |

**Rollback = une ligne de compose + `up -d`.** C'est ce qui rend l'opération acceptable.

## 7. Ce qu'il ne faut PAS faire

- Ne pas merger upstream puis déployer dans la même heure sans avoir lu `git diff` de la config.
- Ne pas activer `inline_storage` ni changer la quantization pendant le bump (un changement à la fois).
- Ne pas comparer le recall post-bump à un chiffre non archivé — **c'est exactement l'erreur qui a coûté la nuit de forensique des 05-06/10**.
- Ne pas exécuter pendant la fenêtre de backup 02:17-02:50.
- Ne pas oublier que **`docker compose restart` ne suffit pas** pour changer d'image : il faut `up -d` (recréation).

## 8. Durées estimées

| Phase | Durée | Coupure |
|---|---|---|
| A — sync git + PR | 15 min | aucune |
| B — students | 10 min | ~10 s |
| C — prod (pull + recreate + vérifs) | 30 min | ~10-30 s |
| C — vague d'optimisation | 10 min → 1 h | aucune (en ligne) |
| C — bench | 20 min | aucune |
| **Total hors compaction** | **~1 h 15 actives** | **quelques dizaines de secondes** |

## 9. Journal d'exécution (29/10/2026)

**Phase A — sync git (FAITE, ~17:00).** Branche `sync/upstream-v1.20.0` (from master) · `git merge upstream/master` = **172 commits amont / 1083 fichiers (+79 756 / −20 843)** · **1 seul conflit**, `CLAUDE.md` (add/add) : la version fork est conservée (doc de déploiement MyIA), celle de l'amont reste lisible via `git show upstream/master:CLAUDE.md` — pointeur d'une ligne ajouté en `8cdf899b1`. Aucun fichier Rust touché par nos 42 commits ⇒ aucun conflit possible sur le moteur. **PR #6.** Merge commit `9917c3031`.

**Phase B — students (FAITE, 17:15).**
- `docker pull qdrant/qdrant:v1.20.0` a d'abord échoué `authentication required - incorrect username or password` (credential Docker Hub périmé) → **`docker logout`** puis pull anonyme OK, digest `sha256:9bfc89f9…`.
- `docker-compose.students.yml` épinglé `v1.20.0` + `up -d` (recréation obligatoire, pas `restart`).
- **Récupération à froid ~2 min** : 349 collections rechargées une à une (~0,4 s chacune) ⇒ pendant ce temps les connexions HTTP sont **abandonnées** (le serveur n'accepte pas encore) — **ce n'est pas une panne**, ne pas conclure à un crash.
- **Critères d'acceptation : TOUS VERTS** — version **1.20.0 build 222b2e44** (`GET /` + log de démarrage) · healthz 200 · **349 collections** (le runbook annonçait 347 : deux index `ws-*` créés depuis, pas une perte) · **401 sans clé / 200 avec** · probe `ws-009a20068fece012` dim 1536, 3 041 pts, `green` · **search 3 hits / 15 ms** · **aucune** ligne ERROR/WARN/`enforce_internal_auth` dans les logs.
- Les volumes students vivent dans `docker_data.vhdx` **sur C:** (663,5 Go, C: à 707 Go libres) ⇒ **le bump students n'écrit PAS dans le VHDX E:** — la règle « compaction avant bump » ne contraint que la **production** (Phase C).

**Phase C — production : EN ATTENTE.** Prérequis bloquants : compaction VHDX (**Q7 — clic UAC du user**), soak 24 h des students, backup du jour, débit d'ingest mesuré hors vague, bench vs **archive du 07/10**.

**Enquête « optimisations disponibles » en v1.20.0 (lu dans le tree mergé, pas dans les notes de release)**
| Nouveauté | Où | Ce que ça change | Verdict pour nous |
|---|---|---|---|
| **TurboQuant `turbo8`** | datatype de collection (`"datatype":"turbo8"` sur la def vector) + enum `Bits8` (`lib/segment/src/types.rs`) | TurboQuant 8 bits compressé, à la place de `Turbo4`/`Uint8` | **à tester** sur une collection témoin — pas de changement en prod tant que le recall n'est pas benché |
| **TurboQuant `turbo16`** | datatype (`Turbo16`, `types.rs` + `graph_inline.rs`) | TurboQuant 16 bits ≈ quasi sans perte | idem — option « qualité » si le recall prime |
| **Kernels VNNI** | `lib/quantization/src/turboquant/simd/{query8bit,query16bit}/x64.rs` | SIMD AVX512-VNNI sur les chemins turbo 8/16 bits | explains the latency upside of turbo8 vs scalar int8 — **à mesurer, pas à supposer** |
| **`hnsw_config.inline_storage`** | `lib/segment/src/types.rs:885` + proto (`collections.proto:262`) | vecteurs stockés **dans le fichier du graphe HNSW** ; **contraintes** : exige `quantization` activée, incompatible **multivectors** | **piste disque** : moins de fichiers/seeks sur E:. `roo_tasks` est mono-vecteur + int8 ⇒ compatible. Un changement à la fois |
| HNSW `m: 0` / `payload_m` | `config/config.yaml` | `m=0` désactive le graphe principal ; `payload_m` devient le nombre de liens payload-aware | hors périmètre (qualité/recall) |
| `enforce_internal_auth` | `config/config.yaml` (service) | défaut **activé** si une clé API est configurée ; **sans effet en mono-nœud** (aucun pair) ; rotation via `alt_api_key` | vérifié au démarrage students : **aucune erreur** ✔ |
| Snapshot durci | amont | noms uniques (plus d'écrasement), timeouts 60 s | utile pour notre script de backup |

