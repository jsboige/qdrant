# Standards de Configuration Qdrant

## Vue d'ensemble

Ce document définit les standards de configuration pour toutes les instances Qdrant du projet.

## Instances Déployées

| Instance | Port | Container | Environnement | Usage |
|----------|------|-----------|---------------|-------|
| Production | 6333 | `qdrant_production` | `.env.production` | Production principale |
| Students | 6335 | `qdrant_students` | `.env.students` | Instance Students |

## Configuration des Collections

### Modèles d'Embedding Supportés

| Modèle | Provider | Dimensions | Distance Recommandée |
|--------|----------|------------|---------------------|
| `text-embedding-3-small` | OpenAI | **1536** | Cosine |
| `text-embedding-3-large` | OpenAI | **3072** | Cosine |
| `text-embedding-ada-002` | OpenAI | **1536** | Cosine |

⚠️ **CRITIQUE**: La dimension doit correspondre EXACTEMENT au modèle utilisé.

### Configuration HNSW Recommandée

```yaml
hnsw_config:
  m: 16                    # Nombre de connexions par nœud (défaut: 16)
  ef_construct: 100        # Taille du beam search pendant construction (défaut: 100)
  full_scan_threshold: 10000  # Seuil pour scan complet vs index (défaut: 10000)
```

**Ajustements selon la charge:**

| Type de Charge | m | ef_construct | Usage Mémoire | Performances |
|----------------|---|--------------|---------------|--------------|
| Faible volume | 16 | 100 | Normal | Bon |
| Volume moyen | 32 | 200 | +50% | Très bon |
| Gros volume | 48 | 300 | +100% | Excellent |

### Configuration des Optimizers

```yaml
optimizer_config:
  deleted_threshold: 0.2   # Seuil de suppression pour compaction (20%)
  vacuum_min_vector_number: 1000  # Nombre minimum de vecteurs pour vacuum
  default_segment_number: 0  # 0 = auto
  max_segment_size: 200000  # Taille max d'un segment (en KB)
  memmap_threshold: 50000   # Seuil pour utiliser memmap
  indexing_threshold: 20000 # Seuil pour créer l'index HNSW
  flush_interval_sec: 5     # Intervalle de flush sur disque
  max_optimization_threads: 1  # Threads pour optimisation
```

### Configuration de Quantization (Optionnelle)

Pour les collections très larges, la quantization peut réduire l'usage mémoire:

```yaml
quantization_config:
  scalar:
    type: "int8"           # Quantification en int8
    quantile: 0.99         # Percentile pour clipping
    always_ram: true       # Garder en RAM
```

## Exemples de Configuration Complète

### Collection Standard (1536 dimensions)

```json
{
  "vectors": {
    "size": 1536,
    "distance": "Cosine"
  },
  "hnsw_config": {
    "m": 16,
    "ef_construct": 100,
    "full_scan_threshold": 10000
  },
  "optimizer_config": {
    "deleted_threshold": 0.2,
    "vacuum_min_vector_number": 1000,
    "default_segment_number": 0,
    "max_segment_size": 200000,
    "memmap_threshold": 50000,
    "indexing_threshold": 20000
  }
}
```

### Collection Haute Performance (3072 dimensions)

```json
{
  "vectors": {
    "size": 3072,
    "distance": "Cosine"
  },
  "hnsw_config": {
    "m": 32,
    "ef_construct": 200,
    "full_scan_threshold": 10000
  },
  "optimizer_config": {
    "deleted_threshold": 0.15,
    "vacuum_min_vector_number": 1000,
    "default_segment_number": 2,
    "max_segment_size": 300000,
    "memmap_threshold": 50000,
    "indexing_threshold": 10000
  },
  "quantization_config": {
    "scalar": {
      "type": "int8",
      "quantile": 0.99,
      "always_ram": true
    }
  }
}
```

## Limites de Ressources Docker

### Production

```yaml
services:
  qdrant_production:
    deploy:
      resources:
        limits:
          memory: 4G           # Limite mémoire
          cpus: '2.0'          # Limite CPU
        reservations:
          memory: 2G           # Réservation mémoire
          cpus: '1.0'          # Réservation CPU
```

### Ajustements selon la charge

| Charge | Memory Limit | CPUs | Collections | Points Total |
|--------|--------------|------|-------------|--------------|
| Légère | 2G | 1.0 | 1-5 | <100K |
| Moyenne | 4G | 2.0 | 5-15 | 100K-1M |
| Lourde | 8G | 4.0 | 15+ | 1M+ |

## Paramètres de Performance

### Variables d'Environnement Recommandées

```bash
# Logs
QDRANT__LOG_LEVEL=INFO                    # Niveau de log (DEBUG|INFO|WARN|ERROR)

# Sécurité
QDRANT__SERVICE__API_KEY=<secure_key>     # API key obligatoire

# Performance
QDRANT__SERVICE__MAX_REQUEST_SIZE_MB=128  # Taille max requête (défaut: 32)
QDRANT__SERVICE__MAX_WORKERS=0            # Workers (0 = auto)
QDRANT__SERVICE__HTTP_PORT=6333           # Port HTTP
QDRANT__SERVICE__GRPC_PORT=6334           # Port gRPC

# Storage
QDRANT__STORAGE__STORAGE_PATH=/qdrant/storage  # Chemin de stockage
QDRANT__STORAGE__SNAPSHOTS_PATH=/qdrant/snapshots  # Chemin snapshots
QDRANT__STORAGE__ON_DISK_PAYLOAD=true     # Payloads sur disque
QDRANT__STORAGE__WAL_CAPACITY_MB=32       # Capacité WAL
QDRANT__STORAGE__WAL_SEGMENTS_AHEAD=0     # Segments WAL en avance

# Performance tuning
QDRANT__STORAGE__PERFORMANCE__MAX_SEARCH_THREADS=0  # Threads search (0=auto)
QDRANT__STORAGE__PERFORMANCE__MAX_OPTIMIZATION_THREADS=1  # Threads optim
```

## Checklist de Validation

Avant de créer/modifier une collection:

- [ ] ✅ Dimension correspond au modèle d'embedding
- [ ] ✅ Distance metric appropriée (généralement Cosine)
- [ ] ✅ Configuration HNSW adaptée au volume
- [ ] ✅ Optimizer config définie
- [ ] ✅ Ressources Docker suffisantes
- [ ] ✅ Backup créé si modification d'existant
- [ ] ✅ Monitoring en place

## Scripts de Validation

Utiliser le script de diagnostic pour vérifier la cohérence:

```powershell
.\myia_qdrant\scripts\diagnostics\analyze_issues.ps1 -FocusOnCollection "ma_collection"
```

## Troubleshooting

### Problème: Freezes récurrents
**Causes possibles:**
- Dimension incorrecte vs modèle
- Mémoire insuffisante
- Trop de segments non optimisés

**Solution:**
1. Vérifier dimension avec `analyze_issues.ps1`
2. Augmenter mémoire Docker si nécessaire
3. Forcer optimisation des segments

### Problème: Indexation lente
**Causes possibles:**
- `ef_construct` trop élevé
- `indexing_threshold` trop bas
- CPU insuffisant

**Solution:**
1. Réduire `ef_construct` à 100
2. Augmenter `indexing_threshold` à 50000
3. Allouer plus de CPU

### Problème: Recherches lentes
**Causes possibles:**
- `m` trop faible
- Index pas créé (sous seuil)
- Quantization inadaptée

**Solution:**
1. Augmenter `m` à 32-48
2. Vérifier que collection > `indexing_threshold`
3. Tester avec/sans quantization

## Références

- [Qdrant Documentation](https://qdrant.tech/documentation/)
- [HNSW Algorithm](https://qdrant.tech/articles/filtrable-hnsw/)
- [Vector Quantization](https://qdrant.tech/documentation/guides/quantization/)
- [Performance Tuning](https://qdrant.tech/documentation/guides/optimize/)

## Historique des Changements

| Date | Changement | Auteur |
|------|------------|--------|
| 2025-10-13 | Document initial basé sur incident freeze | Consolidation |