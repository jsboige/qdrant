# Setup MCP Qdrant pour Recherche Sémantique Claude Code
# Date: 2026-01-29
# Objectif: Intégrer recherche sémantique dans Claude Code sur toutes les machines

## 📋 Vue d'ensemble

Ce guide explique comment configurer un serveur MCP (Model Context Protocol) pour ajouter la recherche sémantique de code dans Claude Code.

**Avec MCP Qdrant, Claude Code pourra**:
- 🔍 Faire des recherches sémantiques dans tout le codebase
- 📝 Indexer automatiquement du code avec descriptions
- 🎯 Trouver du code par signification (pas juste keywords)
- 🚀 Accélérer la compréhension de grandes codebases

---

## 🎯 Options MCP Disponibles

### Option 1: mcp-server-qdrant (Officiel Qdrant) ⭐ **RECOMMANDÉ**

**Avantages**:
- ✅ Officiel et maintenu par Qdrant
- ✅ Utilise votre Qdrant existant (6333/6335)
- ✅ Simple à configurer
- ✅ Compatible avec tous les modèles d'embeddings

**Prérequis**:
- Python 3.10+ avec `uvx` (ou `npx` pour version npm)
- Qdrant en cours d'exécution (déjà le cas)
- Modèle d'embeddings (local ou API)

**Installation**:
```bash
# Via Python (recommandé)
pip install mcp-server-qdrant

# OU via uvx (auto-install)
uvx mcp-server-qdrant
```

**Configuration Claude Code** (`~/.claude/settings.json`):
```json
{
  "mcpServers": {
    "qdrant-production": {
      "command": "uvx",
      "args": ["mcp-server-qdrant"],
      "env": {
        "QDRANT_URL": "http://localhost:6333",
        "QDRANT_API_KEY": "<YOUR_PRODUCTION_API_KEY>",
        "COLLECTION_NAME": "code_search",
        "EMBEDDING_MODEL": "sentence-transformers/all-MiniLM-L6-v2"
      }
    },
    "qdrant-students": {
      "command": "uvx",
      "args": ["mcp-server-qdrant"],
      "env": {
        "QDRANT_URL": "http://localhost:6335",
        "QDRANT_API_KEY": "<YOUR_PRODUCTION_API_KEY>",
        "COLLECTION_NAME": "code_search_students",
        "EMBEDDING_MODEL": "sentence-transformers/all-MiniLM-L6-v2"
      }
    }
  }
}
```

**Outils disponibles dans Claude Code**:
- `qdrant-store`: Indexer code/docs avec description
- `qdrant-find`: Recherche sémantique
- `qdrant-delete`: Supprimer entrées

**Exemple d'utilisation**:
```
# Dans Claude Code, tu peux dire:
"Store this authentication function in the code search"
"Find all error handling patterns in the codebase"
"Search for database connection implementations"
```

---

### Option 2: claude-context-local (Local, Gratuit)

**Avantages**:
- ✅ 100% local, aucun coût API
- ✅ Utilise EmbeddingGemma-300M (Google)
- ✅ Auto-indexation du codebase
- ✅ Multi-langues (15 extensions)

**Prérequis**:
- Node.js 18+
- EmbeddingGemma model (téléchargé automatiquement)

**Installation**:
```bash
npm install -g claude-context-local
```

**Configuration Claude Code**:
```json
{
  "mcpServers": {
    "claude-context": {
      "command": "claude-context-local",
      "args": ["--workspace", "/path/to/your/project"],
      "env": {
        "EMBEDDING_MODEL": "google/embedding-gemma-300m"
      }
    }
  }
}
```

**Avantages**:
- Pas besoin de Qdrant séparé
- Tout est local et gratuit
- Indexation automatique au démarrage

---

### Option 3: @iflow-mcp/qdrant-mcp-server (AST-Aware)

**Avantages**:
- ✅ Chunking intelligent (fonctions/classes)
- ✅ Support 35+ langages
- ✅ Recherche hybride (BM25 + vecteurs)
- ✅ Utilise Ollama pour embeddings locaux

**Prérequis**:
- Node.js 18+
- Ollama avec modèle d'embeddings
- Qdrant en cours d'exécution

**Installation**:
```bash
npm install -g @iflow-mcp/qdrant-mcp-server
```

**Configuration Claude Code**:
```json
{
  "mcpServers": {
    "qdrant-code": {
      "command": "qdrant-mcp-server",
      "args": ["--workspace", "/path/to/project"],
      "env": {
        "QDRANT_URL": "http://localhost:6333",
        "QDRANT_API_KEY": "<YOUR_PRODUCTION_API_KEY>",
        "OLLAMA_URL": "http://localhost:11434",
        "EMBEDDING_MODEL": "bge-m3"
      }
    }
  }
}
```

**Avantages**:
- Chunking basé sur l'AST (arbre syntaxique)
- Comprend la structure du code
- Meilleure précision sur requêtes code

---

## 🚀 Guide d'Installation Rapide (Recommandé)

### Étape 1: Installer mcp-server-qdrant

```bash
# Vérifier Python 3.10+
python --version

# Installer le serveur MCP
pip install mcp-server-qdrant

# OU tester directement avec uvx (pas d'install)
uvx --help
```

### Étape 2: Créer Collection Qdrant

```bash
# Créer collection code_search dans production
curl -X PUT "http://localhost:6333/collections/code_search" \
  -H "Content-Type: application/json" \
  -H "api-key: <YOUR_PRODUCTION_API_KEY>" \
  -d '{
    "vectors": {
      "size": 384,
      "distance": "Cosine"
    },
    "optimizers_config": {
      "indexing_threshold": 10000
    },
    "hnsw_config": {
      "m": 16,
      "ef_construct": 100,
      "on_disk": true
    }
  }'
```

**Note**: `size: 384` correspond au modèle `all-MiniLM-L6-v2` (léger et rapide)

### Étape 3: Configurer Claude Code

**Windows**: `%USERPROFILE%\.claude\settings.json`
**Linux/Mac**: `~/.claude/settings.json`

```json
{
  "mcpServers": {
    "qdrant": {
      "command": "uvx",
      "args": ["mcp-server-qdrant"],
      "env": {
        "QDRANT_URL": "http://localhost:6333",
        "QDRANT_API_KEY": "<YOUR_PRODUCTION_API_KEY>",
        "COLLECTION_NAME": "code_search",
        "EMBEDDING_MODEL": "sentence-transformers/all-MiniLM-L6-v2"
      }
    }
  }
}
```

### Étape 4: Redémarrer Claude Code

```bash
# Fermer Claude Code complètement
# Rouvrir Claude Code

# Vérifier que le MCP est chargé
# Dans Claude Code, taper: "List available tools"
# Tu devrais voir: qdrant-store, qdrant-find, qdrant-delete
```

### Étape 5: Test

```
# Dans Claude Code:
"Store this function as an example of error handling:
def handle_error(e):
    log.error(f'Error: {e}')
    return {'error': str(e)}"

# Puis:
"Find examples of error handling in the codebase"
```

---

## 🔧 Configuration Avancée

### Utiliser BGE-M3 (Meilleur Modèle)

Si tu as déployé BGE-M3 via Ollama:

1. **Modifier la collection** (1024 dims au lieu de 384):
```bash
curl -X PUT "http://localhost:6333/collections/code_search_bge" \
  -H "Content-Type: application/json" \
  -H "api-key: <YOUR_PRODUCTION_API_KEY>" \
  -d '{
    "vectors": {
      "size": 1024,
      "distance": "Cosine"
    }
  }'
```

2. **Configurer MCP pour Ollama**:
```json
{
  "mcpServers": {
    "qdrant-bge": {
      "command": "uvx",
      "args": ["mcp-server-qdrant"],
      "env": {
        "QDRANT_URL": "http://localhost:6333",
        "QDRANT_API_KEY": "<YOUR_PRODUCTION_API_KEY>",
        "COLLECTION_NAME": "code_search_bge",
        "EMBEDDING_PROVIDER": "ollama",
        "OLLAMA_URL": "http://localhost:11434",
        "EMBEDDING_MODEL": "bge-m3"
      }
    }
  }
}
```

### Multi-Machines (RooSync)

Pour déployer sur toutes les machines via RooSync:

1. **Créer config MCP partagée**:
```json
// Dans shared config (à distribuer via RooSync)
{
  "mcpServers": {
    "qdrant-shared": {
      "command": "uvx",
      "args": ["mcp-server-qdrant"],
      "env": {
        "QDRANT_URL": "http://myia-ai-01:6333",
        "QDRANT_API_KEY": "<YOUR_PRODUCTION_API_KEY>",
        "COLLECTION_NAME": "shared_code_search",
        "EMBEDDING_MODEL": "sentence-transformers/all-MiniLM-L6-v2"
      }
    }
  }
}
```

2. **Distribuer via RooSync**:
```powershell
# Utiliser MCP roo-state-manager pour distribuer la config
# (À implémenter dans RooSync)
```

---

## 📊 Comparaison des Options

| Critère | mcp-server-qdrant | claude-context-local | @iflow-mcp/qdrant |
|---------|-------------------|----------------------|-------------------|
| **Setup** | Simple | Très simple | Moyen |
| **Coût** | Gratuit (si Ollama) | Gratuit | Gratuit (si Ollama) |
| **Qualité** | Dépend du modèle | Bonne | Excellente (AST) |
| **Langues** | Toutes | 15 extensions | 35+ langages |
| **Chunking** | Basic | Smart | AST-aware ⭐ |
| **Qdrant** | Requis | Non | Requis |
| **Maintenance** | Officiel Qdrant | Communauté | Communauté |

---

## 🎯 Recommandation

**Pour MyIA avec Qdrant existant**:
1. **Démarrer avec mcp-server-qdrant** (officiel, simple)
2. Utiliser `all-MiniLM-L6-v2` pour tester
3. Si satisfait, upgrader vers BGE-M3 via Ollama
4. Si besoin chunking avancé, tester `@iflow-mcp/qdrant`

**Timeline**:
- Setup initial: 30 minutes
- Test et validation: 1-2 heures
- Déploiement multi-machines: 1 jour

---

## 🐛 Troubleshooting

### MCP ne se charge pas dans Claude Code

**Vérifier**:
```bash
# Tester le MCP manuellement
uvx mcp-server-qdrant --help

# Vérifier les logs Claude Code
# Windows: %APPDATA%\Claude\logs
# Linux: ~/.config/Claude/logs
```

### Collection Qdrant non créée

**Créer manuellement**:
```bash
curl -X PUT "http://localhost:6333/collections/code_search" \
  -H "Content-Type: application/json" \
  -H "api-key: <YOUR_PRODUCTION_API_KEY>" \
  -d '{"vectors": {"size": 384, "distance": "Cosine"}}'
```

### Embeddings lents

**Solutions**:
- Utiliser un modèle plus léger (`all-MiniLM-L6-v2`)
- Déployer Ollama avec BGE-M3 localement
- Augmenter RAM/CPU alloués à Ollama

---

## 📚 Références

### Documentation
- [mcp-server-qdrant GitHub](https://github.com/qdrant/mcp-server-qdrant)
- [claude-context-local GitHub](https://github.com/FarhanAliRaza/claude-context-local)
- [@iflow-mcp/qdrant npm](https://www.npmjs.com/package/@iflow-mcp/qdrant-mcp-server)
- [Model Context Protocol Spec](https://spec.modelcontextprotocol.io/)

### Tutoriels
- [Qdrant MCP Webinar](https://qdrant.tech/blog/webinar-vibe-coding-rag/)
- [Semantic Code Search in Claude Code](https://medium.com/@jldavern/semantic-code-search-in-claude-code-the-missing-feature-32b22d62f6a2)

---

## 🎯 Prochaines Étapes

1. **Choisir option MCP** (recommandé: mcp-server-qdrant)
2. **Installer et configurer** (suivre guide rapide)
3. **Tester sur machine locale** (validation)
4. **Déployer multi-machines** (via RooSync si besoin)
5. **Former utilisateurs** (documentation + exemples)

**Bénéfices attendus**:
- 🚀 Recherche code 10x plus rapide
- 🎯 Meilleure compréhension codebase
- 💡 Découverte de patterns existants
- ⚡ Productivité accrue dans Claude Code

---

*Document créé le 2026-01-29*
*Guide Setup MCP Qdrant pour Claude Code*
