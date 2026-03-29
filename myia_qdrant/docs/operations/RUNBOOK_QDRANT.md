# 🔧 Runbook Opérationnel Qdrant

**Date**: 2025-10-15  
**Version**: 1.0  
**Responsable**: Infrastructure Team

## 📋 Table des Matières

1. [Vue d'Ensemble](#vue-densemble)
2. [Configuration Actuelle](#configuration-actuelle)
3. [Procédures Standard](#procédures-standard)
4. [Diagnostic Rapide](#diagnostic-rapide)
5. [Résolution Problèmes Courants](#résolution-problèmes-courants)
6. [Escalade](#escalade)
7. [FAQ Troubleshooting](#faq-troubleshooting)

---

## 🎯 Vue d'Ensemble

### Infrastructure

- **Container**: `qdrant_production`
- **Compose**: `docker-compose.production.yml`
- **Configuration**: `config/production.optimized.yaml`
- **Version**: Qdrant latest
- **Données**: 3.2M vecteurs, 59 collections

### Limites Ressources

| Ressource | Réservation | Limite Max |
|-----------|-------------|------------|
| **RAM** | 4 GB | 12 GB |
| **CPU** | 2 cœurs | 8 cœurs |

### Threads Configuration

| Type | Threads | Justification |
|------|---------|---------------|
| API Workers | 8 | Aligné sur 8 CPU limit |
| Search | 8 | Évite over-subscription |
| Optimization | 4 | Réduit charge background |
| HNSW Indexing | 8 | Balance perf/stabilité |
| **TOTAL MAX** | **28** | Évite contention CPU |

### Monitoring

- **Healthcheck Docker**: Automatique (30s interval, 10s timeout)
- **Script Monitoring**: `scripts/monitoring/continuous_health_check.ps1`
- **Logs**: `logs/monitoring/health_check_*.log`

---

## ⚙️ Configuration Actuelle

### Docker Compose

```yaml
# docker-compose.production.yml
services:
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant_production
    restart: always
    stop_grace_period: 60s
    
    environment:
      - QDRANT__SERVICE__MAX_REQUEST_SIZE_MB=32
      - QDRANT__SERVICE__GRPC_TIMEOUT_MS=60000
      - QDRANT__LOG_LEVEL=INFO
      - QDRANT__TELEMETRY_DISABLED=true
    
    deploy:
      resources:
        limits:
          memory: 12G
          cpus: '8'
        reservations:
          memory: 4G
          cpus: '2'
    
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:6333/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### Configuration Qdrant

**Fichier**: `config/production.optimized.yaml`

**Paramètres Clés**:
- WAL: 384 MB
- Flush interval: 5s
- Max segment size: 512 MB
- Memmap threshold: 250 MB
- HNSW on disk: true
- GRPC timeout: 60s

---

## 📝 Procédures Standard

### 1️⃣ Démarrage Container

```powershell
# Démarrer le container
cd myia_qdrant
docker compose -f docker-compose.production.yml up -d

# Vérifier démarrage
docker ps | Select-String "qdrant_production"

# Attendre healthcheck (40s)
Start-Sleep -Seconds 40

# Vérifier santé
docker ps | Select-String "healthy"
```

**Temps attendu**: 40-60 secondes jusqu'à "healthy"

### 2️⃣ Arrêt Container

```powershell
# Arrêt gracieux (60s grace period)
cd myia_qdrant
docker compose -f docker-compose.production.yml down

# Vérifier arrêt
docker ps | Select-String "qdrant_production"
# Doit retourner rien
```

**Important**: Toujours utiliser `docker compose down` pour arrêt gracieux (flush des données).

### 3️⃣ Redémarrage Container

```powershell
# Méthode recommandée: Arrêt + Démarrage
cd myia_qdrant
docker compose -f docker-compose.production.yml down
Start-Sleep -Seconds 5
docker compose -f docker-compose.production.yml up -d

# Alternative: Restart Docker
docker restart qdrant_production
```

**Note**: Préférer `down`/`up` pour redémarrage complet avec nouvelle config.

### 4️⃣ Vérification Santé

```powershell
# Vérifier status Docker
docker ps --filter "name=qdrant_production"
# Doit afficher: "Up X minutes (healthy)"

# Tester API REST
curl http://localhost:6333/healthz
# Doit retourner: {"title":"healthz","version":"..."}

# Vérifier collections
curl http://localhost:6333/collections
# Doit lister 59 collections

# Statistiques ressources
docker stats qdrant_production --no-stream
```

### 5️⃣ Consultation Logs

```powershell
# Logs temps réel (suivre)
docker logs -f qdrant_production

# Dernières 100 lignes
docker logs qdrant_production --tail 100

# Logs depuis X minutes
$Since = (Get-Date).AddMinutes(-15).ToString("yyyy-MM-ddTHH:mm:ss")
docker logs qdrant_production --since $Since

# Filtrer par pattern
docker logs qdrant_production 2>&1 | Select-String "error|panic|timeout"

# Sauvegarder logs
docker logs qdrant_production > "logs/qdrant_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" 2>&1
```

### 6️⃣ Monitoring Continu

```powershell
# Lancer monitoring automatique avec auto-restart
cd myia_qdrant
pwsh -c ".\scripts\monitoring\continuous_health_check.ps1"

# Mode monitoring seul (sans auto-restart)
pwsh -c ".\scripts\monitoring\continuous_health_check.ps1 -AutoRestart `$false"

# Paramètres personnalisés
pwsh -c ".\scripts\monitoring\continuous_health_check.ps1 -CheckInterval 60 -HealthTimeout 15"
```

**Recommandation**: Lancer en tâche de fond ou service Windows.

### 7️⃣ Test de Charge

```powershell
# Test standard
cd myia_qdrant
pwsh -c ".\scripts\diagnostics\stress_test_qdrant.ps1"

# Test léger (développement)
pwsh -c ".\scripts\diagnostics\stress_test_qdrant.ps1 -StartLoad 5 -MaxLoad 50 -LoadStep 10"

# Test intensif (validation prod)
pwsh -c ".\scripts\diagnostics\stress_test_qdrant.ps1 -StartLoad 20 -MaxLoad 300 -LoadStep 30"
```

**Résultats**: Rapports générés dans `diagnostics/stress_test_*.{json,md}`

---

## 🔍 Diagnostic Rapide

### Checklist 5 Minutes

Exécuter cette séquence pour diagnostic rapide:

```powershell
Write-Host "=== DIAGNOSTIC QDRANT ===" -ForegroundColor Cyan

# 1. Container running?
Write-Host "`n1. Status Container:" -ForegroundColor Yellow
docker ps --filter "name=qdrant_production" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 2. Healthcheck OK?
Write-Host "`n2. Healthcheck:" -ForegroundColor Yellow
$Health = docker inspect qdrant_production --format='{{.State.Health.Status}}' 2>$null
Write-Host "  Status: $Health" -ForegroundColor $(if ($Health -eq "healthy") { "Green" } else { "Red" })

# 3. API accessible?
Write-Host "`n3. API REST:" -ForegroundColor Yellow
try {
    $Response = Invoke-WebRequest -Uri "http://localhost:6333/healthz" -TimeoutSec 5 -UseBasicParsing
    Write-Host "  OK (HTTP $($Response.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host "  ERREUR: $($_.Exception.Message)" -ForegroundColor Red
}

# 4. Ressources CPU/RAM
Write-Host "`n4. Ressources:" -ForegroundColor Yellow
docker stats qdrant_production --no-stream --format "  CPU: {{.CPUPerc}} | RAM: {{.MemUsage}} ({{.MemPerc}})"

# 5. Logs récents (erreurs)
Write-Host "`n5. Erreurs Récentes:" -ForegroundColor Yellow
$Errors = docker logs qdrant_production --tail 50 2>&1 | Select-String -Pattern "error|panic|fatal|timeout" | Select-Object -First 5
if ($Errors) {
    $Errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
} else {
    Write-Host "  Aucune erreur détectée" -ForegroundColor Green
}

Write-Host "`n=== FIN DIAGNOSTIC ===" -ForegroundColor Cyan
```

### Seuils d'Alerte

| Métrique | OK | Attention | Critique |
|----------|-----|-----------|----------|
| **CPU** | <60% | 60-80% | >80% |
| **RAM** | <60% | 60-80% | >80% |
| **Temps réponse API** | <500ms | 500ms-2s | >2s |
| **Healthcheck** | healthy | starting | unhealthy |
| **Logs errors/min** | <5 | 5-20 | >20 |

---

## 🚨 Résolution Problèmes Courants

### Problème 1: Container "unhealthy"

**Symptômes**:
- Docker status: "unhealthy"
- API ne répond pas ou timeout

**Diagnostic**:
```powershell
# Vérifier logs
docker logs qdrant_production --tail 100

# Vérifier ressources
docker stats qdrant_production --no-stream

# Tester API manuellement
curl http://localhost:6333/healthz -v
```

**Solutions**:

1. **Si CPU/RAM >90%**: Freeze probable
   ```powershell
   # Redémarrage immédiat
   docker restart qdrant_production
   ```

2. **Si logs montrent erreurs I/O**: Problème disque
   ```powershell
   # Vérifier espace disque WSL
   wsl df -h /home/jesse/qdrant_data
   
   # Si <10% libre: nettoyer snapshots
   docker exec qdrant_production ls /qdrant/snapshots
   docker exec qdrant_production rm /qdrant/snapshots/old_*.snapshot
   ```

3. **Si timeout réseau**: Vérifier ports
   ```powershell
   # Vérifier ports écoutés
   netstat -an | Select-String "6333|6334"
   
   # Si rien: container network issue
   docker compose -f docker-compose.production.yml down
   docker compose -f docker-compose.production.yml up -d
   ```

### Problème 2: Container freeze (ne répond plus)

**Symptômes**:
- Healthcheck timeout
- API bloquée >10s
- CPU 100% ou 0%

**Diagnostic**:
```powershell
# Capture état avant restart
docker top qdrant_production
docker stats qdrant_production --no-stream
docker logs qdrant_production --tail 200 > "logs/freeze_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" 2>&1
```

**Solutions**:

1. **Redémarrage immédiat**:
   ```powershell
   docker restart qdrant_production
   ```

2. **Si redémarrage échoue**:
   ```powershell
   # Force kill + restart
   docker kill qdrant_production
   docker compose -f docker-compose.production.yml up -d
   ```

3. **Si problème récurrent**:
   - Vérifier `stress_test_qdrant.ps1` pour identifier limites
   - Réduire `max_workers` dans `production.optimized.yaml`
   - Contacter équipe infrastructure

### Problème 3: Performance dégradée

**Symptômes**:
- Temps réponse API >2s
- Débit <10 req/s
- CPU constant >80%

**Diagnostic**:
```powershell
# Test performance
pwsh -c ".\scripts\diagnostics\stress_test_qdrant.ps1 -StartLoad 10 -MaxLoad 50 -LoadStep 10"

# Analyser rapport
cat diagnostics/stress_test_*.md
```

**Solutions**:

1. **Si RAM >80%**: Réduire cache
   ```yaml
   # Dans production.optimized.yaml
   storage:
     optimizers:
       memmap_threshold_kb: 200000  # Réduit de 250000
   ```

2. **Si CPU >80%**: Réduire threads
   ```yaml
   # Dans production.optimized.yaml
   service:
     max_workers: 6  # Réduit de 8
   storage:
     performance:
       max_search_threads: 6  # Réduit de 8
   ```

3. **Si I/O saturé**: Optimiser WAL
   ```yaml
   # Dans production.optimized.yaml
   storage:
     wal:
       wal_capacity_mb: 256  # Réduit de 384
     optimizers:
       flush_interval_sec: 10  # Augmenté de 5
   ```

### Problème 4: Redémarrages fréquents (>3/heure)

**Symptômes**:
- Monitoring détecte >3 restarts/heure
- Logs montrent cycles restart

**Diagnostic**:
```powershell
# Vérifier logs monitoring
cat logs/monitoring/health_check_*.log | Select-String "Redémarrage"

# Analyser pattern
docker events --filter "container=qdrant_production" --since 1h
```

**Solutions**:

1. **Over-subscription CPU**: Cause la plus fréquente
   - Vérifier config threads (total doit être ≤28)
   - Réduire `max_workers` et `max_search_threads`

2. **OOM (Out Of Memory)**:
   ```powershell
   # Vérifier dmesg Linux (dans WSL)
   wsl dmesg | grep -i "oom\|killed"
   
   # Si OOM détecté:
   # - Réduire Docker limit memory: 12G → 10G
   # - Réduire memmap_threshold_kb: 250000 → 200000
   ```

3. **Problème configuration**:
   - Vérifier syntaxe YAML: `docker compose config`
   - Revenir config précédente si nécessaire

### Problème 5: Données corrompues/perdues

**Symptômes**:
- Collections manquantes
- Erreurs "collection not found"
- Vecteurs count incorrect

**Diagnostic**:
```powershell
# Lister collections
curl http://localhost:6333/collections | ConvertFrom-Json | Select-Object -ExpandProperty result

# Vérifier snapshots
docker exec qdrant_production ls -lh /qdrant/snapshots
```

**Solutions**:

1. **Restaurer depuis snapshot**:
   ```powershell
   # Arrêter container
   docker compose -f docker-compose.production.yml down
   
   # Restaurer snapshot (dans WSL)
   wsl -e bash -c "cd /home/jesse/qdrant_data && ./restore_snapshot.sh"
   
   # Redémarrer
   docker compose -f docker-compose.production.yml up -d
   ```

2. **Si pas de snapshot**: Réindexation nécessaire
   - Contacter équipe data pour réindexation
   - Prévoir downtime

---

## 📞 Escalade

### Niveau 1: Auto-Healing (Automatique)

- **Système**: Healthcheck Docker + Monitoring script
- **Action**: Redémarrage automatique si unhealthy
- **Limite**: Max 3 restarts/heure

### Niveau 2: Intervention Ops (Manuel)

**Quand escalader**:
- Redémarrages >3/heure
- Dégradation performance persistante
- Erreurs logs critiques (panic, fatal)

**Actions**:
1. Exécuter diagnostic complet
2. Capturer logs/stats
3. Appliquer solutions runbook
4. Documenter incident

### Niveau 3: Équipe Infrastructure (Escalade)

**Quand escalader**:
- Solutions runbook inefficaces
- Problème récurrent >24h
- Suspicion bug Qdrant
- Besoin modification architecture

**Contact**:
- Email: infra-team@company.com
- Slack: #infrastructure-critical
- Téléphone: +XX XXX XXX XXX (urgence)

**Informations à fournir**:
- Logs complets: `docker logs qdrant_production > incident.log`
- Stats ressources: `docker stats --no-stream`
- Configuration actuelle: `docker compose config`
- Rapport test charge si disponible
- Timeline détaillée de l'incident

---

## ❓ FAQ Troubleshooting

### Q1: Comment savoir si Qdrant est surchargé?

**R**: Vérifier ces indicateurs:
```powershell
docker stats qdrant_production --no-stream
```
- CPU >80% = Surchargé
- RAM >80% = Risque OOM
- Temps réponse API >2s = Saturé

**Solution**: Exécuter `stress_test_qdrant.ps1` pour identifier seuils.

### Q2: Quelle est la charge maximale recommandée?

**R**: Dépend du test de charge. Généralement:
- **Optimal**: <50 requêtes parallèles (<1s réponse)
- **Acceptable**: 50-100 requêtes parallèles (1-2s réponse)
- **Limite**: >100 requêtes parallèles (>2s réponse)

Exécuter `stress_test_qdrant.ps1` pour déterminer vos limites exactes.

### Q3: Comment activer le monitoring automatique permanent?

**R**: Créer tâche planifiée Windows:
```powershell
# Créer script wrapper
$ScriptPath = "C:\path\to\myia_qdrant\scripts\monitoring\continuous_health_check.ps1"
$Action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-File `"$ScriptPath`""
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Register-ScheduledTask -TaskName "QdrantMonitoring" -Action $Action -Trigger $Trigger -Principal $Principal
```

### Q4: Où sont les logs de monitoring?

**R**: `myia_qdrant/logs/monitoring/`
- `health_check_*.log`: Logs monitoring continu
- `freeze_*.log`: Logs capturés au moment des freeze

### Q5: Comment vérifier si configuration est appliquée?

**R**:
```powershell
# Vérifier config chargée
docker exec qdrant_production cat /qdrant/config/production.yaml

# Vérifier variables environnement
docker exec qdrant_production env | Select-String "QDRANT"

# Comparer avec config locale
cat config/production.optimized.yaml
```

### Q6: Que faire si healthcheck toujours "starting"?

**R**: Container n'arrive pas à démarrer correctement.
```powershell
# Vérifier logs démarrage
docker logs qdrant_production

# Causes fréquentes:
# 1. Config YAML invalide
docker compose config  # Doit retourner sans erreur

# 2. Permissions volumes
wsl ls -la /home/jesse/qdrant_data/storage

# 3. Port déjà utilisé
netstat -an | Select-String "6333|6334"
```

### Q7: Comment réduire l'utilisation RAM?

**R**: Ajuster paramètres dans `production.optimized.yaml`:
```yaml
storage:
  optimizers:
    memmap_threshold_kb: 200000  # Réduit cache (était 250000)
    indexing_threshold_kb: 200000
  hnsw_index:
    on_disk: true  # IMPORTANT: Garder true
```

Puis redémarrer:
```powershell
docker compose -f docker-compose.production.yml down
docker compose -f docker-compose.production.yml up -d
```

### Q8: Différence entre restart et down/up?

**R**:
- `docker restart`: Redémarre container sans recharger config
- `docker compose down/up`: Redémarre + recharge config complète

**Recommandation**: Toujours utiliser `down`/`up` après modification config.

---

## 📚 Références

- **Documentation Qdrant**: https://qdrant.tech/documentation/
- **Optimisation HNSW**: https://qdrant.tech/articles/indexing-optimization/
- **Performance Tuning**: https://qdrant.tech/documentation/guides/configuration/
- **Monitoring**: https://qdrant.tech/documentation/guides/monitoring/

---

**Dernière mise à jour**: 2025-10-15  
**Version**: 1.0  
**Prochain audit**: 2025-11-15