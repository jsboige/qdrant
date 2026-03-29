# Qdrant Instance Management

Ce projet gère plusieurs instances de Qdrant pour différents environnements et cas d'usage.

## 🏗️ Architecture des Services

### Services Qdrant Disponibles

#### 1. Service Principal (Production)
- **URL** : `http://localhost:6333` (HTTP API) 
- **gRPC** : `localhost:6334`
- **Configuration** : `config/production.yaml`
- **Docker Compose** : `docker-compose.yml`

#### 2. Service GenAI ✨
- **URL Locale** : `http://localhost:6335` (HTTP API)
- **URL Publique** : `https://genai.qdrant.myia.io/`
- **gRPC** : `localhost:6336`
- **Configuration** : `config/genai.yaml`
- **Docker Compose** : `docker-compose.genai.yml`
- **Documentation** : [SETUP_GENAI_QDRANT.md](./SETUP_GENAI_QDRANT.md)

---

## 🚀 Démarrage Rapide

### Service Principal
```bash
# Démarrer le service principal
docker-compose up -d

# Vérifier le statut
curl http://localhost:6333/healthz
```

### Service GenAI
```bash
# Démarrer le service GenAI
docker-compose -f docker-compose.genai.yml up -d

# Vérifier le statut
curl http://localhost:6335/healthz
```

---

## 📁 Structure du Projet

```
qdrant/
├── README.md                           # Ce fichier
├── SETUP_GENAI_QDRANT.md              # Guide de configuration GenAI
├── docker-compose.yml                  # Service principal
├── docker-compose.genai.yml           # Service GenAI
├── .env                               # Variables d'environnement
├── config/
│   ├── production.yaml                # Configuration service principal
│   └── genai.yaml                     # Configuration service GenAI
├── myia_qdrant/                       # Scripts de gestion
│   ├── README.md                      # Documentation des scripts
│   ├── backup.ps1                     # Sauvegarde des collections
│   ├── restore.ps1                    # Restauration depuis snapshots
│   ├── monitor_qdrant_health.ps1      # Surveillance automatique
│   └── setup_automated_*.ps1          # Scripts d'installation
├── QdrantValidator/                   # Outil de validation
├── roo_docs/                         # Documentation ROO
├── tests/                            # Tests d'intégration
└── tools/                            # Outils de développement
```

---

## 🔒 Configuration Sécurité

### API Keys
Toutes les instances utilisent la même API key définie dans `.env` :
```bash
QDRANT_SERVICE_API_KEY=<YOUR_PRODUCTION_API_KEY>
```

### Usage de l'API Key
```bash
# Avec curl
curl -H "api-key: <YOUR_PRODUCTION_API_KEY>" \
     http://localhost:6333/collections

# Service GenAI public
curl -H "api-key: <YOUR_PRODUCTION_API_KEY>" \
     https://genai.qdrant.myia.io/collections
```

---

## 🛠️ Gestion et Maintenance

### Scripts Automatisés
Le dossier `myia_qdrant/` contient des scripts PowerShell pour :
- **Backup automatique** : Sauvegarde toutes les 3 heures
- **Monitoring** : Surveillance et récupération automatique
- **Restauration** : Récupération depuis les snapshots

Voir [myia_qdrant/README.md](./myia_qdrant/README.md) pour plus de détails.

### Commandes Utiles

#### Logs
```bash
# Service principal
docker-compose logs -f

# Service GenAI
docker-compose -f docker-compose.genai.yml logs -f
```

#### Nettoyage
```bash
# Arrêter tous les services
docker-compose down
docker-compose -f docker-compose.genai.yml down

# Nettoyage complet (⚠️ supprime les données)
docker-compose down -v
docker-compose -f docker-compose.genai.yml down -v
```

---

## 🌐 Accès Public

### Service GenAI
Le service GenAI est accessible publiquement via :
- **URL** : `https://genai.qdrant.myia.io/`
- **Configuration** : Reverse proxy (Nginx/IIS) → `localhost:6335`
- **Certificat SSL** : Configuré pour le domaine `genai.qdrant.myia.io`

Voir [SETUP_GENAI_QDRANT.md](./SETUP_GENAI_QDRANT.md) pour la configuration complète du reverse proxy.

---

## 📊 Monitoring

### Health Checks
```bash
# Service principal
curl http://localhost:6333/healthz

# Service GenAI (local)
curl http://localhost:6335/healthz

# Service GenAI (public)
curl https://genai.qdrant.myia.io/healthz
```

### Métriques
- Les services exposent des métriques via leurs endpoints respectifs
- Logs centralisés via Docker Compose
- Monitoring automatique configuré via les scripts PowerShell

---

## 🧪 Tests et Validation

### Tests de Base
```bash
# Tester le service principal
curl -X PUT 'http://localhost:6333/collections/test' \
     -H 'Content-Type: application/json' \
     -H 'api-key: <YOUR_PRODUCTION_API_KEY>' \
     --data-raw '{"vectors": {"size": 384, "distance": "Cosine"}}'

# Tester le service GenAI
curl -X PUT 'https://genai.qdrant.myia.io/collections/test_genai' \
     -H 'Content-Type: application/json' \
     -H 'api-key: <YOUR_PRODUCTION_API_KEY>' \
     --data-raw '{"vectors": {"size": 384, "distance": "Cosine"}}'
```

### Outil de Validation
Le projet inclut un validateur C# dans `QdrantValidator/` pour des tests plus poussés.

---

## 🆘 Support et Troubleshooting

### Problèmes Courants

1. **Service ne démarre pas**
   ```bash
   # Vérifier les logs
   docker-compose logs [nom_service]
   
   # Recréer les containers
   docker-compose up -d --force-recreate
   ```

2. **Port déjà utilisé**
   ```bash
   # Vérifier les ports utilisés
   netstat -tulpn | grep :6333
   netstat -tulpn | grep :6335
   ```

3. **Erreur d'API Key**
   - Vérifier la variable dans `.env`
   - Redémarrer les services après modification

### Récupération d'Urgence
En cas de corruption des données :
```powershell
# Exécuter le script de restauration
pwsh -c "./myia_qdrant/restore.ps1"
```

---

## 📚 Documentation Complète

- **[SETUP_GENAI_QDRANT.md](./SETUP_GENAI_QDRANT.md)** : Configuration complète du service GenAI et reverse proxy
- **[myia_qdrant/README.md](./myia_qdrant/README.md)** : Documentation des scripts de gestion
- **[roo_docs/README.md](./roo_docs/README.md)** : Documentation ROO

---

## 🏷️ Version et Maintenance

- **Version Qdrant** : `latest` (Docker image)
- **Dernière mise à jour** : 2025-01-11
- **Maintenu par** : MYIA Team

Pour toute question ou problème, consulter la documentation spécifique ou les logs des services.