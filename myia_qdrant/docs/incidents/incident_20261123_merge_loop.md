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

## 8. Verdict sweep 12:49 — convergence PARTIELLE, cycle toujours actif sur le search

- **Hiérarchie de déblocage mesurée : le count converge AVANT la recherche vectorielle.** Count exact 2 chemins (LAN = public) redevenu lisible à **09:47Z** (baseline po-2023 c166 = 15 247 820, +52 k en 2,9 h ≈ 18 k/h diurne). Recherche à **11:54Z : 5 vecteurs divers min 17,5 / max 60,0 s, dont 1× HTTP 500 à 60 s** — PAS service-grade (requis max < 5 s). Le search paie le cache HNSW/int8 froid (RAM 38/60 Gio en re-remplissage après l'évection à 28) + la digestion restante.
- **Zéro restart depuis 03:18:44Z** — la doctrine « laisser converger » (option d) est tenue ; écritures OK toute la matinée (15 267 996 pts, +112 k).
- **Erreur de mécanisme, corrigée deux fois.** Version du sweep 12:49 (lecture miroir, organe exit 1) : « l'escalade 03:48Z a été fermée à tort par le [REPAIRED] prématuré » — **FAUX**. Vérité (lecture PG, organe lancé avec `--env-file`) : ce [REPAIRED] de 05:55Z **n'a rien fermé** — écrit `**[REPAIRED] …**` en gras, il n'est pas reconnu (l'organe n'accepte que le tag `REPAIRED` ou le token en PREMIER token du corps). Les escalades 02:33Z et 03:46Z sont donc restées ouvertes, et le re-post `qdrant-degraded-readpath-20261123T1155Z` est un **doublon** de 03:46Z, pas une réparation. **Erreur corrigée à 23:10Z :** un `[REPAIRED]` scopé avait été posté à 17:50Z pour fermer le wedge #4 (`qdrant-repaired-wedge4-scoped-20261123T1750Z`) ; l'organe ne le voit pas, l'escalade 02:33Z reste OUVERTE — et c'est la bonne nouvelle : le chemin de lecture n'est pas réparé (§10). **Les trois escalades de lecture (02:33Z, 03:46Z, 11:58Z) restent ouvertes** jusqu'au critère de clôture du §10.3.
- **Organe degraded-escalation exit 1 sur ai-01** (sweep 12:49) : `MCP_PROXY_BEARER` absent de tous les fichiers vérifiables (`.env` roo-extensions, `~/.claude.json`, settings) → store PG non lu, codes non fiables, **la sonnerie ~11:48Z n'est pas partie**. DM `qdrant-organ-exit1-20261123T1200Z` à ai-01:roo-extensions (leur siège). Per #4729 : pas de contournement (pas de lecture sur miroir périmé).
- **Régime watchdog sous charge** (bénin mais à connaître) : `Verify-Qdrant-Mount` rend ~50 % de `PROBE_ERROR` (`Wsl/Service/0x8007274c` — wsl.exe sous charge I/O du merge) ; tous les ~30 min, 3 échecs consécutifs déclenchent `Mount-Qdrant-VHDX`, qui meurt en Phase 5 `label=''` (lecture vide) exit 6 **AVANT tout geste compose** — la garde anti-split-brain a tenu 7 runs sur la journée, container inchangé. Le montage est SAIN (sentinel 285 ×2 namespaces + alias proxy OK + 15,27 M points servis). Le compose du script est conditionnel (`if ($needMount)` ligne 227) : le risque de restart involontaire exigerait une lecture de label VIDE en Phase 4 (umount+remount), non observé en 7 runs.
- **Chemin sémantique RSM : `fallback_used:false`** (mode semantic réel, 9,1 s) — la recherche MCP passe, lentement ; embedder 0,17 s dims=2560. DNS↔IP concordants. Montage/sentinelle/alias : verts.
- **Jalons suivants** : sweep 18:49 (re-sonde vecteurs divers) ; **nightly 24/11 02:17 = acceptation Q68** (si le blocage persiste à 02:00Z → proposition de désarmer le schtask une nuit, §4.3).

## 9. Sweep 18:49 (17:49Z) — convergence lente, et l'alias /srv tué par le watchdog lui-même

- **Read path** : 5 vecteurs divers **min 8,3 / max 34,2 s, tous 200** (11:54Z : 17,5-60,0 s avec un 500). Toujours pas service-grade (< 5 s). Info 1,34 s green/ok, 302 segments, 15 306 724 pts, RAM 42,6/60 Gio (en remontée), container up depuis 03:18:44Z. **Mais 40 ERROR sur 60 min (WARN=0)** : 20× `read operations failed` (9× retrieve « 0ns », 8× count 60 s, retrieve 21 s, Search 25-27 s) — de vraies requêtes de clients time-outent encore. `roosync_search` : `fallback_used:false` en 3,4 s. OWUI a posté sa fermeture d'escalade à 12:11Z (canaris réels 1,6-3,6 s).
- **Nuance d'instrument** : les vecteurs aléatoires uniformes sont hors distribution des embeddings réels — ils explorent plus de graphe (pire cas), alors que canaris RAG réels et recherche MCP passent mieux. Le critère « max < 5 s sur vecteurs divers » reste la clôture STRICTE ; la vérité de service se lit en plus sur les timeouts lecture (0/60 min) et `fallback_used`.
- **Alias `/srv/qdrant-e` MORT dans le ns PID-1 à 17:55Z** (18:55 locales ; retombé sur le répertoire rootfs de Sep 28 ; vivant uniquement dans le ns du proxy DD). Réparé à la main (bind + make-shared, sentinel 285 ×2 namespaces). **Cause racine = le script de montage lui-même, sur sonde sourde** : sous charge I/O, `wsl.exe` rend `rc=-1` (`Wsl/Service/0x8007274c`) une fois sur deux.
  - **Boucle alias (ligne 267)** : le `break` exigeait `rc=0` ET sentinel 285 ; un `rc=-1` sur un alias SAIN entrait en 2ᵉ tentative = `umount` **inconditionnel** ; si le re-bind échouait à son tour, alias mort, loggé ERR puis « Idempotent… skip restart » exit 0. Mesuré à **16:02Z et 17:21Z** (heures des logs de montage, locales : 17:02 et 18:21 — « ECHEC apres 3 tentative(s) rc=-1 sentinel='0' ») ; le run de 16:40Z (17:40 locales) l'avait ressuscité.
  - **Phase 4** : un label `blkid` illisible (sortie vide) tombait dans la branche « mauvais disque » → `umount` + remount de `/mnt/qdrant-e` sous le conteneur. Mesuré à **14:39Z** (run de 15:38:34 locales ; « Collections visibles: 0 » loggé `[OK]` à 15:41:53 locales).
  - 15 runs de `Mount-Qdrant-VHDX` avant le correctif, **0 compose** : 1 au démarrage machine (03:08 locales), 12 « Idempotent… skip restart » (dont celui de 15:38 locales, après son umount+remount), 2 refus de Phase 5 sur label illisible (11:10 et 12:28 locales, exit 6).
- **Correctif — PR #40 mergée (`93396e7ab`), DÉPLOYÉE à 18:24Z** (19:24 locales ; `mount_qdrant_vhdx.ps1`, empreinte déployée `2a36c9fe1192`, backup `.bak-20261123-a330455c8708` à côté de l'original) : Phase 4 → label vide = sonde sourde, aucun geste (la Phase 5 tranche par device) ; bloc alias → **diagnostic et geste dans UN SEUL payload bash** (un `wsl.exe` sourd n'exécute rien ; `umount -l` seulement si le sentinel lu dans la même exécution n'est pas 285) ; 0 collections → WARN. Preuves : parse PS 5.1 + 7, `bash -n`, exécution réelle (`alias-ok:sain`, `alias-ok:repare`, appel sourd → rien exécuté), selftest `myia_qdrant/scripts/test/mount_qdrant_vhdx.selftest.ps1` (code réel extrait, `wsl.exe` factice, 9 cas). **Premier run du script déployé (18:32Z → 18:41Z)** : Phase 4 « deja monte sur /dev/sdd (label=qdrant-e) », 3 sondes alias sourdes → « AUCUN geste, état INCONNU », Phase 5 sourde → exit 6, conteneur inchangé. Le geste dangereux n'est plus tiré sur sonde sourde. La ligne positive « verifie par le sentinel (sain, …) » reste à relever sur un run à sondes répondantes (alias vérifié sain à la main à 17:45Z : sentinel 285 dans les 2 namespaces).
- **Reste ouvert côté script** : (a) un alias non vérifié finit toujours en exit 0 ; (b) **dérive déployé↔repo** sur le bloc proxy-alias (une variante non versionnée datée 21/11 01:05 — conservée telle quelle dans le déploiement ; réconciliation = décision du propriétaire, signalée à Maintenance).
- **Jalons** : nightly 24/11 à **01:17Z** (02:17 locales — acceptation Q68, règle §4.3) ; sweep 23:49Z.
- **Correction d'horodatage (PR #41 → #42)** : les heures « 18:55Z », « 17:00Z », « 18:21Z » et « 19:24Z » de la première version de ce §9 étaient des heures LOCALES des logs de montage, notées Z à tort.

## 10. Verdict du 18:49, complété à 23:00Z — chronologie réelle des clients, et la mémoire de la VM

**Instrument** : le journal d'accès du conteneur (lignes `actix_web::middleware::logger`), agrégé par minute et par endpoint — `myia_qdrant/scripts/diagnostics/qdrant_traffic_stats.py`. C'est le trafic RÉEL des clients (qdrant-js), pas une sonde synthétique.

### 10.1 Le service alterne bloqué / sain — il ne converge pas

- **Par heure (UTC), requêtes / erreurs 5xx sur `roo_tasks_semantic_index`** : 07h 4 850/167 · 09h 5 777/316 · 11h 4 589/419 · **15h 5 836/954** · **16h 2 404/850** · 17h 7 854/20 · **18h 4 989/711** · 20h 7 687/185 · 22h 6 529/31.
- **Blocages TOTAUX (100 % des requêtes `points` en échec)** : 15:33Z (au plus tard) → ~17:15Z ; **18:31Z → 18:50Z** (20 min) ; ralenti à partir de ~22:33Z (la plupart des réponses à 60 s), 5xx 22:42-22:44Z. Chaque blocage se relâche d'un coup (18:51Z : 1 124 requêtes dans la minute ; 22:46-22:49Z : 990 à 1 536/min, 0 erreur, max 0,17 s).
- **Fenêtre saine la mieux mesurée** : 17:20Z → 18:14Z, 0 erreur, latence max 3,4 s sur trafic réel. Les 8-34 s mesurés à 17:49Z sur vecteurs aléatoires tombaient dans cette fenêtre : les vecteurs hors distribution sont un pire cas, pas l'état du service.
- **Pendant le blocage total (échantillon de 45 s à 18:38Z)** : 13,45 Mo/s lus depuis le VHDX en 139 902 E/S (≈ 4,3 Ko chacune), ~0 octet écrit, 0,71 cœur, **0 WARN**. **Aucun fichier de segment écrit entre 15:46Z et 18:14Z** (histogramme des mtime), alors que le service était bloqué puis sain : l'hypothèse « merge en vol » des §1-9 n'explique pas ces blocages. Deux vagues d'écriture seulement : 18:15-18:17Z et 18:29-18:30Z (305 `segment.json`, 335 `tracker.dat`, 361 fichiers d'index de payload = flush).

### 10.2 La mémoire de la VM est saturée (MESURÉ à 18:49Z)

| Niveau | Mesure |
|---|---|
| Conteneur qdrant (cgroup) | limite 60 Gio + 60 Gio de swap autorisé ; resident 36-41 Gio ; **swap utilisé 22,8 Gio** ; pic resident 56,1 Gio ; re-défauts : 12,1 M (anon) et 134,1 M (fichiers) |
| Processus qdrant (pid 7) | VmRSS 41,9 Go, **VmSwap 23,7 Go**, 190 fils |
| VM WSL | 125,8 Gio au total, MemFree 2 Go, MemAvailable 36 Gio ; **swap 32 Gio PLEIN (SwapFree = 0)** ; 82,8 M pages sorties, 54,2 M rentrées, 3 `oom_kill` depuis le démarrage de la VM (20/11) |
| Hôte | 191,8 Go de RAM, 20,2 Go libres ; `vmmemWSL` 117 Gio ; `.wslconfig` : `memory=128GB`, `swap=32GB` |
| Autre gros consommateur | `myia_vllm-medium-swift15-27b` : démarré le **22/11 14:16Z**, limite 48 Gio, **42,0 Gio utilisés** (87,6 %) à 18:52Z |

Relevé du 23:03Z (24/11, fenêtre saine, `qdrant_cgroup_sample.py` 15 s) : swap du conteneur 18,1 Gio (4,8 Gio rentrés depuis 18:52Z), VM SwapFree 5,6 Gio, resident 42,9 Gio, **pic = 60,0 Gio = la limite** ; le conteneur continue de sortir 4,9 Mo/s vers le swap et de relire 12,7 Mo/s du VHDX par blocs de 4,3 Ko. Il vit en régime de swap permanent, supportable quand le trafic est bas.

**Lien avec les blocages : SUPPOSÉ, pas prouvé.** Pour : les lectures aléatoires de 4 Ko et les sorties de swap pendant le blocage, l'empreinte réelle de qdrant (≈ 59-64 Gio) au-dessus de sa limite, et l'arrivée du conteneur vLLM 6 h avant le premier blocage de la nuit d'incident. Contre : le relâchement de 18:51Z s'est produit SANS rentrée de swap (22,8 Gio restés dehors), donc la saturation mémoire rend les requêtes lentes mais n'explique pas à elle seule l'état « 100 % en échec puis tout passe d'un coup » — un point de sérialisation reste à identifier.

### 10.3 Conséquences

- Le critère de clôture de l'escalade reste : **0 erreur 5xx et 0 réponse > 5 s sur trafic réel pendant ≥ 60 min**, à lire au journal d'accès (plus les vecteurs divers < 5 s).
- Un redémarrage de qdrant ne changera rien tant que la VM est sur-engagée : à froid, il demande encore plus de mémoire pour relire le cache.
- Leviers, par ordre de la lane : (1) **arbitrage mémoire dans la VM** (vLLM medium 42 Gio, plafond `memory=128GB`, swap 32 Gio) — décision user, la VM est partagée ; (2) **réduire l'empreinte de qdrant** : binary quantization + rescore (le cache int8 pèse 36,5 Gio pour 15,3 M points) ; (3) gel d'ingest le temps de converger. Le relèvement à chaud de la limite du conteneur a été écarté : il rendrait le swap de la VM à qdrant en vidant le cache de fichiers de tous les conteneurs.
- Chemin sémantique RSM : `fallback_used:true` à 18:43Z (31 s), `false` à 17:49Z (3,4 s) — il suit les épisodes. Embedder : 200, 2560 dims, 0,26 s à 17:49Z, 6,7 s à 22:58Z (ralenti, pas mort).
- Sauvegarde nocturne : déclencheur réel **01:17Z (02:17 locales)**, résultat de la nuit du 23/11 = 1 (échec). Règle §4.3 appliquée telle quelle : blocage persistant → la lane propose de la reporter d'une nuit.
