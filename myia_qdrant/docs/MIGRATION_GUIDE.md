# 📘 Guide de Migration Qdrant - Configuration Optimisée

**Date de création:** 2025-10-07  
**Version:** 1.0  
**Objectif:** Migrer de `production.yaml` vers `production.optimized.yaml` pour améliorer la stabilité

---

## 📋 Vue d'ensemble

Cette migration vise à résoudre les redémarrages quotidiens de Qdrant en optimisant:
- ✅ La gestion des ressources CPU et mémoire
- ✅ Les paramètres d'I/O et de flush
- ✅ La capacité du Write-Ahead Log (WAL)
- ✅ Les seuils de mémoire et d'indexation

**Durée estimée:** 15-30 minutes (dépend de la taille des données)  
**Impact:** Redémarrage du service requis (~2-5 minutes d'indisponibilité)

---

## ⚠️ Prérequis et Vérifications

### 1. Vérifications Système

```powershell
# Vérifier que le container est en cours d'exécution
docker ps | Select-String "qdrant_production"

# Vérifier l'espace disque disponible (minimum 10 GB recommandé)
Get-PSDrive | Where-Object {$_.Name -eq 'C'}

# Vérifier la connexion à Qdrant
curl http://localhost:6333/healthz
```

**Critères de succès:**
- ✅ Container actif et sain
- ✅ Au moins 10 GB d'espace disque libre
- ✅ API Qdrant répond correctement

### 2. Informations Nécessaires

Avant de commencer, assurez-vous d'avoir:
- [ ] Accès administrateur PowerShell
- [ ] Accès au serveur où Docker est installé
- [ ] Clé API Qdrant: `<YOUR_PRODUCTION_API_KEY>`
- [ ] Au moins 30 minutes de disponibilité
- [ ] Un plan de communication si le service est critique

### 3. Fenêtre de Maintenance Recommandée

**Meilleur moment:** Heures creuses (nuit/week-end) pour minimiser l'impact utilisateur.

---

## 🎯 Étapes de Migration Détaillées

### Phase 1: Sauvegarde Complète (5-10 min)

#### Étape 1.1: Exécuter le script de sauvegarde

```powershell
# Naviguer vers le répertoire du projet
cd d:\qdrant

# Exécuter la sauvegarde complète
.\scripts\backup_before_migration.ps1
```

**Ce script effectue:**
1. Création d'un snapshot via l'API Qdrant
2. Sauvegarde de `config/production.yaml` → `config/production.yaml.pre-migration`
3. Sauvegarde de `docker-compose.production.yml` → `docker-compose.production.yml.pre-migration`
4. Export de la liste des collections → `backups/collections_list_[timestamp].json`

**Durée:** 5-10 minutes (dépend du nombre de collections)

**Validation:**
```powershell
# Vérifier que les sauvegardes ont été créées
Get-ChildItem config/*.pre-migration
Get-ChildItem backups/
```

**Critères de succès:**
- ✅ Fichier `config/production.yaml.pre-migration` existe
- ✅ Fichier `docker-compose.production.yml.pre-migration` existe
- ✅ Fichier JSON de collections dans `backups/`
- ✅ Aucune erreur dans les logs

---

### Phase 2: Arrêt Gracieux du Service (2-3 min)

#### Étape 2.1: Arrêter le container avec grace period étendu

```powershell
# Arrêt gracieux avec 60 secondes de délai
docker stop -t 60 qdrant_production
```

**Ce que cela fait:**
- Envoie un signal SIGTERM au processus Qdrant
- Attend 60 secondes pour que Qdrant termine ses opérations
- Flush des données en mémoire vers le disque
- Fermeture propre des connexions

**Durée:** 2-3 minutes

**Validation:**
```powershell
# Vérifier que le container est arrêté
docker ps -a | Select-String "qdrant_production"
# Status doit être "Exited"
```

**Critères de succès:**
- ✅ Container arrêté (status: Exited)
- ✅ Aucun processus Qdrant actif

#### Étape 2.2: Vérifier l'intégrité des données (optionnel mais recommandé)

```powershell
# Vérifier que les fichiers de storage sont intacts
Get-ChildItem -Path "\\wsl.localhost\Ubuntu\home\jesse\qdrant_data\storage" -Recurse | Measure-Object -Property Length -Sum
```

---

### Phase 3: Déploiement de la Nouvelle Configuration (1 min)

#### Étape 3.1: Copier la configuration optimisée

```powershell
# Copier production.optimized.yaml vers production.yaml
Copy-Item -Path "config/production.optimized.yaml" -Destination "config/production.yaml" -Force

# Vérifier que la copie a réussi
Get-Content "config/production.yaml" | Select-String "MODIFIÉ"
```

**Validation:**
```powershell
# Comparer les fichiers pour vérifier les changements
Compare-Object (Get-Content "config/production.yaml.pre-migration") (Get-Content "config/production.yaml")
```

**Critères de succès:**
- ✅ Fichier `config/production.yaml` contient les nouvelles valeurs
- ✅ Commentaires "MODIFIÉ" présents dans le fichier

#### Étape 3.2: Utiliser le nouveau docker-compose (OPTIONNEL)

**Option A: Utiliser le nouveau fichier docker-compose (RECOMMANDÉ)**

```powershell
# Utiliser docker-compose.production.optimized.yml
docker compose -f docker-compose.production.optimized.yml up -d
```

**Option B: Continuer avec l'ancien docker-compose**

```powershell
# Redémarrer avec l'ancien docker-compose (qui va charger la nouvelle config)
docker compose -f docker-compose.production.yml up -d
```

**⚠️ IMPORTANT:** L'Option A est recommandée car elle inclut:
- Limites de ressources (16 GB RAM, 16 CPU)
- Health check automatique
- Stop grace period de 60s

---

### Phase 4: Démarrage et Validation (5-10 min)

#### Étape 4.1: Démarrer le service

```powershell
# Si vous utilisez le nouveau docker-compose (Option A recommandée)
docker compose -f docker-compose.production.optimized.yml up -d

# OU si vous continuez avec l'ancien (Option B)
docker compose -f docker-compose.production.yml up -d
```

**Durée:** 2-5 minutes pour le démarrage complet

#### Étape 4.2: Surveiller les logs de démarrage

```powershell
# Suivre les logs en temps réel
docker logs -f qdrant_production

# Appuyer sur Ctrl+C pour arrêter de suivre les logs
```

**Messages attendus:**
- `[INFO] Starting Qdrant service`
- `[INFO] Loading configuration from /qdrant/config/production.yaml`
- `[INFO] Service started successfully`
- `[INFO] gRPC server listening on...`
- `[INFO] Web server listening on...`

**Durée:** 2-3 minutes d'observation

#### Étape 4.3: Vérifier le health endpoint

```powershell
# Attendre 40 secondes (start_period du health check)
Start-Sleep -Seconds 40

# Tester le health endpoint
curl http://localhost:6333/healthz

# Devrait retourner: {"title":"healthz OK","version":"..."}
```

**Critères de succès:**
- ✅ Health endpoint répond avec status 200
- ✅ Aucune erreur dans les logs
- ✅ Toutes les collections sont accessibles

#### Étape 4.4: Vérifier les collections

```powershell
# Lister toutes les collections
$headers = @{"api-key" = "<YOUR_PRODUCTION_API_KEY>"}
$response = Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $headers
$response.result.collections | Format-Table -AutoSize
```

**Validation:**
- Comparer avec le fichier `backups/collections_list_[timestamp].json`
- Vérifier que toutes les collections sont présentes
- Vérifier que le nombre de points correspond

#### Étape 4.5: Exécuter le script de monitoring (RECOMMANDÉ)

```powershell
# Démarrer le monitoring automatique en arrière-plan
Start-Process powershell -ArgumentList "-NoExit", "-File", ".\scripts\monitor_qdrant_health_enhanced.ps1"
```

**Ce script surveillera:**
- État du container
- Utilisation CPU et mémoire
- Temps de réponse API
- Nombre de collections

**Durée:** Laisser tourner pendant au moins 30 minutes après la migration

---

## 📊 Validation Post-Migration

### Checklist de Validation Complète

```powershell
# Script de validation post-migration
$validationResults = @()

# 1. Container en cours d'exécution
$containerRunning = (docker ps --filter "name=qdrant_production" --format "{{.Names}}") -eq "qdrant_production"
$validationResults += [PSCustomObject]@{
    Check = "Container running"
    Status = if ($containerRunning) { "✅ PASS" } else { "❌ FAIL" }
}

# 2. Health endpoint
try {
    $health = Invoke-RestMethod -Uri "http://localhost:6333/healthz" -TimeoutSec 5
    $healthOK = $health.title -like "*OK*"
} catch {
    $healthOK = $false
}
$validationResults += [PSCustomObject]@{
    Check = "Health endpoint"
    Status = if ($healthOK) { "✅ PASS" } else { "❌ FAIL" }
}

# 3. Configuration chargée
$configLoaded = (docker logs qdrant_production 2>&1 | Select-String "production.yaml").Count -gt 0
$validationResults += [PSCustomObject]@{
    Check = "Config loaded"
    Status = if ($configLoaded) { "✅ PASS" } else { "⚠️ WARNING" }
}

# 4. Collections accessibles
try {
    $headers = @{"api-key" = "<YOUR_PRODUCTION_API_KEY>"}
    $collections = Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $headers -TimeoutSec 5
    $collectionsOK = $collections.result.collections.Count -gt 0
} catch {
    $collectionsOK = $false
}
$validationResults += [PSCustomObject]@{
    Check = "Collections accessible"
    Status = if ($collectionsOK) { "✅ PASS" } else { "❌ FAIL" }
}

# Afficher les résultats
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  RÉSULTATS DE VALIDATION POST-MIGRATION                   ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$validationResults | Format-Table -AutoSize

$failedChecks = ($validationResults | Where-Object {$_.Status -like "*FAIL*"}).Count
if ($failedChecks -eq 0) {
    Write-Host "`n✅ MIGRATION RÉUSSIE! Tous les tests sont passés.`n" -ForegroundColor Green
} else {
    Write-Host "`n❌ ÉCHEC DE VALIDATION! $failedChecks test(s) ont échoué.`n" -ForegroundColor Red
    Write-Host "⚠️  Consultez la section Rollback ci-dessous pour revenir en arrière.`n" -ForegroundColor Yellow
}
```

### Critères de Succès Finaux

La migration est considérée comme réussie si:

- ✅ **Container stable:** Reste actif pendant au moins 1 heure
- ✅ **Health check:** Répond correctement en continu
- ✅ **Collections:** Toutes accessibles et avec le bon nombre de points
- ✅ **Performance:** Temps de réponse API < 500ms pour les requêtes simples
- ✅ **Ressources:** Utilisation CPU < 50%, RAM < 12 GB
- ✅ **Logs:** Aucune erreur critique pendant les 30 premières minutes

---

## 🔄 Rollback - Procédure de Retour Arrière

### Quand effectuer un Rollback?

**Effectuez un rollback immédiatement si:**
- ❌ Le service ne démarre pas après 5 minutes
- ❌ Les collections ne sont plus accessibles
- ❌ Erreurs critiques dans les logs
- ❌ Utilisation mémoire > 15 GB
- ❌ Health check échoue en continu

### Méthode 1: Script Automatique (RECOMMANDÉ)

```powershell
# Exécuter le script de rollback
.\scripts\rollback_migration.ps1
```

**Ce script effectue automatiquement:**
1. Arrêt du container
2. Restauration de `production.yaml.pre-migration` → `production.yaml`
3. Redémarrage avec l'ancienne configuration
4. Validation du service

**Durée:** 3-5 minutes

### Méthode 2: Rollback Manuel

```powershell
# Étape 1: Arrêter le container
docker stop -t 60 qdrant_production

# Étape 2: Restaurer l'ancienne configuration
Copy-Item -Path "config/production.yaml.pre-migration" -Destination "config/production.yaml" -Force

# Étape 3: Redémarrer avec l'ancien docker-compose
docker compose -f docker-compose.production.yml up -d

# Étape 4: Vérifier le health
Start-Sleep -Seconds 40
curl http://localhost:6333/healthz

# Étape 5: Vérifier les logs
docker logs -f qdrant_production
```

### Validation Post-Rollback

```powershell
# Vérifier que tout fonctionne
$headers = @{"api-key" = "<YOUR_PRODUCTION_API_KEY>"}
$collections = Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $headers
Write-Host "Collections restaurées: $($collections.result.collections.Count)"
```

---

## 🔍 FAQ et Dépannage

### Q1: Le container ne démarre pas après la migration

**Symptômes:**
- Container en état "Restarting" ou "Exited"
- Logs montrent des erreurs de configuration

**Solution:**
```powershell
# Vérifier les logs détaillés
docker logs qdrant_production 2>&1 | Select-String -Pattern "ERROR|FATAL|panic"

# Si erreur de configuration, effectuer un rollback
.\scripts\rollback_migration.ps1
```

### Q2: Utilisation mémoire très élevée après migration

**Symptômes:**
- RAM > 15 GB utilisée
- Container devient lent ou non-responsive

**Solution:**
```powershell
# Vérifier l'utilisation actuelle
docker stats qdrant_production --no-stream

# Si > 15 GB, ajuster les limites dans docker-compose.production.optimized.yml
# Réduire: memmap_threshold_kb et indexing_threshold_kb dans production.optimized.yaml
```

### Q3: Collections manquantes après migration

**Symptômes:**
- Certaines collections ne sont plus visibles
- API retourne des erreurs 404

**⚠️ CRITIQUE:** Effectuer un rollback immédiatement!

```powershell
# Rollback immédiat
.\scripts\rollback_migration.ps1

# Comparer avec le backup
$backupFile = Get-ChildItem "backups/collections_list_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $backupFile | ConvertFrom-Json
```

### Q4: Performance dégradée après migration

**Symptômes:**
- Requêtes plus lentes qu'avant
- Temps de réponse > 1 seconde

**Diagnostic:**
```powershell
# Tester les temps de réponse
Measure-Command {
    $headers = @{"api-key" = "<YOUR_PRODUCTION_API_KEY>"}
    Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $headers
}

# Vérifier les métriques Qdrant
curl http://localhost:6333/metrics
```

**Solutions possibles:**
1. Augmenter `max_search_threads` si CPU < 50%
2. Réduire `flush_interval_sec` si beaucoup d'écritures
3. Ajuster `memmap_threshold_kb` si beaucoup de lectures

### Q5: Le health check échoue en continu

**Symptômes:**
- Container en état "unhealthy"
- Docker tente de redémarrer le container

**Solution:**
```powershell
# Vérifier l'état du health check
docker inspect qdrant_production --format='{{json .State.Health}}' | ConvertFrom-Json

# Augmenter le start_period si le service met plus de 40s à démarrer
# Modifier dans docker-compose.production.optimized.yml:
#   start_period: 60s  # Au lieu de 40s
```

---

## ⏱️ Timeline de Migration Complète

| Étape | Durée Estimée | Durée Réelle | Notes |
|-------|---------------|--------------|-------|
| Phase 1: Sauvegarde | 5-10 min | ______ | Dépend du nombre de collections |
| Phase 2: Arrêt service | 2-3 min | ______ | Attendre le flush complet |
| Phase 3: Config | 1 min | ______ | Simple copie de fichier |
| Phase 4: Démarrage | 5-10 min | ______ | Inclut validation initiale |
| Monitoring initial | 30-60 min | ______ | Surveillance continue recommandée |
| **TOTAL** | **43-84 min** | ______ | |

**Conseil:** Prévoir une fenêtre de 2 heures pour être confortable.

---

## 📚 Références et Ressources

### Scripts Créés pour cette Migration

1. **`scripts/backup_before_migration.ps1`**
   - Crée une sauvegarde complète avant migration
   - [Voir le fichier](scripts/backup_before_migration.ps1)

2. **`scripts/rollback_migration.ps1`**
   - Restaure la configuration précédente
   - [Voir le fichier](scripts/rollback_migration.ps1)

3. **`scripts/safe_restart_production.ps1`**
   - Redémarrage sécurisé avec validations
   - [Voir le fichier](scripts/safe_restart_production.ps1)

4. **`scripts/execute_migration.ps1`** *(À créer)*
   - Orchestration automatique complète de la migration
   - Mode interactif avec confirmations

### Fichiers de Configuration

1. **`config/production.yaml`** - Configuration actuelle (à remplacer)
2. **`config/production.optimized.yaml`** - Nouvelle configuration optimisée
3. **`docker-compose.production.yml`** - Docker Compose actuel (à conserver)
4. **`docker-compose.production.optimized.yml`** - Nouvelle version avec limites de ressources

### Changements de Configuration Détaillés

| Paramètre | Ancienne Valeur | Nouvelle Valeur | Impact |
|-----------|----------------|-----------------|--------|
| `flush_interval_sec` | 1 | 5 | ⬇️ Réduit I/O disque de ~80% |
| `wal_capacity_mb` | 128 | 512 | ⬆️ Buffer 4x plus grand |
| `max_workers` | 0 (auto=31) | 16 | ⬇️ Réduit CPU overhead |
| `max_search_threads` | 0 (auto=31) | 16 | ⬇️ Limite concurrence |
| `max_optimization_threads` | 0 (auto=31) | 8 | ⬇️ Balance indexation |
| `memmap_threshold_kb` | 200000 | 300000 | ⬆️ Plus de cache RAM |
| `indexing_threshold_kb` | 200000 | 300000 | ⬆️ Moins d'accès disque |
| `max_request_size_mb` | - | 32 | 🆕 Protection contre requêtes volumineuses |

### Docker Compose - Nouvelles Limites

| Ressource | Limite | Réservation | Impact |
|-----------|--------|-------------|--------|
| **Mémoire** | 16 GB | 4 GB | Évite OOM, garantit minimum |
| **CPU** | 16 cœurs | 4 cœurs | Évite saturation, garantit minimum |
| **Stop Grace** | 60s | - | Plus de temps pour flush |
| **Health Check** | 30s interval | - | Détection automatique des problèmes |

---

## 📞 Support et Contact

En cas de problème durant la migration:

1. **Consulter ce guide** - Sections FAQ et Dépannage
2. **Vérifier les logs** - `docker logs qdrant_production`
3. **Effectuer un rollback** - Si problème critique
4. **Documenter l'incident** - Pour analyse post-mortem

---

## ✅ Checklist de Préparation (Avant de Commencer)

Cochez avant de démarrer la migration:

- [ ] J'ai lu entièrement ce guide
- [ ] J'ai vérifié tous les prérequis
- [ ] J'ai au moins 30 minutes disponibles
- [ ] J'ai accès administrateur
- [ ] J'ai informé les utilisateurs (si applicable)
- [ ] J'ai une fenêtre de maintenance planifiée
- [ ] Les sauvegardes automatiques sont configurées
- [ ] J'ai testé les commandes de validation
- [ ] Je sais comment effectuer un rollback
- [ ] J'ai le contact du support en cas de problème

---

## 📈 Résultats Attendus Après Migration

Après une migration réussie, vous devriez observer:

✅ **Stabilité améliorée:**
- Container reste actif pendant des jours/semaines
- Plus de redémarrages quotidiens

✅ **Performance optimisée:**
- Temps de réponse API cohérents
- Utilisation CPU plus stable (~30-40%)

✅ **Utilisation mémoire contrôlée:**
- RAM utilisée: 8-12 GB (au lieu de pics à 20+ GB)
- Pas de swap utilisé

✅ **I/O disque réduit:**
- Moins d'écritures fréquentes
- Lectures optimisées via cache RAM

---

**Bonne migration! 🚀**

*Document créé le: 2025-10-07*  
*Dernière mise à jour: 2025-10-07*  
*Version: 1.0*