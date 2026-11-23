# Runbook Q68 — Snapshots hors VHDX (vers F:)

**Date:** 2026-11-23 · **Arbitrage user:** 2026-11-22 (via Maintenance, DM
`ai01-maint-q68-qdrant-fixed-vhdx-20261122`) — sortie de `snapshots_path` du VHDX,
puis taille VHDX fixée ; **aucune compaction quotidienne** en régime nominal.

## Objectif

Le round-trip nocturne (~220 Go : zone temporaire PUIS archive finale) ne doit
plus grossir le VHDX `E:\wsl-data\qdrant.vhdx` (plafond 880 Gio, E: au plancher
~45-55 Go). **Deux changements sont requis, l'un ne suffit pas :**
1. le bind conteneur `/qdrant/snapshots` passe sur
   `F:\Backups\qdrant\myia-ai-01\server-snapshots` (USB sain, doctrine machine
   « D: = transit, archives sur `F:\Backups\<lane>` ») — archive finale ;
2. `storage.temp_path: /qdrant/snapshots/tmp` dans
   `config/production.optimized.yaml` — **la zone temporaire d'un snapshot de
   COLLECTION est `temp_path`, pas `snapshots_path/tmp`**
   (`lib/storage/src/content_manager/toc/snapshots.rs:66-70` :
   `optional_temp_or_storage_temp_path()`, défaut = `storage/tmp` DANS le VHDX).
   Sans (2), le tar de 220 Go s'écrit quand même dans le VHDX puis est copié
   vers F: — Q68 échoue silencieusement. Avec (2), temp et finale sont sur le
   même filesystem F: → `move_file` = rename, pas copie.

Le bind vit dans `docker-compose.production.pathfix.yml` (déjà requis pour tout
`compose up` production) : **aucun script à modifier**, `mount_qdrant_vhdx.ps1`
charge déjà cet overlay automatiquement. La zone temp vit dans
`config/production.optimized.yaml` (`storage.temp_path`) — les DEUX fichiers sont
montés par le même compose.

## Préconditions (toutes obligatoires)

1. `F:` présent et sain, **≥ 350 Gio libres** (snapshot ~220 Go + marge) :
   `Get-PSDrive F`.
2. Répertoire cible existant : `F:\Backups\qdrant\myia-ai-01\server-snapshots`
   (créé 2026-11-23 ; bind Windows validé par sonde conteneur write/read).
3. Qdrant **green/ok**, hors vague d'optimiseur, ET roo-extensions a déployé le
   backoff indexeur (#4879/ms#1865) OU l'indexation est mesurée calme — ne pas
   combiner un `compose recreate` avec la charge B2 (classe wslrelay + saturation).
4. Hors créneau backup **02:17 → ~10:30 locale** et hors fenêtre de compaction.
5. Dernière copie offsite vérifiée (passe du soir) ; snapshot pré-upgrade F: en
   dernier recours.

## Déploiement (~15 min : recreate + cold recovery 5-10 min)

Depuis **Windows** (jamais depuis WSL — leçon compaction 14/11) :

```powershell
cd D:\qdrant\myia_qdrant
git pull --ff-only

# 1. Autoheal en pause (cold recovery > start_period, leçon 2026-05)
docker stop qdrant_autoheal

# 2. Recreate AVEC l'overlay pathfix (le changement de volume force le recreate)
docker compose -f docker-compose.production.yml -f docker-compose.production.pathfix.yml up -d

# 3. Attendre healthy (start_period 10 min ; sentinel doit logger [SENTINEL] OK)
docker inspect qdrant_production --format '{{.State.Health.Status}}'

# 4. Vérifier le bind effectif
docker inspect qdrant_production --format '{{json .Mounts}}'   # /qdrant/snapshots -> F:\...

# 5. Réarmer l'autoheal
docker start qdrant_autoheal
```

## Validation (critères d'acceptation)

- `GET /collections/roo_tasks_semantic_index` : `green`, optimizer `ok`,
  points ±0 vs avant recreate.
- **Snapshot complet mesuré hors VHDX** : déclencher le run (naturellement à
  02:17, ou manuel `qdrant_snapshot_backup.ps1`) puis vérifier :
  - fichier final sous `F:\Backups\qdrant\myia-ai-01\server-snapshots\roo_tasks_semantic_index\`,
  - **fichier temporaire sous `F:\...\server-snapshots\tmp\` pendant la création**
    (preuve que `temp_path` est bien pris en compte — si le temp pousse dans
    `<VHDX>/storage/tmp`, la config n'est pas active : ABORT et vérifier),
  - taille `serverSize` cohérente (~220 Go, +9 Go/j),
  - `E:\wsl-data\qdrant.vhdx` **inchangé** hors croissance ingest (± quelques Go),
  - E: libre stable pendant le round-trip (plus de plongée −360 Go),
  - log backup `snapshot-backup-<date>.log` : `Snapshot created` → `Downloaded` →
    `OFFSITE UPLOAD DONE`.
- Après TOUT `compose recreate` : vigilance **wslrelay** (classe récidive) — si
  RSM local (localhost) passe en fallback texte alors que LAN/127.0.0.1 = 200 :
  vérifier 0 session PG vivante puis killer le relay `[::1]:6333`, reset disjoncteur
  RSM. Cf. mémoire `feedback_docker_update_bind_stale`.

## Rollback

Rétablir dans `docker-compose.production.pathfix.yml` la ligne :

```yaml
- \\wsl.localhost\Ubuntu\srv\qdrant-e\qdrant_data\snapshots:/qdrant/snapshots
```

**et retirer `storage.temp_path`** de `config/production.optimized.yaml` (sinon la
zone temp pointe sur un chemin qui n'existe plus), puis
`docker compose -f docker-compose.production.yml -f docker-compose.production.pathfix.yml up -d`.
Les anciens snapshots restent dans le VHDX (non migrés, non supprimés) ; ceux écrits
sur F: restent lisibles en y pointant le bind.

## Non-migré (volontaire)

~43 Go de vieux snapshots restent DANS le VHDX (`roo_tasks_baseline_check` 33 Go du
05/10, `open-webui_*` 6,9 Go du 19/10, `selftest_restore_tmp` 2,9 Go) : invisibles de
l'API après le switch (chemin changé), conservés comme archive froide. Leur purge est
un arbitrage séparé (Q16/nettoyage), avec preuve de préservation avant suppression.
