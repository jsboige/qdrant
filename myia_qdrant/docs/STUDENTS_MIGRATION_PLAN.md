# Plan de Migration Qdrant Students - Version Optimisée

**Date:** 2025-10-08  
**Auteur:** Debug Mode Analysis  
**Statut:** ✅ PRÊT POUR EXÉCUTION (après correction healthcheck)

---

## 🎯 RÉSUMÉ EXÉCUTIF

### État Actuel Students
- **Container:** qdrant_students (UNHEALTHY mais fonctionnel)
- **Collections:** 197 actives
- **Ressources:** 8.30% CPU, 9.6 GB RAM
- **Problème identifié:** Healthcheck utilise `curl` qui n'existe pas dans l'image Docker

### État Actuel Production
- **Container:** qdrant_production (UNHEALTHY mais fonctionnel)
- **FailingStreak:** 73 échecs
- **Problème:** IDENTIQUE à students (curl manquant)

### Découverte Critique 🔴
Les DEUX environnements (students + production) sont marqués UNHEALTHY à cause d'un bug de configuration:
- Le healthcheck tente d'exécuter `curl` 
- `curl` n'est pas installé dans l'image `qdrant/qdrant:latest`
- Les services fonctionnent parfaitement malgré ce statut

---

## 📋 CHECKLIST FINALE PRÉ-MIGRATION

### ✅ Analyse Complétée
- [x] Fichiers de configuration analysés
- [x] État container vérifié
- [x] Métriques collectées
- [x] Collections inventoriées (197)
- [x] Bug healthcheck identifié et diagnostiqué
- [x] Production vérifiée (même bug confirmé)
- [x] Comparaison students/production effectuée
- [x] Plan d'adaptation préparé

### 🔧 Actions Requises AVANT Migration
1. **CRITIQUE:** Corriger le healthcheck dans les DEUX environnements
2. Créer les fichiers optimisés (config + docker-compose)
3. Préparer les scripts de migration
4. Créer backup complet

### 📊 Optimisations Prévues
```yaml
# Configuration Qdrant
flush_interval_sec: 1 -> 5 (réduit I/O de ~80%)
wal_capacity_mb: 128 -> 512 (4x buffer)
max_workers: auto(31) -> 16 (limite CPU)
max_search_threads: auto -> 16 (limite concurrence)
max_optimization_threads: auto -> 8 (balance perf)
memmap_threshold_kb: 200000 -> 300000 (+50% RAM cache)
indexing_threshold_kb: 200000 -> 300000 (moins disque)
max_request_size_mb: NOUVEAU -> 32 (protection)

# Docker Compose
stop_grace_period: 30s -> 60s (arrêt gracieux)
resource_limits: AUCUNE -> 12G RAM / 12 CPU (protection)
healthcheck: curl -> wget (CORRECTION BUG)
retries: 3 -> 5 (tolérance)
start_period: 40s -> 60s (temps démarrage)
```

---

## 🔴 CORRECTION HEALTHCHECK URGENTE

### Problème Actuel
```yaml
# NE FONCTIONNE PAS - curl n'existe pas dans l'image
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:6333/healthz"]
```

### Solution Recommandée
```yaml
# FONCTIONNE - wget est présent dans l'image
healthcheck:
  test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:6333/healthz"]
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 60s
```

### Alternatives
```yaml
# Option 2: Test de port uniquement (moins précis)
test: ["CMD", "nc", "-z", "localhost", "6333"]

# Option 3: Désactivation temporaire (migration urgente)
disable: true
```

---

## 📁 FICHIERS À CRÉER

### 1. Config Optimisée
**Fichier:** `config/students.optimized.yaml`
**Basé sur:** `config/production.yaml` (optimisé)
**Adaptations:** Identique, juste pour students

### 2. Docker Compose Optimisé
**Fichier:** `docker-compose.students.optimized.yml`
**Changements clés:**
- Healthcheck corrigé (wget au lieu de curl)
- Resource limits: 12G RAM / 12 CPU
- Stop grace period: 60s
- Retries: 5, start_period: 60s

### 3. Scripts Migration
- `scripts/backup_students_before_migration.ps1`
- `scripts/execute_students_migration.ps1`
- `scripts/rollback_students_migration.ps1`

---

## 🚀 ORDRE D'EXÉCUTION

### Phase 1: Correction Healthcheck (URGENT)
```powershell
# 1. Corriger docker-compose.students.yml (remplacer curl par wget)
# 2. Redémarrer: docker compose -f docker-compose.students.yml up -d
# 3. Vérifier: docker ps (devrait passer HEALTHY après 60s)
```

### Phase 2: Backup
```powershell
# 1. Backup configuration
Copy-Item config/students.yaml config/students.yaml.pre-migration

# 2. Backup via Docker
docker exec qdrant_students tar czf /qdrant/snapshots/backup-pre-migration.tar.gz /qdrant/storage

# 3. Snapshot API
curl -X POST http://localhost:6335/snapshots
```

### Phase 3: Migration Optimisations
```powershell
# 1. Copier fichiers optimisés
Copy-Item config/students.optimized.yaml config/students.yaml
Copy-Item docker-compose.students.optimized.yml docker-compose.students.yml

# 2. Arrêt gracieux (60s)
docker stop -t 60 qdrant_students

# 3. Redémarrage avec nouvelle config
docker compose -f docker-compose.students.yml up -d

# 4. Vérification
curl http://localhost:6335/healthz
docker ps | Select-String student
docker stats qdrant_students --no-stream
```

### Phase 4: Monitoring
```powershell
# Surveiller pendant 24-48h
.\myia_qdrant\monitor_qdrant_health.ps1 -Port 6335
```

---

## 🎯 IMPACT ATTENDU

### Performance
- ⬆️ -80% I/O disque (flush moins fréquent)
- ⬆️ +400% WAL buffer (moins de contention)
- ⬆️ CPU usage stable (threads limités)
- ⬆️ +50% cache RAM (thresholds augmentés)

### Stabilité
- ✅ Container status: HEALTHY (bug corrigé)
- ✅ Arrêt gracieux garanti (60s)
- ✅ Protection ressources (limites)
- ✅ Moins de variations erratiques

### Monitoring
- ✅ Healthcheck fiable (wget)
- ✅ Métriques stables
- ✅ Pas de redémarrages intempestifs

---

## 🔒 ROLLBACK PLAN

### Si Problème Après Migration
```powershell
# 1. Arrêt
docker stop -t 60 qdrant_students

# 2. Restaurer config
Copy-Item config/students.yaml.pre-migration config/students.yaml

# 3. Restaurer docker-compose (version sauvegardée)
Copy-Item docker-compose.students.yml.backup docker-compose.students.yml

# 4. Redémarrer
docker compose -f docker-compose.students.yml up -d

# 5. Vérifier
curl http://localhost:6335/healthz
docker ps | Select-String student
```

---

## 📊 MÉTRIQUES DE RÉFÉRENCE (AVANT MIGRATION)

```yaml
Date: 2025-10-08 20:05
Container: qdrant_students
Status: UNHEALTHY (bug healthcheck)
Uptime: 2 days
Collections: 197
CPU: 8.30%
RAM: 9.628 GB / 125.8 GB (7.65%)
PIDs: 364
FailingStreak: 6934 (depuis 9 jours)
API Health: ✅ PASS (service fonctionnel)
```

---

## ⚠️ NOTES IMPORTANTES

### Différences Students vs Production
**À PRÉSERVER:**
- Ports: 6335/6336 (students) vs 6333/6334 (prod)
- Container name: qdrant_students
- Network: qdrant-students-network
- Volumes: qdrant-students-storage/snapshots
- Config: students.yaml
- Env file: .env.students

**Resource Limits (adaptés):**
- Students: 12G RAM / 12 CPU (plus petit que prod)
- Production: 16G RAM / 16 CPU
- Rationale: Students a moins de collections et charge

### Spécificités Students
- Utilise Docker volumes locaux (pas WSL bind mounts)
- Environnement plus petit mais tout aussi critique
- Même niveau de disponibilité requis
- Configuration isolée de production

---

## ✅ VALIDATION POST-MIGRATION

### Checklist Santé
- [ ] Container status: HEALTHY (pas UNHEALTHY)
- [ ] API répond: `curl http://localhost:6335/healthz`
- [ ] Collections accessibles: 197 collections présentes
- [ ] CPU usage: stable ~8-10%
- [ ] RAM usage: <12G (respecte limite)
- [ ] Healthcheck: aucun échec dans logs
- [ ] Pas de restart intempestif

### Monitoring 24-48h
- [ ] Métriques stables
- [ ] Pas de dégradation performance
- [ ] Logs sans erreur
- [ ] Pas de crash/restart
- [ ] Utilisateurs students: aucun impact

---

## 🆘 CONTACTS SUPPORT

En cas de problème pendant la migration:
1. Consulter `STUDENTS_ANALYSIS_20251008.md` (diagnostic complet)
2. Exécuter rollback plan (ci-dessus)
3. Vérifier logs: `docker logs qdrant_students --tail 100`
4. Contacter équipe infrastructure

---

**Document préparé en mode DEBUG - Analyse LECTURE SEULE complétée**  
**Aucune modification n'a été apportée aux systèmes**  
**Migration prête après création des fichiers optimisés**