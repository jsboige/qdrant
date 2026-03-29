# Recommandations Modèles d'Embeddings 2026
# Date: 2026-01-29
# Contexte: Abandon Qwen 8B (trop lourd RTX 3080) - Recherche alternatives

## 📋 Contexte

### Situation Actuelle
- **Production**: OpenAI text-embedding-3-small (1536 dimensions)
- **Problème**: Modèle obsolète, coûteux, dépendance API externe
- **Tentative Qwen3 8B**: Abandonnée (trop gourmand en VRAM pour RTX 3080)

### Objectifs
- ✅ Modèle open-source performant
- ✅ Léger en VRAM (compatible RTX 3080 10GB)
- ✅ Meilleur qu'OpenAI text-embedding-3-small
- ✅ Rapide (< 2s par embedding)
- ✅ Multi-lingue de préférence

---

## 🏆 Modèles Recommandés (Classés par Priorité)

### 1. BGE-M3 (BAAI) ⭐ **RECOMMANDÉ**

**Spécifications**:
- **Paramètres**: ~560M
- **Dimensions**: 1024
- **MTEB Score**: 63.0 (meilleur open-source)
- **VRAM**: ~2GB
- **Langues**: Multi-lingue (100+ langues)
- **Latence**: ~50-100ms par embedding

**Avantages**:
- ✅ Meilleur score MTEB open-source
- ✅ Très léger en VRAM (2GB)
- ✅ Compatible RTX 3080 sans problème
- ✅ Multi-lingue excellent
- ✅ Supporte query rewriting via prefixes

**Configuration Qdrant**:
```yaml
vectors:
  size: 1024
  distance: Cosine
hnsw_config:
  m: 32
  ef_construct: 200
  on_disk: true
```

**Déploiement Ollama**:
```bash
# Télécharger le modèle
ollama pull bge-m3

# Serveur embeddings
ollama serve

# Test
curl http://localhost:11434/api/embeddings \
  -d '{"model": "bge-m3", "prompt": "test"}'
```

**Impact Migration**:
- OpenAI 1536 → BGE-M3 1024 = **-33% dimensions**
- Moins de mémoire, plus rapide qu'OpenAI
- **Recréer toutes les collections**

---

### 2. Nomic-embed-text-v1.5 ⭐ **ALTERNATIVE LÉGÈRE**

**Spécifications**:
- **Paramètres**: ~137M
- **Dimensions**: 768
- **MTEB Score**: 59.4
- **VRAM**: <1GB
- **Langues**: Principalement anglais, support multi-lingue limité
- **Latence**: <30ms par embedding

**Avantages**:
- ✅ Ultra léger (137M params)
- ✅ Très rapide (<30ms)
- ✅ Bon rapport qualité/coût
- ✅ Facile à déployer

**Configuration Qdrant**:
```yaml
vectors:
  size: 768
  distance: Cosine
hnsw_config:
  m: 24
  ef_construct: 150
  on_disk: true
```

**Déploiement Ollama**:
```bash
ollama pull nomic-embed-text

# Serveur embeddings
ollama serve
```

**Impact Migration**:
- OpenAI 1536 → Nomic 768 = **-50% dimensions**
- Très rapide, léger
- **Recréer toutes les collections**

---

### 3. EmbeddingGemma-300M (Google) ⭐ **OPTION MOBILE/EDGE**

**Spécifications**:
- **Paramètres**: 300M
- **Dimensions**: 128/256/512/768 (Matryoshka)
- **MTEB Score**: ~57
- **VRAM**: <1GB (peut tourner sur CPU)
- **Langues**: Multi-lingue (100+ langues)
- **Latence**: <22ms sur EdgeTPU, ~50ms CPU

**Avantages**:
- ✅ Ultra léger (300M, <200MB RAM quantized)
- ✅ Matryoshka Representation Learning (dimensions flexibles)
- ✅ Peut tourner sur CPU si besoin
- ✅ Multi-lingue Google quality

**Configuration Qdrant** (768 dims max):
```yaml
vectors:
  size: 768
  distance: Cosine
hnsw_config:
  m: 24
  ef_construct: 150
  on_disk: true
```

**Avantage MRL**: Peut utiliser 256 ou 512 dims pour économiser espace/vitesse

---

### 4. Qwen3 0.6B (Alibaba) - Version Légère

**Spécifications**:
- **Paramètres**: 600M
- **Dimensions**: 1024
- **MTEB Score**: ~58
- **VRAM**: ~2GB
- **Langues**: Multi-lingue (fort sur chinois/anglais)

**Avantages**:
- ✅ Version légère de Qwen (vs 8B abandonné)
- ✅ Compatible RTX 3080
- ✅ Bon si écosystème Qwen déjà en place

**Configuration Qdrant**:
```yaml
vectors:
  size: 1024
  distance: Cosine
hnsw_config:
  m: 32
  ef_construct: 200
  on_disk: true
```

---

## 📊 Comparaison Détaillée

| Critère | BGE-M3 | Nomic-v1.5 | EmbeddingGemma | Qwen3 0.6B | OpenAI (actuel) |
|---------|--------|------------|----------------|------------|-----------------|
| **MTEB Score** | **63.0** ⭐ | 59.4 | ~57 | ~58 | ~61 |
| **Params** | 560M | 137M | 300M | 600M | ? |
| **Dimensions** | 1024 | 768 | 128-768 | 1024 | 1536 |
| **VRAM** | ~2GB | <1GB | <1GB | ~2GB | N/A |
| **Latence** | ~50-100ms | <30ms | <50ms | ~80ms | ~200-500ms |
| **Multi-lingue** | ✅ Excellent | ⚠️ Limité | ✅ Excellent | ✅ Bon | ✅ Bon |
| **Coût** | Gratuit | Gratuit | Gratuit | Gratuit | **$$$** |
| **Déploiement** | Ollama | Ollama | HF/Local | Ollama | API |

---

## 🎯 Recommandation Finale

### Pour Votre Use Case (RTX 3080, MyIA)

**Choix #1: BGE-M3** ⭐
- Meilleur score MTEB open-source (63.0)
- Parfaitement adapté RTX 3080 (2GB VRAM)
- Multi-lingue excellent
- Écosystème mature (BAAI)

**Choix #2: Nomic-embed-v1.5** (si besoin ultra-rapide)
- Ultra léger et rapide
- Bon pour prototypage/tests
- Moins bon multi-lingue

**Choix #3: EmbeddingGemma-300M** (si besoin edge/mobile)
- Dimensions flexibles (MRL)
- Peut tourner sur CPU
- Google quality

---

## 🚀 Plan de Migration Recommandé

### Phase 1: Validation (1 jour)
1. Déployer BGE-M3 via Ollama sur machine test
2. Tester performance/qualité sur échantillon
3. Comparer avec OpenAI sur métriques clés

### Phase 2: Migration Collections (3-5 jours)
1. Backup complet des collections actuelles
2. Créer nouvelles collections avec 1024 dims (BGE-M3)
3. Ré-générer embeddings avec BGE-M3
4. Réindexer progressivement (par ordre priorité)

### Phase 3: Déploiement (1 jour)
1. Mettre à jour applications clientes
2. Basculer vers BGE-M3 en production
3. Monitoring intensif

### Phase 4: Nettoyage (1 jour)
1. Supprimer anciennes collections OpenAI
2. Documenter migration
3. Former équipes

**Timeline totale**: 1-2 semaines

---

## 📋 Checklist Migration

### Pré-Migration
- [ ] BGE-M3 déployé et testé (Ollama)
- [ ] Backup complet collections actuelles
- [ ] Espace disque vérifié (collections 1024 dims)
- [ ] RAM Qdrant suffisante (estimations faites)
- [ ] Plan de rollback documenté

### Migration
- [ ] Collection test migrée (1024 dims)
- [ ] Validation qualité embeddings BGE-M3
- [ ] Migration collections prioritaires
- [ ] Validation post-migration
- [ ] Applications clientes mises à jour

### Post-Migration
- [ ] Monitoring actif (performance, qualité)
- [ ] Anciennes collections OpenAI supprimées
- [ ] Documentation mise à jour
- [ ] Coûts OpenAI API arrêtés

---

## 🔧 Configuration Technique

### Ollama Serveur Embeddings (BGE-M3)

**Installation**:
```bash
# Installer Ollama (si pas déjà fait)
curl https://ollama.ai/install.sh | sh

# Télécharger BGE-M3
ollama pull bge-m3

# Démarrer serveur
ollama serve
```

**API Compatible OpenAI**:
```python
import requests

def get_embedding(text: str) -> list:
    response = requests.post(
        "http://localhost:11434/api/embeddings",
        json={
            "model": "bge-m3",
            "prompt": text
        }
    )
    return response.json()["embedding"]
```

**Configuration Qdrant pour BGE-M3**:
```yaml
# config/production.bge-m3.yaml
storage:
  storage_path: /qdrant/storage
  on_disk_payload: true

  optimizers:
    indexing_threshold_kb: 8000  # Adapté pour 1024 dims
    max_optimization_threads: 4

  hnsw_index:
    on_disk: true
    m: 32  # Optimal pour 1024 dimensions
    ef_construct: 200
    max_indexing_threads: 4

service:
  max_request_size_mb: 32
```

---

## 📚 Références

### Benchmarks
- [MTEB Leaderboard](https://huggingface.co/spaces/mteb/leaderboard)
- [Open Source Embedding Models Guide (BentoML)](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models)
- [Best Embedding Models Benchmarked (Supermemory)](https://supermemory.ai/blog/best-open-source-embedding-models-benchmarked-and-ranked/)

### Modèles
- [BGE-M3 (HuggingFace)](https://huggingface.co/BAAI/bge-m3)
- [Nomic-embed-text-v1.5 (HuggingFace)](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5)
- [EmbeddingGemma-300M (Google)](https://ai.google.dev/gemma/docs/embedding_guide)

### Outils
- [Ollama](https://ollama.ai/)
- [Qdrant Documentation](https://qdrant.tech/documentation/)

---

## 🎯 Conclusion

**BGE-M3 est le choix optimal** pour votre cas d'usage :
- ✅ Meilleur score MTEB open-source (63.0)
- ✅ Léger et compatible RTX 3080 (2GB VRAM)
- ✅ Multi-lingue excellent
- ✅ Facile à déployer (Ollama)
- ✅ Gratuit, aucun coût API

**Migration estimée**: 1-2 semaines avec approche progressive.

**ROI immédiat**: Économies API OpenAI + meilleure qualité embeddings.

---

*Document créé le 2026-01-29*
*Recommandations Modèles d'Embeddings 2026*
