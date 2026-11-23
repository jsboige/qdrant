# Incident 2026-11-23 — Nuit à 5 événements : phantom-segment ×3 + merge en boucle

**Date :** 2026-11-23 (00:40Z → 05:20Z, en cours au moment de l'écriture)
**Lane :** myia-ai-01:qdrant · **Audience :** arbitrage user + lane sweep du matin
**Escalade vivante :** `qdrant-degraded-merge-cycle-20261123T0348Z` (+ [DEGRADED] roo-extensions-b5 de 03:47Z « jusqu'au matin »)

## 1. Chronologie mesurée (toutes heures UTC — docker StartedAt fait foi)

| Heure | Événement | Action | Preuve |
|---|---|---|---|
| 22/11 20:43Z → 23/11 00:51Z | Wedge #3 (status:red, WARN loop, OWUI 1138 timeouts) | Restart #1 | green/ok, warm 428-543 ms, `fallback_used:false` |
| 01:47Z | Nightly backup : POST timeout 1800 s client, serveur continue (160→212 Go temp) | Vigie 45 min | — |
| 02:00Z | Wedge #4 (temp figé, WARN loop segment 90a6bc16, GET info 000/30 s, 3/3 recherches mortes) | Restart #2 (02:10:14Z) | healthy 02:24Z |
| ~02:30Z | Faux positif « verrou post-restart » (500 à 60 s pile, « 0ns ») | A/B discriminateur | **4,51 s → 0,40 s → 0,38 s = cache froid** |
| ~02:47Z | Blocage #5 : info GET bloqué (0 WARN !), I/O +29 Go/+19 Go en 27 min, CPU 46 % | Diagnostic : merge en vol — **pas de restart** | segments 299→303 |
| ~03:15Z | **Merge deadlocké** : I/O gel 45 s à 133/51,7 Go, CPU 42 % à vide, segments figés 3 cycles | Restart #3 (**03:18:44Z**) | healthy ~280 s, warm 0,45 s, sonde pair #1 (28,2 s) et #2 (9,7 s) PASS, [REPAIRED] pair |
| ~03:45Z | Re-forme (~27 min post-restart) : info re-bloqué, `count`/`internal_scroll_by_id` 60 s | Plan B : plus de restart | Merge ACTIF cette fois (97,9 Go lus/28 min ≈ 58 Mo/s) |
| 04:00-04:50Z | Merge-run : segments 303↔310, I/O 103→120 Go, 8 WARN deferred en 4 min (cycle 7) | Vigies bornées | Non convergent à 04:52Z |

## 2. Ce qu'on a appris (le cœur du dossier)

1. **Le restart n'est PAS une solution durable** : 3 restarts, 2 re-formes à ~25-30 min chacune. Le cycle restart→merge-backlog→blocage est **structurel**. Un 4ᵉ restart est exclu.
2. **Deux phases distinctes de blocage lecture** :
   - **Wedge phantom-segment** (classe 15/11, 16/11, 23/11 #1-#4) : boucle WARN martelée, segment proxy « still in use » → restart débloque (pour ~30 min).
   - **Merge en vol** (nouveau, #5) : **0 WARN**, I/O soutenu, segments montent, info bloqué par verrous de segments — le restart le tue en vol et le relance (même état + WAL replay).
   - **Deadlock** (sous-cas du merge) : I/O morte + CPU à vide + segments figés — le restart débloque, mais la vague repart.
3. **Discriminateurs retenus** :
   - 2 requêtes identiques consécutives : chute ×10 = cache froid (attendre) ; constant = blocage (agir).
   - I/O `docker stats` sur 45 s : progression = travail ; gel = deadlock.
   - Segments : croissance lente = merge en cours ; chute = commit/convergence ; **hausses répétées = l'ingest alimente le backlog plus vite que le merge ne l'absorbe** (observé 303→310 cycle 6).
4. **Le déclencheur du backup** : le build du snapshot DANS le VHDX déclenche/aggrave la classe (wedge #4) ; Q68 (snapshots sur F:) retire ce déclencheur.
5. **Signatures de mensonge opérationnel** : healthz 200 toujours ; `status` green/ok pendant la panne ; points continuent de monter (ingest OK) — seules la latence réelle (info + recherche) et les WARN/IO parlent.

## 3. Options du matin (à arbitrer, classement de la lane)

### (d) Laisser converger — EN COURS, verdict à l'aube
Le merge travaille (58 Mo/s initiaux puis 12-15 Mo/s, ~25 Go écrits en 1,5 h). Si le backlog est fini, il commit à un moment. **Si la vigie 3 montre la convergence (segments < 290 + info 200), c'est la solution sans geste.**

### (c) Geler l'ingest 9 sièges + convergence à froid — RECOMMANDÉ si (d) échoue
Pièce de roo-extensions-b5 : `ROO_INDEXING_ENABLED=false` par siège (`background-services.ts:1136`, `:1257`, `state-manager.service.ts:190`), lu au démarrage, actif par défaut (absent du `.env` ai-01). **Mécanique** : si le deadlock est un cycle write-vs-merge (écriture tient un lock de segment, merge attend, écriture attend le merge), geler l'ingest casse le cycle ET borne le backlog. Coût : fraîcheur de l'index, 9 sièges à toucher (redémarrage de chaque hôte RSM pour relire l'env — la lane roo-extensions a la main). Hypothèse « les sièges alimentent les vagues » : SUPPOSÉ (les logs optimiseur ne tranchent pas la cause, seulement la forme) — mais cohérente avec la croissance du compteur segments sous ingest.

### (a) Q68 deploy — combiné avec (c), PAS seul
Le compose recreate = un restart : il re-déclenchera le merge-backlog au boot (WAL replay + récupération 299+ segments). À faire PENDANT un gel d'ingest (c), jamais seul. Prérequis déjà mesurés verts (backoff #4879, F: 797,8 Gio, dir cible). Si la collection converge AVANT la fenêtre 07:00, le déploiement redevient le plan normal.

### (b) Geste optimiseur ciblé — DERNIER RECOURS
`max_segment_size_kb`, `default_segment_number`, `max_optimization_threads` : toucher ces paramètres en plein churn = pièges connus (rebuild quant silencieux, vagues supplémentaires). À envisager à froid, sur bench, après analyse des logs optimiseur complets.

## 4. Ce qui est demandé au user (via registre, pas de question bloquante)

1. **GO pour option (c) si la convergence (d) n'est pas là au sweep 06:49** : roo-extensions gèle l'ingest des 9 sièges (coût : index en retard quelques heures), la lane qdrant déploie Q68 (a) dans la foulée, on relève le gel quand la collection est stable.
2. Sans réponse : on reste en (d) dégradé (recherches roo_tasks intermittentes/bloquées, écritures OK, petites collections OK) jusqu'au premier signal de convergence ; l'escalade reste ouverte avec les 2 cycles du mécanisme degraded-escalation.
3. Backup : nightly 24/11 à 02:17 se fera-t-il dans un VHDX bloqué ? Si toujours en (d) à cette heure : le run risque le wedge #6 pendant le build — la lane propose de **désarmer le schtask Qdrant-Snapshot-Daily pour une nuit** si le blocage persiste à 02:00Z du 24/11 (RPO offsite resterait 21/11 une nuit de plus).

## 5. Pièces jointes (preuves)

- Dashboard workspace-qdrant : [DEGRADED] `qdrant-degraded-merge-cycle-20261123T0348Z` (crossPost global+machine) · [CORRECTIF horloge] `qdrant-clockfix-restart3-20261123T0327Z` · [REPAIRED wedge #4] `qdrant-repaired-search-wedge-20261123T0237Z`
- DM roo-extensions-b5 : protocole sonde-pair (2 sondes espacées >5 min), pièce `ROO_INDEXING_ENABLED`, option (c)
- DM OWUI (réponse 26 h en retard) : leur URGENT 22/11 = même classe, dégradation interne prouvée
- PR #37 mergée : backup réutilise un snapshot serveur du jour (anti-empilement)
- Autoheal : `unless-stopped` depuis le 23/11 (SIGSEGV + `always` = résurrection pendant récupération)
- Mémoire : fiche `project_semantic_degradation_two_layers_20261115.md` (occurrences 3-5 + discriminateurs), `feedback_qdrant_autoheal_recovery.md`, `project_vhdx_cap_snapshot_temp_20261120.md`

## 6. État au moment de l'écriture (05:17 local / 04:17Z) — SUPERSÉDÉ par §7

## 7. Suite (matin 23/11) — convergence partielle, puis cycle write-vs-merge prouvé

- **~05:40Z** : convergence partielle — info 2,18 s, green/ok, warm 0,39 s, WARN 0, segments 300. **Erreur d'instrument commise et corrigée** : le « warm » était un A/B requête IDENTIQUE (chaud pour ces pages seules) ; 5 vecteurs divers à 06:05Z = 11,8-51,1 s = PAS service-grade. La sonde peer de 05:58Z (fallback texte) était juste. Leçon : preuve service = vecteurs divers, jauge = RAM (cache int8 ~48,8/60).
- **06:05-06:35Z** : vague de digestion ingest-driven (PAS post-restart — container up depuis 3 h) : RAM évincée 39→28 Gio, I/O 13 Mo/s, segments 300-303, WARN 0, erreur « fill query context timed out ~11-13 s ». La vague bloque la lecture et évince le cache.
- **~07:00Z** : **sonde décisive 500 à 60 s = chemin BLOQUÉ**, avec le tableau complet du **cycle write-vs-merge** : écritures OK (points montent), lecture bloquée derrière le merge, WARN 0, segments figés, I/O modéré — l'état que l'option (c) (gel d'ingest) est conçue pour casser. **Registre Q17 : (c) exige le GO user ; défaut (b).** Sonnette d'escalade ~11:48Z (mécanisme degraded-escalation, 2 cycles), points de mesure : sonde peer 11:53Z, sweep 12:49.
- **Prochains jalons** : nightly 24/11 02:17 = acceptation Q68 (premier snapshot hors VHDX ; risque d'interaction avec la vague si le blocage persiste à 02:00Z — cf. §4.3 la proposition de désarmer le schtask une nuit).

- `qdrant_production` healthy, container up depuis 03:18:44Z.
- GET info roo_tasks : **bloqué** (000/12 s aux derniers cycles de vigie).
- Merge : actif (I/O en progression), segments 303-310, 8 WARN/4 min en réapparition au cycle 7.
- Écritures/ingest : OK. Petites collections : OK.
- Chemin sémantique RSM : fallback texte (breaker côté RSM), escalade pair ouverte « jusqu'au matin ».
- Prochains événements : vigie 3 (verdict ~04:45Z), cron sweep 06:49 local.
