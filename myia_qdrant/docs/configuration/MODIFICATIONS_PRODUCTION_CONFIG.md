# Modifications config/production.yaml - Documentation

## ⚠️ STATUT: MODIFICATIONS INTENTIONNELLES ET CRITIQUES

**Date des modifications**: 2025-10-14  
**Objectif**: Améliorer la stabilité du service Qdrant Production  
**Impact**: Résolution des redémarrages quotidiens → stabilité continue

---

## 📋 Résumé des Modifications

Les modifications apportées à `config/production.yaml` sont **INTENTIONNELLES** et doivent être **CONSERVÉES**. Elles font partie d'une optimisation de performance et de stabilité documentée.

### Changements Principaux

| Paramètre | Avant | Après | Raison |
|-----------|-------|-------|--------|
| `flush_interval_sec` | 1 | 5 | Réduit la charge I/O |
| `wal_capacity_mb` | 128 | 512 | Augmente buffer Write-Ahead Log |
| `max_workers` | 0 (auto) | 16 | Limite explicite (vs auto=31) |
| `max_search_threads` | 0 (auto) | 16 | Contrôle concurrence recherches |
| `max_optimization_threads` | 0 (auto) | 8 | Balance indexation/disponibilité |
| `memmap_threshold_kb` | 200000 | 300000 | Plus de données en RAM |
| `indexing_threshold_kb` | 200000 | 300000 | Seuil indexation plus élevé |
| `max_request_size_mb` | N/A | 32 | **NOUVEAU** - Limite requêtes |

---

## 🎯 Rationale Détaillé

### 1. Optimisation I/O

```yaml
flush_interval_sec: 1 -> 5
wal_capacity_mb: 128 -> 512
```

**Problème identifié**: Trop de flush disque fréquents causaient une charge I/O excessive.

**Solution**: 
- Augmenter l'intervalle de flush (1→5 sec)
- Augmenter la capacité du WAL (128→512 MB)
- **Résultat**: Moins de contention I/O, meilleure performance

### 2. Contrôle Explicite des Threads

```yaml
max_workers: 0 -> 16
max_search_threads: 0 -> 16
max_optimization_threads: 0 -> 8
```

**Problème identifié**: Auto-détection créait 31 threads (sur-utilisation CPU).

**Solution**: 
- Limites explicites adaptées à la charge réelle
- 16 workers API (vs 31 auto-détectés)
- 16 threads recherche
- 8 threads optimisation/indexation
- **Résultat**: CPU plus équilibré, moins de context switching

### 3. Gestion Mémoire Optimisée

```yaml
memmap_threshold_kb: 200000 -> 300000
indexing_threshold_kb: 200000 -> 300000
```

**Problème identifié**: Trop d'accès disque pour les données chaudes.

**Solution**: 
- Seuils augmentés → plus de données en RAM
- Moins d'accès disque pour les opérations fréquentes
- **Résultat**: Performance améliorée, latence réduite

### 4. Protection Anti-Surcharge

```yaml
max_request_size_mb: 32 (NOUVEAU)
```

**Problème identifié**: Requêtes volumineuses pouvaient déstabiliser le service.

**Solution**: 
- Limite explicite de 32 MB par requête
- Protection contre les abus/erreurs
- **Résultat**: Service plus résilient

---

## ⚡ Paramètres Critiques Inchangés

### HNSW Indexing Threads

```yaml
hnsw_index:
  max_indexing_threads: 0  # ⚠️ GARDÉ À 0 (auto)
```

**Raison CRITIQUE**: 
- 0 = auto-sélection (recommandé officiel Qdrant)
- Valeurs fixes (2 ou moins) → index HNSW corrompus/inefficaces
- Source: https://qdrant.tech/articles/indexing-optimization/

**NE JAMAIS** définir manuellement sauf indication expert.

---

## 📊 Impact Mesuré

### Avant Optimisation (≤ 2025-10-13)
- Redémarrages: Quotidiens
- Utilisation CPU: Pics à 80-90%
- I/O Wait: 15-25%
- Freeze collections: Fréquents

### Après Optimisation (≥ 2025-10-14)
- Stabilité: Continue (0 redémarrage forcé)
- Utilisation CPU: 15-25% stable
- I/O Wait: 5-10%
- Freeze collections: 0 incident

---

## 🔒 Instructions de Maintenance

### ✅ À FAIRE

1. **Conserver ces modifications**
   - Ne PAS reverter vers config upstream
   - Ne PAS revenir aux valeurs auto (0) sans analyse

2. **Monitoring continu**
   ```powershell
   .\myia_qdrant\scripts\health\monitor_qdrant.ps1 -Watch
   ```

3. **Backup avant changement**
   ```powershell
   .\myia_qdrant\scripts\backup\backup_qdrant.ps1
   ```

### ❌ À ÉVITER

1. **NE PAS** faire `git checkout config/production.yaml` sans validation
2. **NE PAS** modifier `max_indexing_threads` (laisser à 0)
3. **NE PAS** réduire les seuils mémoire sans analyse performance

---

## 📝 Procédure de Rollback (si nécessaire)

Si problème critique nécessite rollback:

1. Backup actuel
   ```powershell
   Copy-Item config/production.yaml config/production.optimized.backup.yaml
   ```

2. Restaurer depuis backup
   ```powershell
   Copy-Item myia_qdrant/archive/repatriation_backup_20251016/production.yaml config/
   ```

3. Redémarrer service
   ```powershell
   docker compose restart qdrant_production
   ```

4. Documenter raison du rollback dans ce fichier

---

## 🔗 Références

- **Documentation optimisation**: `myia_qdrant/docs/diagnostics/20251014_DIAGNOSTIC_RESSOURCES_RAPPORT.md`
- **Incident freeze résolu**: `myia_qdrant/docs/incidents/20251013_freeze/`
- **Config upstream originale**: Sauvegardée dans `myia_qdrant/archive/repatriation_backup_20251016/`

---

## 📅 Historique des Versions

| Date | Version | Auteur | Changement |
|------|---------|--------|------------|
| 2025-10-14 | 1.0 | Équipe Ops | Optimisation stabilité (doc initiale) |
| 2025-10-16 | 1.1 | Rapatriement | Documentation formalisée |

---

## ✍️ Notes

Ce fichier documente les modifications **intentionnelles et critiques** de `config/production.yaml`. 

**Important**: Ces modifications ont été testées et validées en production. Elles sont le résultat d'une analyse approfondie des problèmes de stabilité rencontrés en octobre 2025.

Pour toute question ou modification proposée, consulter:
1. Ce document d'abord
2. L'historique Git des modifications
3. Les rapports de diagnostic associés