---
name: qdrant-sweep
description: Sweep de surveillance 6h de la lane myia-ai-01:qdrant — healthz, point-count (floor 1.5M), montage VHDX + sentinel anti-split-brain, backup du jour, watchdogs, chemin sémantique (preuve par inférence réelle, mandat user 02/09), IP dynamique, inbox, puis synthèse [DONE] sur workspace-qdrant. À invoquer à chaque cycle de veille (cron 6h) ou manuellement.
---

# Sweep surveillance qdrant (lane myia-ai-01:qdrant)

Cadence : 6h (01:15 / 07:15 / 13:15 / 19:15). Durée typique ~5 min. Tout est en lecture, sauf les posts dashboard. Ne JAMAIS échoer de valeur de clé (longueurs uniquement).

## 1. Sondes locales (script canonique)

```powershell
& d:\qdrant\myia_qdrant\scripts\monitoring\qdrant_lane_sweep.ps1
```

Attendu : healthz ×3 = 200 · points roo_tasks_semantic_index > 1.5M · montage `/dev/sdX` avec `LABEL=qdrant-e` · `qdrant_production Up ... (healthy)` · `dns_qdrant` = `public_ip4`.

## 2. Sentinel anti-split-brain (chemin RÉEL, namespace PID-1)

Via Bash — **obligatoirement `MSYS_NO_PATHCONV=1`** (sinon Git Bash détourne `/mnt/...` vers `C:/Program Files/Git/mnt/...` et la sonde échoue à tort) :

```bash
MSYS_NO_PATHCONV=1 wsl -u root -- nsenter -t 1 -m -- ls -la /mnt/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel
```

Attendu : 285 o. PAS une session `wsl` fraîche (elle ne voit pas le namespace PID-1). Le sentinel vit SOUS `qdrant_data/storage/`, pas à la racine du montage.

## 3. Chemin sémantique (mandat user 02/09 — la lane qdrant EST garante du chemin)

a) **Preuve par inférence RÉELLE** — jamais `/health` seul (épisode #9 : /health restait 200 avec l'inférence morte). POST sur `{EMBEDDING_API_BASE_URL}/embeddings` avec Bearer `EMBEDDING_API_KEY` et `model` = `EMBEDDING_MODEL`, tous lus depuis `myia_qdrant/.env.production` sans jamais afficher la clé. Attendu : **dims=2560**.

b) **KPI** : `roosync_search(action:"semantic", max_results:1, query:"qdrant down semantic broken embedding error")` → `fallback_used` doit être **false**.

Si fallback / `embedding_api_error` / rapport « sémantique cassée » circule : **décomposer** — épisode embedder vLLM po-2026:8004 (la plupart auto-résolus <10 min) ≠ crash ESM d'indexation MCP (la RECHERCHE reste verte) ≠ disque po-2026 ≠ Qdrant lui-même. Poster preuve + grille de lecture ; escalader roo-extensions si le code MCP est en cause. Attention : épisodes « proxy-only » (IIS) = backend :8004 reste 200 → NE PAS relancer Docker.

## 4. Backup

Le log du jour (`myia_qdrant/backups/snapshot-logs/snapshot-backup-<yyyyMMdd>.log`) doit finir **"Backup done"** et contenir la ligne **orphan-cleanup**. Avant ~03:20, log absent = normal (schtask 03:17). Retry copie borné intégré (3×300 s, commit `38595c379`) ; en cas d'échec persistant, deux classes DriveFS connues : racine G: absente (pré-wait intégré) vs montée dégradée (retry la couvre). Jamais restaurer/dropper sans GO user.

## 5. Watchdogs & reboots

`Verify-Qdrant-Mount`, `Mount-Qdrant-VHDX`, `Watchdog-Embedding-API` : exit 0 attendu (état + dernières lignes `C:\ProgramData\maint-scripts\logs\`). Après TOUT reboot machine : vérifier la chaîne de récupération complète — drift détecté → `Mount-Qdrant-VHDX` → compose recreate → healthy (container peut monter ~3 min après l'exit 7 du mount = transient qualifié).

## 6. IP dynamique (Livebox Orange, *.myia.io via Gandi)

`dns_qdrant` ≠ `public_ip4` = **rotation IP** → c'EST ça la panne externe (pas le service) : poster [ERROR] + rappeler le workaround LAN (192.168.0.47:6333 direct).

Santé de l'updater : lire le log **canonique** `D:\roo-extensions\outputs\gandi-dns\gandi-dns-<yyyyMMdd>.log` (schtask `Gandi-DNS-Updater`, 15 min, PAT dans le trousseau Windows `Gandi-LiveDNS-PAT`) — attendu : `Rien a faire : apex et IP publique concordent` + `Fin (exit=0)`. ⚠️ **NE PAS** prendre `C:\ProgramData\maint-scripts\logs\update-gandi-dns.log` pour l'état canonique : c'est le **legacy** (token fichier, quarantainé 04/09) — ses `ERREUR: Aucun token Gandi` ne disent RIEN du canonique. Du 05/09 au 08/09 les sweeps ont mal attribué ce log (« auto-update désarmé » = FAUX — canonique sain, établi 08/09 avec roo-extensions, [[dr-me-migration-dynamic-ip]]). Canonique en erreur → [ASK] roo-extensions ; le check DNS↔IP du sweep reste la vérification indépendante. Ne JAMAIS provisionner de fichier token (ré-armerait le duplicat legacy).

## 7. Inbox & dashboards

Inbox : vérifier les HIGH pour pertinence lane AVANT `bulk_mark_read` (worker reports des autres lanes = hors-lane). `bulk_mark_read` en timeout = problème connu #2267 (pool volumineux, scan lent) — si listing/reply fonctionnent, ce n'est PAS une panne DriveFS ; rattraper au sweep suivant. Si notif `CLUSTER-HEALTH T#NN` → lire l'intercom global. DM adressé à la lane → répondre (ACK).

## ALERTE point-count (< 1.5M)

Suspect **client drop+recreate**. NE JAMAIS restaurer/dropper sans GO user explicite → poster **[ASK]** sur workspace-qdrant avec la chaîne complète (heure, point-count, dernier snapshot sain). Le poison-guard backup empêche déjà la rotation des bons snapshots.

## Escalades (règle user 14/07)

Tout service dégradé, même hors-lane → escalade formelle **[ERROR]/[WARN] + [ASK] + crossPost global**, PAS une mention passagère dans un [DONE]. Vérifier le réel d'abord (5xx/000 = down ; 401 = clé stale, pas un down). Router vers la lane propriétaire, ne pas remédier hors-lane.

## 8. Clôture

Synthèse **[DONE]** sur workspace-qdrant (condensation auto OK). Y consigner : deltas points, épisodes embeddings, état backup, cohérence DNS, escalades en attente ([ASK]s ouverts), état du cron (re-arm avant expiration ~7 j — prompt = « invoque le skill qdrant-sweep »).
