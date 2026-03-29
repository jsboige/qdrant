# Configuration Qdrant Students

Ce document détaille la configuration du nouveau container Qdrant Students qui sera accessible via `https://students.qdrant.myia.io/`.

## 📋 Configuration créée

### Fichiers configurés :
- **`config/students.yaml`** : Configuration Qdrant spécifique pour Students
- **`docker-compose.students.yml`** : Configuration Docker Compose isolée

### Ports utilisés :
- **6335** : HTTP API Students (mappé vers 6333 interne)
- **6336** : gRPC Students (mappé vers 6334 interne)

## 🚀 Structure des répertoires WSL

### Création automatique via Docker
Les volumes Docker créeront automatiquement la structure suivante :
```
Volumes Docker :
├── qdrant-students-storage/     # Données persistantes Students
└── qdrant-students-snapshots/   # Snapshots Students
```

### Localisation des volumes (WSL)
Les volumes Docker sont généralement stockés dans :
```bash
/var/lib/docker/volumes/qdrant_qdrant-students-storage/_data
/var/lib/docker/volumes/qdrant_qdrant-students-snapshots/_data
```

## 🔧 Commandes de démarrage

### 1. Démarrer uniquement le service Students
```bash
docker-compose -f docker-compose.students.yml up -d
```

### 2. Arrêter le service Students
```bash
docker-compose -f docker-compose.students.yml down
```

### 3. Démarrer avec logs en temps réel
```bash
docker-compose.students.yml up
```

### 4. Reconstruire et redémarrer
```bash
docker-compose -f docker-compose.students.yml up -d --force-recreate
```

## 🔍 Vérification du service

### Health Check
Le service dispose d'un health check automatique :
```bash
curl -f http://localhost:6335/healthz
```

### Vérifier les logs
```bash
docker-compose -f docker-compose.students.yml logs -f
```

### Vérifier que les ports sont bien exposés
```bash
docker ps
# Doit montrer qdrant_students avec les ports 6335:6333 et 6336:6334
```

## 🌐 Accès au service

- **HTTP API** : `http://localhost:6335`
- **gRPC** : `localhost:6336`
- **API Key** : Utilisée depuis le fichier `.env.students` (variable `QDRANT_SERVICE_API_KEY`)

## 📝 Variables d'environnement

Le service utilise un fichier `.env.students` dédié :
```
QDRANT_SERVICE_API_KEY=<YOUR_STUDENTS_API_KEY>
OPENAI_API_KEY=sk-proj-...
```

## 🔒 Sécurité

- Le service utilise une API key dédiée différente du service principal
- Réseau Docker isolé : `qdrant-students-network`
- Health checks configurés pour la surveillance

## 🌐 Configuration Reverse Proxy

### Vue d'ensemble
Le service Qdrant Students doit être exposé publiquement via l'URL `https://students.qdrant.myia.io/`. Cette section documente la configuration recommandée pour les reverse proxies les plus courants.

### Prérequis
- Service Students démarré et accessible localement sur le port 6335
- Certificat SSL valide pour le domaine `students.qdrant.myia.io`
- Configuration DNS pointant vers le serveur

---

### 🔧 Configuration Nginx

#### Fichier de configuration : `/etc/nginx/sites-available/students-qdrant-myia-io`

```nginx
server {
    listen 80;
    server_name students.qdrant.myia.io;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name students.qdrant.myia.io;

    # Configuration SSL
    ssl_certificate /path/to/ssl/students.qdrant.myia.io.crt;
    ssl_certificate_key /path/to/ssl/students.qdrant.myia.io.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Headers de sécurité
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Configuration du proxy
    location / {
        proxy_pass http://localhost:6335;
        proxy_http_version 1.1;
        
        # Headers essentiels pour Qdrant
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $server_name;
        
        # Support des WebSockets (si nécessaire)
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts optimisés pour les requêtes vectorielles
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # Gestion des gros payloads
        client_max_body_size 100M;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # Health check endpoint
    location /healthz {
        proxy_pass http://localhost:6335/healthz;
        proxy_set_header Host $host;
        access_log off;
    }

    # Logs spécifiques
    access_log /var/log/nginx/students-qdrant-access.log;
    error_log /var/log/nginx/students-qdrant-error.log;
}
```

#### Activation de la configuration
```bash
# Créer le lien symbolique
sudo ln -s /etc/nginx/sites-available/students-qdrant-myia-io /etc/nginx/sites-enabled/

# Tester la configuration
sudo nginx -t

# Recharger Nginx
sudo systemctl reload nginx
```

---

### 🔧 Configuration IIS (Windows Server)

#### 1. Installation des modules requis
```powershell
# Installer Application Request Routing (ARR)
# Télécharger depuis : https://www.iis.net/downloads/microsoft/application-request-routing

# Installer URL Rewrite Module
# Télécharger depuis : https://www.iis.net/downloads/microsoft/url-rewrite
```

#### 2. Configuration du site dans IIS Manager

1. **Créer un nouveau site** :
   - Nom : `students-qdrant-myia-io`
   - Port : `443` (HTTPS)
   - Nom d'hôte : `students.qdrant.myia.io`
   - Certificat SSL : Sélectionner le certificat approprié

2. **Ajouter la règle de reverse proxy** dans `web.config` :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <system.webServer>
        <rewrite>
            <rules>
                <rule name="ReverseProxyInboundRule" stopProcessing="true">
                    <match url="(.*)" />
                    <action type="Rewrite" url="http://localhost:6335/{R:1}" />
                    <serverVariables>
                        <set name="HTTP_X_FORWARDED_PROTO" value="https" />
                        <set name="HTTP_X_FORWARDED_FOR" value="{REMOTE_ADDR}" />
                        <set name="HTTP_X_FORWARDED_HOST" value="{HTTP_HOST}" />
                    </serverVariables>
                </rule>
            </rules>
            <outboundRules>
                <rule name="ReverseProxyOutboundRule" preCondition="ResponseIsHtml">
                    <match filterByTags="A, Form, Img" pattern="^http://localhost:6335/(.*)" />
                    <action type="Rewrite" value="https://students.qdrant.myia.io/{R:1}" />
                </rule>
                <preConditions>
                    <preCondition name="ResponseIsHtml">
                        <add input="{RESPONSE_CONTENT_TYPE}" pattern="^text/html" />
                    </preCondition>
                </preConditions>
            </outboundRules>
        </rewrite>
        <httpProtocol>
            <customHeaders>
                <add name="X-Frame-Options" value="DENY" />
                <add name="X-Content-Type-Options" value="nosniff" />
                <add name="X-XSS-Protection" value="1; mode=block" />
            </customHeaders>
        </httpProtocol>
    </system.webServer>
</configuration>
```

3. **Configuration des timeouts** dans `web.config` :

```xml
<system.webServer>
    <security>
        <requestFiltering>
            <requestLimits maxAllowedContentLength="104857600" /> <!-- 100MB -->
        </requestFiltering>
    </security>
    <httpRuntime maxRequestLength="102400" /> <!-- 100MB -->
</system.webServer>
```

---

### 🧪 Tests et Validation

#### 1. Tests de connectivité de base

```bash
# Test de santé via HTTPS
curl -k https://students.qdrant.myia.io/healthz

# Test avec API key
curl -k -H "api-key: <YOUR_STUDENTS_API_KEY>" \
     https://students.qdrant.myia.io/

# Test de création de collection
curl -k -X PUT 'https://students.qdrant.myia.io/collections/test_collection' \
     -H 'Content-Type: application/json' \
     -H 'api-key: <YOUR_STUDENTS_API_KEY>' \
     --data-raw '{
         "vectors": {
             "size": 384,
             "distance": "Cosine"
         }
     }'
```

#### 2. Tests de performance

```bash
# Test de latence
curl -k -o /dev/null -s -w "Total time: %{time_total}s\n" \
     -H "api-key: <YOUR_STUDENTS_API_KEY>" \
     https://students.qdrant.myia.io/

# Test de charge (avec Apache Bench)
ab -n 100 -c 10 -H "api-key: <YOUR_STUDENTS_API_KEY>" \
   https://students.qdrant.myia.io/collections
```

#### 3. Validation PowerShell

```powershell
# Script de validation automatisé
$apiKey = "<YOUR_STUDENTS_API_KEY>"
$baseUrl = "https://students.qdrant.myia.io"
$headers = @{"api-key" = $apiKey}

# Test 1: Health check
try {
    $response = Invoke-RestMethod -Uri "$baseUrl/healthz" -Headers $headers
    Write-Host "✅ Health check: OK" -ForegroundColor Green
} catch {
    Write-Host "❌ Health check: FAILED" -ForegroundColor Red
}

# Test 2: Collections listing
try {
    $response = Invoke-RestMethod -Uri "$baseUrl/collections" -Headers $headers
    Write-Host "✅ Collections API: OK" -ForegroundColor Green
} catch {
    Write-Host "❌ Collections API: FAILED" -ForegroundColor Red
}
```

---

### 📊 Monitoring et Surveillance

#### 1. Logs à surveiller

**Nginx :**
```bash
# Logs d'accès
tail -f /var/log/nginx/students-qdrant-access.log

# Logs d'erreur
tail -f /var/log/nginx/students-qdrant-error.log
```

**IIS :**
- Observateur d'événements → Journaux Windows → Application
- IIS Manager → Sites → Logs → Failed Request Traces

#### 2. Métriques importantes à surveiller

- **Latence** : Temps de réponse < 2s pour les requêtes normales
- **Taux d'erreur** : < 1% d'erreurs 5xx
- **Throughput** : Nombre de requêtes par seconde
- **Certificat SSL** : Date d'expiration

#### 3. Script de monitoring automatisé

```powershell
# Script à exécuter toutes les 5 minutes
$baseUrl = "https://students.qdrant.myia.io"
$apiKey = "<YOUR_STUDENTS_API_KEY>"
$headers = @{"api-key" = $apiKey}

try {
    $startTime = Get-Date
    $response = Invoke-RestMethod -Uri "$baseUrl/healthz" -Headers $headers
    $duration = (Get-Date) - $startTime
    
    if ($duration.TotalMilliseconds -gt 5000) {
        Write-Warning "Latence élevée: $($duration.TotalMilliseconds)ms"
    }
    
    Write-Host "[$(Get-Date)] Service Students OK - Latence: $($duration.TotalMilliseconds)ms"
} catch {
    Write-Error "[$(Get-Date)] Service Students INDISPONIBLE: $($_.Exception.Message)"
    # Ici, vous pourriez envoyer une alerte
}
```

---

### 🔧 Troubleshooting

#### Problèmes courants

**1. Erreur 502 Bad Gateway**
```bash
# Vérifier que le service Students est démarré
docker ps | grep students
curl http://localhost:6335/healthz

# Redémarrer le service si nécessaire
docker-compose -f docker-compose.students.yml restart
```

**2. Erreur de certificat SSL**
```bash
# Vérifier le certificat
openssl x509 -in /path/to/cert.crt -text -noout

# Tester le certificat
openssl s_client -connect students.qdrant.myia.io:443
```

**3. Timeouts sur les grosses requêtes**
- Augmenter `proxy_read_timeout` dans Nginx
- Augmenter `client_max_body_size` pour les gros uploads
- Vérifier les limites dans IIS

**4. Headers CORS manquants**
Ajouter dans Nginx :
```nginx
add_header Access-Control-Allow-Origin "*";
add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
add_header Access-Control-Allow-Headers "api-key, Content-Type";
```

---

## 🎯 Prochaines étapes

1. **Démarrer le service** avec la commande `docker-compose -f docker-compose.students.yml up -d`
2. **Configurer le reverse proxy** selon les instructions ci-dessus
3. **Tester l'API** sur l'URL publique avec les scripts de validation
4. **Configurer le monitoring** automatisé
5. **Mettre à jour la documentation** de l'API avec la nouvelle URL publique

## ⚠️ Notes importantes

- Les données sont stockées dans des volumes Docker séparés du service principal
- Le container utilise la même image que le service principal (`qdrant/qdrant:latest`)
- La configuration est identique à celle de production, adaptée pour Students
- Les ports 6335/6336 doivent être libres sur la machine hôte
- **Le certificat SSL doit être valide et configuré avant la mise en production**
- **L'API key est dédiée au service Students et différente du service principal - assurez-vous de la sécuriser**