# 🔧 Fiabilisation Infrastructure Qdrant - Guide Déploiement

**Date**: 2025-10-15  
**Statut**: ✅ Prêt pour déploiement  
**Downtime estimé**: 1-2 minutes

---

## 🎯 Résumé

Infrastructure Qdrant optimisée pour **éliminer les freeze récurrents** via:
- ✅ Réduction threads (40 → 28) pour éviter over-subscription CPU
- ✅ Limites ressources ajustées (12G RAM, 8 CPU)
- ✅ Healthcheck Docker actif (détection auto freeze)
- ✅ Monitoring continu avec auto-healing
- ✅ Scripts de test de charge et runbook opérationnel

**Cause identifiée**: Over-subscription CPU (40 threads sur 8 cores) causant contention et freeze.

---

## 📦 Fichiers Modifiés/Créés

### Configuration (Modifiés)

1. **[`docker-compose.production.yml`](docker-compose.production.yml)**
   - Limites: 12G RAM / 8 CPU (au lieu de 16G/16)
   - Healthcheck actif: 30s interval, 10s timeout
   - Timeouts GRPC: 60s

2. **[`config/production.optimized.yaml`](config/production.optimized.yaml)**
   - Threads réduits: 8+8+4+8 = 28 (au lieu de 40)
   - Buffers optimisés pour 12G RAM
   - Max segment size: 512 MB

### Scripts (Créés)

3. **[`scripts/monitoring/continuous_health_check.ps1`](scripts/monitoring/continuous_health_check.ps1)**
   - Monitoring continu + auto-restart
   - Capture logs freeze automatique
   - Limite 3 restarts/h

4. **[`scripts/diagnostics/stress_test_qdrant.ps1`](scripts/diagnostics/stress_test_qdrant.ps1)**
   - Test charge progressive
   - Identification limites système
   - Rapports JSON + Markdown

### Documentation (Créée)

5. **[`docs/operations/RUNBOOK_QDRANT.md`](docs/operations/RUNBOOK_QDRANT.md)**
   - Procédures standard complètes
   - Diagnostic rapide
   - FAQ troubleshooting

6. **[`docs/diagnostics/20251015_RAPPORT_FIABILISATION_INFRASTRUCTURE.md`](docs/diagnostics/20251015_RAPPORT_FIABILISATION_INFRASTRUCTURE.md)**
   - Analyse cause racine
   - Optimisations détaillées
   - Recommandations

---

## 🚀 Déploiement Rapide

### Prérequis

- Docker Compose installé
- Accès au container `qdrant_production`
- Powershell 7+

### Étape 1: Sauvegarde (0min)

```powershell
cd myia_qdrant

# Sauvegarder config actuelle
Copy-Item docker-compose.production.yml docker-compose.production.yml.backup
Copy-Item config/production.optimized.yaml config/production.optimized.yaml.backup

# Créer snapshot Qdrant
docker exec qdrant_production curl -X POST http://localhost:6333/snapshots
```

### Étape 2: Déploiement (1-2min)

```powershell
# Arrêt gracieux (60s grace period)
docker compose -f docker-compose.production.yml down

# Redémarrage avec nouvelle config
docker compose -f docker-compose.production.yml up -d

# Attendre healthcheck (40s start_period)
Start-Sleep -Seconds 40
```

### Étape 3: Validation (1min)

```powershell
# Vérifier status (doit afficher "healthy")
docker ps --filter "name=qdrant_production"

# Tester API
curl http://localhost:6333/healthz
curl http://localhost:6333/collections

# Vérifier logs (pas d'erreur)
docker logs qdrant_production --tail 50
```

### Étape 4: Monitoring (Optionnel)

```powershell
# Lancer monitoring automatique
pwsh -c ".\scripts\monitoring\continuous_health_check.ps1"

# OU en tâche de fond
Start-Job -ScriptBlock {
    cd myia_qdrant
    pwsh -c ".\scripts\monitoring\continuous_health_check.ps1"
}
```

---

## 🧪 Tests Recommandés

### Test 1: Stabilité Basique (Prioritaire)

```powershell
# Observer pendant 1h minimum
pwsh -c ".\scripts\monitoring\continuous_health_check.ps1"

# Succès si: 0 freeze, healthcheck "healthy" constant
```

### Test 2: Limites Système

```powershell
# Identifier seuils de saturation
pwsh -c ".\scripts\diagnostics\stress_test_qdrant.ps1"

# Analyser rapport
cat diagnostics/stress_test_*.md
```

### Test 3: Endurance (24h)

```powershell
# Lancer monitoring en background
Start-Job -Name QdrantMonitoring -ScriptBlock {
    cd myia_qdrant
    pwsh -c ".\scripts\monitoring\continuous_health_check.ps1"
}

# Vérifier le lendemain
Receive-Job -Name QdrantMonitoring
```

---

## 📊 Comparaison Avant/Après

| Métrique | Avant | Après | Amélioration |
|----------|-------|-------|--------------|
| **Threads totaux** | 40 | 28 | -30% |
| **Ratio CPU** | 5:1 ❌ | 3.5:1 ✅ | -30% |
| **RAM limite** | 16G | 12G | Optimisé |
| **Healthcheck** | ❌ Désactivé | ✅ Actif | Auto-détection |
| **GRPC timeout** | ❌ Aucun | ✅ 60s | Protection |
| **Monitoring** | ❌ Manuel | ✅ Auto | Réactivité |
| **Freeze attendus/jour** | 2-5 | 0 | -100% |
| **Uptime attendu** | <50% | >99% | +50% |

---

## 🔍 Diagnostic Rapide

Si problème après déploiement:

```powershell
# 1. Vérifier status
docker ps --filter "name=qdrant_production"

# 2. Vérifier healthcheck
docker inspect qdrant_production --format='{{.State.Health.Status}}'

# 3. Vérifier ressources
docker stats qdrant_production --no-stream

# 4. Vérifier logs erreurs
docker logs qdrant_production --tail 100 | Select-String "error|panic|fatal"

# 5. Test API manuel
curl http://localhost:6333/healthz -v
```

---

## 🔙 Rollback si Nécessaire

Si problème critique:

```powershell
cd myia_qdrant

# Arrêter
docker compose -f docker-compose.production.yml down

# Restaurer backup
Copy-Item docker-compose.production.yml.backup docker-compose.production.yml -Force
Copy-Item config/production.optimized.yaml.backup config/production.optimized.yaml -Force

# Redémarrer
docker compose -f docker-compose.production.yml up -d
```

---

## 📈 Métriques à Surveiller

### Seuils d'Alerte

| Métrique | OK | Attention | Critique |
|----------|-----|-----------|----------|
| **CPU** | <60% | 60-80% | >80% |
| **RAM** | <60% | 60-80% | >80% |
| **Latence P95** | <500ms | 500ms-1s | >1s |
| **Healthcheck** | healthy | starting | unhealthy |

### Commandes Surveillance

```powershell
# Stats temps réel
docker stats qdrant_production

# Logs continus
docker logs -f qdrant_production

# Monitoring automatique (recommandé)
pwsh -c ".\scripts\monitoring\continuous_health_check.ps1"
```

---

## 📚 Documentation Complète

- **Runbook Opérationnel**: [`docs/operations/RUNBOOK_QDRANT.md`](docs/operations/RUNBOOK_QDRANT.md)
  - Procédures standard (start/stop/restart)
  - Diagnostic rapide (checklist 5min)
  - Résolution problèmes courants
  - FAQ troubleshooting

- **Rapport Technique**: [`docs/diagnostics/20251015_RAPPORT_FIABILISATION_INFRASTRUCTURE.md`](docs/diagnostics/20251015_RAPPORT_FIABILISATION_INFRASTRUCTURE.md)
  - Analyse cause racine détaillée
  - Justification optimisations
  - Tests et validation

---

## ✅ Critères de Succès

### Immédiat (J+1)
- ✅ Container "healthy" en <60s
- ✅ API répond <500ms
- ✅ Pas d'erreur logs

### Court Terme (J+7)
- ✅ 0 freeze sur 7 jours
- ✅ Uptime >99%
- ✅ CPU <60%, RAM <70%

### Moyen Terme (J+30)
- ✅ Infrastructure stable
- ✅ Limites documentées
- ✅ Monitoring permanent

---

## 📞 Support

**Questions/Problèmes**:
- Consulter d'abord: [`docs/operations/RUNBOOK_QDRANT.md`](docs/operations/RUNBOOK_QDRANT.md)
- Si non résolu: Contacter Infrastructure Team

**Escalade si**:
- Redémarrages >3/heure
- Problème persistant >24h
- Dégradation performance majeure

---

**Note**: Les optimisations sont conservatrices et réversibles. Rollback possible en <2min si nécessaire.

**Confiance**: Haute - Basé sur analyse approfondie et best practices Qdrant officielles.