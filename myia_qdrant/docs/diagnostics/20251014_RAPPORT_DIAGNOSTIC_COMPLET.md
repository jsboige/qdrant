# Rapport de Diagnostic Complet - Redémarrages Qdrant Production
**Date**: 2025-10-14  
**Gravité**: CRITIQUE  
**Statut**: Diagnostic terminé, action corrective partielle appliquée

---

## 🔴 PROBLÈMES CRITIQUES IDENTIFIÉS

### 1. **Configuration Manquante** (CAUSE RACINE PRINCIPALE)
- ❌ `myia_qdrant/config/production.yaml` **N'EXISTAIT PAS**
- ✓ `docker-compose.production.yml` pointait vers ce fichier inexistant
- ✓ Qdrant utilisait probablement une **configuration par défaut non optimisée**
- ✓ **ACTION APPLIQUÉE**: Copie de `production.optimized.yaml` → `production.yaml`

### 2. **Configuration HNSW Immuable**
- ❌ La collection `roo_tasks_semantic_index` a été créée avec `max_indexing_threads: 0`
- ⚠️ Ce paramètre est **immutable** après création de la collection
- ⚠️ Le redémarrage avec la nouvelle config ne change PAS la collection existante
- 💡 **SOLUTION REQUISE**: Recréer la collection ou migration de données

### 3. **SIGTERM Externes Répétés**
- 🔍 Les logs montrent: `SIGTERM received; starting graceful shutdown`
- ✓ Ce n'est **PAS un crash** de Qdrant
- ✓ Quelque chose **envoie des signaux d'arrêt** au container
- ❓ Source potentielle: Healthcheck absent, monitoring externe, ou problème Docker/WSL

---

## ✅ RESSOURCES SYSTÈME (ÉTAT SAIN)

### Mémoire
| Ressource | Total | Utilisé | Libre | % Utilisé |
|-----------|-------|---------|-------|-----------|
| Windows RAM | 191.79 GB | 105.33 GB | 86.46 GB | 54.9% |
| WSL2 | 125 GB alloué | 25 GB | 100 GB | 20% |
| Container | 16 GB limite | 2.5 GB | 13.5 GB | 15.77% |

**Conclusion**: ✅ Aucun problème mémoire détecté

### Espace Disque
| Ressource | Total | Utilisé | Libre | % Utilisé |
|-----------|-------|---------|-------|-----------|
| Windows D: | ~1000 GB | 87.88 GB | ~912 GB | ~9% |
| WSL2 / | 1007 GB | 347 GB | 609 GB | 37% |
| VHDX | - | 990 GB | - | - |

**Conclusion**: ✅ Aucun problème espace disque détecté

---

## 🔍 ANALYSE DES LOGS

### Patterns Trouvés
```
✓ Aucune erreur critique (error, panic, fatal)
✓ Aucune saturation mémoire (OOM)
✓ Aucun problème disque
⚠️ 4 patterns de redémarrage détectés
🔴 SIGTERM externes confirmés
```

### Exemple de Log Clé
```
qdrant_production | 2025-10-14T15:41:31.675404Z INFO actix_server::server: 
SIGTERM received; starting graceful shutdown
```

**Interprétation**: Le container est **arrêté proprement** par un signal externe, pas par un crash interne.

---

## 🛠️ ACTIONS CORRECTIVES APPLIQUÉES

### 1. Création de production.yaml ✅
```bash
✓ Backup créé: myia_qdrant/backups/config_backup_20251014_202150/
✓ production.optimized.yaml → production.yaml
✓ max_indexing_threads: 16 dans le fichier de config
```

### 2. Redémarrage du Service ✅
```bash
✓ docker-compose stop (gracieux)
✓ docker-compose up -d (avec nouvelle config)
✓ Service opérationnel confirmé
✓ Status: Up 15 seconds
```

### 3. Vérification Configuration ⚠️
```yaml
# Configuration ACTUELLE de la collection (IMMUABLE)
max_indexing_threads: 0  # ⚠️ Auto-détection active
on_disk: true
m: 32
ef_construct: 200
```

---

## 🚨 PROBLÈMES NON RÉSOLUS

### 1. Collection avec max_indexing_threads=0
**Impact**: La collection existante conserve son ancienne configuration HNSW.

**Options de résolution**:

#### Option A: Recréer la Collection (RECOMMANDÉE)
```bash
# 1. Backup des points
curl -X POST "http://localhost:6333/collections/roo_tasks_semantic_index/snapshots" \
  -H "api-key: $QDRANT_API_KEY"

# 2. Supprimer la collection
curl -X DELETE "http://localhost:6333/collections/roo_tasks_semantic_index" \
  -H "api-key: $QDRANT_API_KEY"

# 3. Recréer avec nouvelle config
# (Le serveur utilisera automatiquement production.yaml avec threads=16)

# 4. Restaurer les données depuis le snapshot
```

**Avantages**:
- ✓ Configuration HNSW optimale garantie
- ✓ Pas de données perdues (snapshot)
- ✓ Solution propre et définitive

**Inconvénients**:
- ⚠️ Downtime pendant la migration
- ⚠️ Nécessite réindexation

#### Option B: Vivre avec max_indexing_threads=0 (NON RECOMMANDÉE)
- Les nouvelles collections utiliseront threads=16
- Cette collection restera avec auto-détection
- Peut causer des problèmes d'indexation

### 2. Source des SIGTERM Externes
**Hypothèses à investiguer**:

1. **Healthcheck Docker absent**
   - Aucun healthcheck configuré dans docker-compose.yml
   - Docker pourrait considérer le container instable

2. **Monitoring externe**
   - Un service externe pourrait surveiller et redémarrer Qdrant
   - Vérifier les tâches planifiées Windows, cron WSL

3. **Problème Docker/WSL**
   - Limites de ressources WSL2 (.wslconfig)
   - Problèmes de connectivité réseau Docker

4. **Problème Application**
   - L'application roo-state-manager pourrait provoquer des redémarrages
   - Vérifier les connexions et requêtes anormales

---

## 📋 RECOMMANDATIONS PRIORITAIRES

### PRIORITÉ 1: Recréer la Collection
```bash
# Script à exécuter: myia_qdrant/scripts/utilities/recreate_collection_with_optimal_hnsw.ps1
# (À créer avec procédure complète)
```

### PRIORITÉ 2: Ajouter Healthcheck Docker
```yaml
# À ajouter dans docker-compose.production.yml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:6333/healthz"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 40s
```

### PRIORITÉ 3: Surveiller les Logs
```bash
# Pendant les 24 prochaines heures
docker-compose -f myia_qdrant/docker-compose.production.yml logs -f --tail 100
```

### PRIORITÉ 4: Investiguer Source SIGTERM
1. Vérifier tâches planifiées Windows
2. Vérifier cron jobs WSL
3. Vérifier logs Docker Desktop
4. Vérifier logs roo-state-manager

---

## 📊 MÉTRIQUES POST-DÉPLOIEMENT

### Configuration Actuelle
```yaml
Service: ✓ Opérationnel
Uptime: 15 secondes (au moment du test)
Config File: ✓ production.yaml présent
max_indexing_threads (config): 16
max_indexing_threads (collection): 0 ⚠️
```

### À Surveiller
- [ ] Pas de redémarrage pendant 24h
- [ ] Logs sans SIGTERM
- [ ] Performance indexation stable
- [ ] Utilisation CPU/RAM normale

---

## 📁 SCRIPTS CRÉÉS

| Script | Chemin | Usage |
|--------|--------|-------|
| Diagnostic Mémoire | `myia_qdrant/scripts/diagnostics/diagnostic_memoire_complet.ps1` | Analyser mémoire système/WSL/container |
| Diagnostic Disque | `myia_qdrant/scripts/diagnostics/diagnostic_espace_disque.ps1` | Analyser espace disque |
| Diagnostic Logs | `myia_qdrant/scripts/diagnostics/diagnostic_logs_qdrant.ps1` | Analyser logs Qdrant |
| Diagnostic Config | `myia_qdrant/scripts/diagnostics/diagnostic_configuration.ps1` | Vérifier configuration |
| Déploiement Fix | `myia_qdrant/scripts/diagnostics/20251014_deploiement_fix_threads.ps1` | Appliquer fix configuration |

---

## 🎯 PROCHAINES ÉTAPES RECOMMANDÉES

### Immédiat (Aujourd'hui)
1. ✅ Configuration production.yaml créée
2. ✅ Service redémarré avec nouvelle config
3. ⏳ **Surveiller pendant 4-6 heures** pour vérifier stabilité
4. ⏳ **Documenter tout nouveau redémarrage** avec timestamp et logs

### Court Terme (24-48h)
1. [ ] Si stabilité confirmée → Recréer collection avec threads=16
2. [ ] Ajouter healthcheck au docker-compose
3. [ ] Identifier et éliminer source des SIGTERM
4. [ ] Créer monitoring automatique des redémarrages

### Moyen Terme (Cette semaine)
1. [ ] Implémenter alertes proactives
2. [ ] Documenter procédure de migration collection
3. [ ] Optimiser autres paramètres HNSW si nécessaire

---

## 📝 NOTES IMPORTANTES

### Pourquoi max_indexing_threads=0 dans la collection?
Les paramètres HNSW sont **définis à la création** de la collection et deviennent **immutables**. La collection a été créée avant que production.yaml n'existe, donc avec les valeurs par défaut de Qdrant.

### Pourquoi les redémarrages continuent?
Le problème de configuration manquante est **résolu**, mais:
1. La source des SIGTERM externes est **encore active**
2. Il faut attendre pour confirmer si le fix suffit
3. D'autres problèmes peuvent exister (healthcheck, monitoring)

### Que signifie max_indexing_threads=0?
`0` = Auto-détection du nombre de threads par Qdrant (généralement nombre de CPU). Sur une machine 31 cœurs, cela peut causer une **surcharge** lors de l'indexation.

---

## 🔗 RÉFÉRENCES

- **Qdrant HNSW Documentation**: https://qdrant.tech/documentation/concepts/indexing/#hnsw-index
- **Qdrant Configuration**: https://qdrant.tech/documentation/guides/configuration/
- **Docker Compose Healthcheck**: https://docs.docker.com/compose/compose-file/05-services/#healthcheck

---

**Rapport généré le**: 2025-10-14 20:22 UTC+2  
**Diagnosticien**: Roo Debug Mode  
**Statut Final**: Configuration corrigée partiellement, surveillance requise