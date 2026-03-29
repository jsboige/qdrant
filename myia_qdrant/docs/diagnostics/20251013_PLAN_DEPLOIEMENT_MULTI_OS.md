# Plan de Déploiement Multi-OS - Fix Heap MCP roo-state-manager

**Date:** 2025-10-13  
**Auteur:** Système de monitoring automatique  
**Version:** 1.0  
**Statut:** Windows validé ✅ - En attente déploiement autres OS

---

## Résumé Exécutif

Le fix heap MCP (4096 MB) a été appliqué avec **succès total sur Windows**:
- ✅ Erreurs HTTP 400: Réduction de 100% (965 → 0)
- ✅ Processus Node.js: 4 instances actives avec heap correct
- ✅ Collection Qdrant: Status green, threads optimisés (2)
- ✅ Temps de réponse: Excellent (13.11 ms moyenne)

Ce document présente la stratégie de déploiement progressif sur macOS et Linux.

---

## 1. Validation Windows (Étape COMPLÈTE ✅)

### 1.1 Configuration Appliquée

**Fichier:** `C:\Users\MYIA\AppData\Roaming\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json`

```json
{
  "mcpServers": {
    "roo-state-manager": {
      "command": "node",
      "args": [
        "--max-old-space-size=4096",
        "D:/roo-extensions/mcps/internal/servers/roo-state-manager/build/src/index.js"
      ],
      "cwd": "D:/roo-extensions/mcps/internal/servers/roo-state-manager",
      "transportType": "stdio",
      "enabled": true
    }
  }
}
```

### 1.2 Résultats de Validation (13/10/2025 23:30 UTC)

| Métrique | Avant | Après | Amélioration |
|----------|-------|-------|--------------|
| Erreurs HTTP 400 (30 min) | 965 | 0 | **100%** ✅ |
| Processus actifs | 0-1 | 4 | Stable ✅ |
| Heap size configuré | Non | 4096 MB | Optimal ✅ |
| Mémoire utilisée/processus | N/A | ~528 MB | Normal ✅ |
| Collection status | Yellow/Red | Green | Opérationnel ✅ |
| Temps réponse Qdrant | N/A | 13.11 ms | Excellent ✅ |

### 1.3 Monitoring Initial (5 minutes post-redémarrage)

- **Collection roo_tasks_semantic_index:**
  - Status: Green
  - Points: 0 (indexation en cours, normal)
  - Threads: 2 (optimisé)
  - Segments: 8

- **Performance Qdrant:**
  - Requêtes: 5/5 succès
  - Min: 4.71 ms
  - Max: 41.1 ms
  - Moyenne: 13.11 ms

---

## 2. Chemins de Configuration par OS

### 2.1 Windows (Validé ✅)

**Fichier mcp_settings.json:**
```
C:\Users\<USERNAME>\AppData\Roaming\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json
```

**Chemin index.js:**
```
D:/roo-extensions/mcps/internal/servers/roo-state-manager/build/src/index.js
```

### 2.2 macOS (À déployer 📋)

**Fichier mcp_settings.json:**
```
/Users/<USERNAME>/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json
```

**Chemin index.js:**
```
/Users/<USERNAME>/roo-extensions/mcps/internal/servers/roo-state-manager/build/src/index.js
```

### 2.3 Linux (À déployer 📋)

**Fichier mcp_settings.json:**
```
/home/<USERNAME>/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json
```

**Chemin index.js:**
```
/home/<USERNAME>/roo-extensions/mcps/internal/servers/roo-state-manager/build/src/index.js
```

---

## 3. Template de Configuration Universel

```json
{
  "mcpServers": {
    "roo-state-manager": {
      "command": "node",
      "args": [
        "--max-old-space-size=4096",
        "<CHEMIN_ABSOLU_VERS_INDEX.JS>"
      ],
      "cwd": "<REPERTOIRE_ROO_STATE_MANAGER>",
      "transportType": "stdio",
      "enabled": true,
      "watchPaths": [
        "<CHEMIN_ABSOLU_VERS_INDEX.JS>"
      ]
    }
  }
}
```

**Variables à adapter:**
- `<CHEMIN_ABSOLU_VERS_INDEX.JS>`: Chemin complet vers le fichier index.js compilé
- `<REPERTOIRE_ROO_STATE_MANAGER>`: Répertoire racine du MCP

---

## 4. Scripts de Vérification par OS

### 4.1 Windows (PowerShell)

**Vérifier configuration:**
```powershell
Get-Content "$env:APPDATA\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json" | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

**Vérifier processus:**
```powershell
Get-CimInstance Win32_Process -Filter "name = 'node.exe'" | Where-Object { $_.CommandLine -like '*roo-state-manager*' } | Select-Object ProcessId, CommandLine
```

**Monitoring erreurs 400:**
```powershell
docker logs qdrant_production --since 5m 2>&1 | Select-String "400" | Measure-Object | Select-Object -ExpandProperty Count
```

### 4.2 macOS/Linux (Bash)

**Vérifier configuration:**
```bash
# macOS
cat ~/Library/Application\ Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json | jq .

# Linux
cat ~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json | jq .
```

**Vérifier processus:**
```bash
ps aux | grep "roo-state-manager" | grep "max-old-space-size=4096"
```

**Monitoring erreurs 400:**
```bash
docker logs qdrant_production --since 5m 2>&1 | grep "400" | wc -l
```

---

## 5. Stratégie de Déploiement Progressif

### Phase 1: Windows (COMPLÈTE ✅)
- **Statut:** Déployé et validé
- **Date:** 2025-10-13 23:30 UTC
- **Résultat:** Succès total (100% réduction erreurs 400)
- **Action suivante:** Monitoring 24h pour confirmation stabilité

### Phase 2: Préparation Documentation (EN COURS 📋)
- **Durée:** 1-2 jours
- **Tâches:**
  - [x] Créer guide de déploiement pour chaque OS
  - [x] Documenter chemins exacts mcp_settings.json
  - [x] Préparer scripts de vérification spécifiques
  - [ ] Valider chemins sur machines réelles (si disponibles)

### Phase 3: Déploiement macOS (SI APPLICABLE)
- **Pré-requis:** Windows stable pendant 24h
- **Durée estimée:** 1 jour
- **Étapes:**
  1. Backup fichier mcp_settings.json original
  2. Appliquer modification avec heap 4096 MB
  3. Redémarrer VS Code
  4. Vérifier processus Node.js (commande ps)
  5. Monitoring initial (1h): erreurs 400, points collection
  6. Monitoring étendu (48h): stabilité générale

### Phase 4: Déploiement Linux (SI APPLICABLE)
- **Pré-requis:** Windows + macOS stables
- **Durée estimée:** 1-2 jours
- **Étapes:** Identiques à Phase 3
- **Distribution testée:** Ubuntu/Debian (adapter selon distribution)

### Phase 5: Validation Finale Multi-OS
- **Durée:** 7 jours
- **Critères de succès:**
  - Tous les OS: 0 erreur HTTP 400 pendant 7 jours consécutifs
  - Collection status: Green permanent
  - Temps réponse: <100 ms moyen
  - Processus MCP: Stables (aucun crash)

---

## 6. Checklist de Déploiement par OS

### Pour Chaque OS à Déployer:

#### 6.1 Pré-Déploiement
- [ ] Identifier chemin exact du fichier mcp_settings.json
- [ ] Vérifier existence du fichier index.js compilé
- [ ] Installer Node.js si nécessaire (version recommandée: 18+)
- [ ] Vérifier Docker et Qdrant fonctionnels
- [ ] Backup du fichier mcp_settings.json original

#### 6.2 Déploiement
- [ ] Éditer mcp_settings.json
- [ ] Ajouter `--max-old-space-size=4096` dans args
- [ ] Vérifier syntaxe JSON (pas d'erreur)
- [ ] Sauvegarder le fichier
- [ ] Redémarrer VS Code **complètement**

#### 6.3 Vérification Immédiate (0-5 min)
- [ ] Processus Node.js lancé avec nouveau heap
- [ ] Logs VS Code confirment démarrage MCP
- [ ] Aucune erreur dans Extension Host logs
- [ ] MCP visible dans Roo interface

#### 6.4 Monitoring Initial (1h)
- [ ] Erreurs HTTP 400: Comparer avant/après
- [ ] Collection status: Doit être Green
- [ ] Points count: Commence à augmenter
- [ ] Temps de réponse Qdrant: <100 ms moyen

#### 6.5 Monitoring Étendu (24h)
- [ ] Erreurs HTTP 400: Rester à 0 ou <5/jour
- [ ] Processus MCP: Aucun crash
- [ ] Mémoire utilisée: Stable (~500-700 MB)
- [ ] Collection: Indexation progressive

#### 6.6 Documentation
- [ ] Noter date/heure du déploiement
- [ ] Documenter tout problème rencontré
- [ ] Capturer métriques avant/après
- [ ] Mettre à jour ce document

---

## 7. Métriques de Succès par OS

### Critères Obligatoires

| Métrique | Valeur Cible | Tolérance |
|----------|--------------|-----------|
| Erreurs HTTP 400 | 0/jour | <5/jour acceptable |
| Processus MCP actifs | ≥1 | Redémarre automatiquement si crash |
| Heap size configuré | 4096 MB | Exact, pas de tolérance |
| Collection status | Green | Yellow acceptable temporairement |
| Temps réponse moyen | <50 ms | <100 ms acceptable |
| Uptime MCP | 100% | >99% acceptable |

### Métriques Secondaires

| Métrique | Windows (Validé) | macOS (À venir) | Linux (À venir) |
|----------|------------------|-----------------|-----------------|
| Réduction erreurs 400 | 100% ✅ | N/A | N/A |
| Mémoire/processus | 528 MB ✅ | N/A | N/A |
| Threads indexation | 2 ✅ | N/A | N/A |
| Points indexés (24h) | TBD | N/A | N/A |

---

## 8. Procédures de Rollback

### 8.1 Rollback Simple (Problème mineur)

**Si:** Erreurs HTTP 400 diminuées mais pas à 0, performance acceptable

**Action:** Continuer monitoring 48h supplémentaires avant décision

### 8.2 Rollback Complet (Problème majeur)

**Si:** 
- Erreurs HTTP 400 augmentent après déploiement
- Processus MCP crashe de manière répétée
- Performance Qdrant se dégrade significativement

**Procédure:**
1. Restaurer backup mcp_settings.json original
2. Redémarrer VS Code
3. Vérifier retour à l'état stable précédent
4. Documenter l'échec et analyser logs
5. Attendre correction avant nouvelle tentative

### 8.3 Fichiers de Backup

**Windows:**
```
C:\Users\MYIA\AppData\Roaming\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json.backup
```

**macOS:**
```
~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json.backup
```

**Linux:**
```
~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json.backup
```

---

## 9. Calendrier Prévisionnel

| Phase | Plateforme | Durée | Date Début Estimée | Date Fin Estimée |
|-------|-----------|-------|-------------------|------------------|
| ✅ Phase 1 | Windows | 1h | 2025-10-13 23:30 | 2025-10-13 23:35 |
| 🔄 Phase 1.5 | Windows (monitoring 24h) | 24h | 2025-10-13 23:35 | 2025-10-14 23:35 |
| 📋 Phase 2 | Documentation | 1-2j | 2025-10-13 | 2025-10-15 |
| ⏳ Phase 3 | macOS (si applicable) | 1j + 48h monitoring | TBD | TBD |
| ⏳ Phase 4 | Linux (si applicable) | 1j + 48h monitoring | TBD | TBD |
| ⏳ Phase 5 | Validation finale | 7j | TBD | TBD |

**Total estimé:** 2-4 semaines selon nombre d'OS à déployer

---

## 10. Points de Contact et Escalade

### 10.1 Monitoring Automatique

- **Scripts disponibles:**
  - `scripts/check_node_heap.ps1` (Windows)
  - `scripts/monitor_http_400_errors.ps1` (Windows)
  - `scripts/check_collection_status.ps1` (Windows)
  - `scripts/measure_qdrant_response_time.ps1` (Windows)

### 10.2 Logs à Consulter en Cas de Problème

1. **VS Code Extension Host:**
   - Windows: `%APPDATA%\Code\logs\<session>\exthost\exthost.log`
   - macOS: `~/Library/Application Support/Code/logs/<session>/exthost/exthost.log`
   - Linux: `~/.config/Code/logs/<session>/exthost/exthost.log`

2. **Qdrant Docker:**
   ```bash
   docker logs qdrant_production --since 1h
   ```

3. **MCP roo-state-manager:**
   - Rechercher: "roo-state-manager" dans logs VS Code
   - Vérifier stderr/stdout du processus Node.js

---

## 11. Recommandations Finales

### 11.1 Bonnes Pratiques

1. **Toujours backup** mcp_settings.json avant modification
2. **Redémarrer VS Code complètement** (fermer toutes les fenêtres)
3. **Attendre 5-10 minutes** avant juger de l'efficacité du fix
4. **Monitorer pendant 24h minimum** avant déploiement OS suivant
5. **Documenter tout problème** dans ce fichier

### 11.2 Signes de Succès

- ✅ 0 erreur HTTP 400 pendant 24h consécutives
- ✅ Processus MCP stable (pas de crash)
- ✅ Collection Green avec indexation progressive
- ✅ Temps de réponse Qdrant <100 ms

### 11.3 Signes d'Alerte

- ⚠️ Erreurs HTTP 400 persistent (>10/heure)
- ⚠️ Processus MCP crash régulièrement
- ⚠️ Collection reste Yellow/Red après 1h
- ⚠️ Temps de réponse Qdrant >1000 ms
- ⚠️ Mémoire utilisée explose (>2 GB/processus)

---

## 12. Historique des Modifications

| Date | Version | Auteur | Modifications |
|------|---------|--------|---------------|
| 2025-10-13 | 1.0 | Système | Création initiale après validation Windows |

---

## Annexes

### A. Configuration Complète Windows (Référence)

Voir fichier: `C:\Users\MYIA\AppData\Roaming\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json`

Section pertinente (lignes 278-323):
```json
"roo-state-manager": {
  "transportType": "stdio",
  "command": "node",
  "args": [
    "--max-old-space-size=4096",
    "D:/roo-extensions/mcps/internal/servers/roo-state-manager/build/src/index.js"
  ],
  "cwd": "D:/roo-extensions/mcps/internal/servers/roo-state-manager",
  "watchPaths": [
    "D:/roo-extensions/mcps/internal/servers/roo-state-manager/build/src/index.js"
  ],
  "disabled": false,
  "enabled": true
}
```

### B. Commandes de Diagnostic Rapide

**Windows:**
```powershell
# Tout-en-un
.\scripts\check_node_heap.ps1; .\scripts\monitor_http_400_errors.ps1; .\scripts\check_collection_status.ps1; .\scripts\measure_qdrant_response_time.ps1
```

**macOS/Linux:**
```bash
# Vérification processus
ps aux | grep "roo-state-manager" | grep "max-old-space-size"

# Erreurs 400
docker logs qdrant_production --since 5m 2>&1 | grep "400" | wc -l

# Collection status
curl -s http://localhost:6333/collections/roo_tasks_semantic_index | jq '.result | {status, points_count, indexed_vectors_count}'
```

---

**FIN DU DOCUMENT**