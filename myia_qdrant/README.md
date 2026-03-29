# MyIA Qdrant - Gestion Centralisée

## Vue d'ensemble

Ce répertoire contient tous les outils et la documentation pour la gestion des instances Qdrant du projet MyIA.

**Dernière mise à jour**: 2025-10-13  
**Version**: 2.0 (consolidée)

## 🗂️ Structure

```
myia_qdrant/
├── scripts/              # Scripts opérationnels consolidés
│   ├── health/          # Monitoring et health checks
│   ├── backup/          # Sauvegarde et restauration
│   ├── diagnostics/     # Outils de diagnostic
│   └── maintenance/     # Opérations de maintenance
├── docs/                # Documentation centralisée
│   ├── configuration/   # Standards de configuration
│   └── incidents/       # Résolutions d'incidents
└── README.md           # Ce fichier
```

## 🚀 Quick Start

### Monitoring Rapide

```powershell
# Check santé complet (toutes collections)
.\myia_qdrant\scripts\health\monitor_qdrant.ps1

# Check collection spécifique
.\myia_qdrant\scripts\health\monitor_qdrant.ps1 -Collection "roo_tasks_semantic_index"

# Monitoring continu (refresh toutes les 30s)
.\myia_qdrant\scripts\health\monitor_qdrant.ps1 -Watch -IntervalSeconds 30
```

### Backup

```powershell
# Backup complet Production
.\myia_qdrant\scripts\backup\backup_qdrant.ps1

# Backup instance Students
.\myia_qdrant\scripts\backup\backup_qdrant.ps1 -EnvFile ".env.students" -Port 6335

# Backup collection spécifique
.\myia_qdrant\scripts\backup\backup_qdrant.ps1 -Collections "ma_collection"
```

### Diagnostic

```powershell
# Analyse complète
.\myia_qdrant\scripts\diagnostics\analyze_issues.ps1

# Analyse freeze spécifique
.\myia_qdrant\scripts\diagnostics\analyze_issues.ps1 -AnalyzeFreeze -AnalyzeLogs

# Export rapport
.\myia_qdrant\scripts\diagnostics\analyze_issues.ps1 -ExportReport -OutputFile "diagnostic.md"
```

### Maintenance

```powershell
# Redémarrage sécurisé
.\myia_qdrant\scripts\maintenance\restart_qdrant.ps1

# Redémarrage sans backup
.\myia_qdrant\scripts\maintenance\restart_qdrant.ps1 -SkipBackup

# Redémarrage instance Students
.\myia_qdrant\scripts\maintenance\restart_qdrant.ps1 -ContainerName "qdrant_students" -Port 6335
```

## 📋 Scripts Disponibles

### Health / Monitoring

| Script | Description | Usage Principal |
|--------|-------------|-----------------|
| [`monitor_qdrant.ps1`](scripts/health/monitor_qdrant.ps1) | Monitoring unifié complet | Check santé quotidien, surveillance continue |

**Fonctionnalités:**
- ✅ Service health check
- ✅ Statistiques collections (points, vectors, segments)
- ✅ Métriques container (CPU, RAM, I/O)
- ✅ Analyse logs récents
- ✅ Export JSON/texte
- ✅ Mode continu avec refresh

### Backup / Restore

| Script | Description | Usage Principal |
|--------|-------------|-----------------|
| [`backup_qdrant.ps1`](scripts/backup/backup_qdrant.ps1) | Sauvegarde complète paramétrable | Backup avant opérations critiques |

**Fonctionnalités:**
- ✅ Snapshots via API Qdrant
- ✅ Backup configuration (docker-compose, .env, config/*.yaml)
- ✅ Métadonnées collections (config, points count, etc.)
- ✅ Support multi-instances (Production/Students)
- ✅ Compression optionnelle
- ✅ Logs détaillés

### Diagnostics

| Script | Description | Usage Principal |
|--------|-------------|-----------------|
| [`analyze_issues.ps1`](scripts/diagnostics/analyze_issues.ps1) | Analyse diagnostique approfondie | Troubleshooting problèmes |

**Fonctionnalités:**
- ✅ Analyse santé service et collections
- ✅ Détection problèmes indexation
- ✅ Analyse logs avec patterns freeze
- ✅ Métriques ressources (CPU, RAM, disque)
- ✅ Recommandations automatiques
- ✅ Export rapport Markdown

### Maintenance

| Script | Description | Usage Principal |
|--------|-------------|-----------------|
| [`restart_qdrant.ps1`](scripts/maintenance/restart_qdrant.ps1) | Redémarrage sécurisé | Restart contrôlé après config |

**Fonctionnalités:**
- ✅ Backup automatique pré-restart
- ✅ Health check pré et post-restart
- ✅ Attente stabilisation service
- ✅ Analyse logs post-restart
- ✅ Rollback automatique si échec

## 📚 Documentation

### Configuration

- **[Standards Qdrant](docs/configuration/qdrant_standards.md)** - Configurations recommandées
  - Modèles d'embedding supportés
  - Configuration HNSW
  - Limites ressources Docker
  - Checklist de validation

### Incidents

#### [Incident 2025-10-13: Freeze Production](docs/incidents/20251013_freeze/)

**Résumé**: 3 freezes récurrents causés par dimension vectors incorrecte (4096 vs 1536)

**Documents disponibles:**
- [README.md](docs/incidents/20251013_freeze/README.md) - Index de l'incident
- [RESOLUTION_FINALE.md](docs/incidents/20251013_freeze/RESOLUTION_FINALE.md) - Résolution complète
- [DIAGNOSTIC_FINAL.md](docs/incidents/20251013_freeze/DIAGNOSTIC_FINAL.md) - Diagnostic détaillé
- [CORRECTION_RAPPORT.md](docs/incidents/20251013_freeze/CORRECTION_RAPPORT.md) - Rapport correction

**Leçons apprises:**
- ✅ Vérifier cohérence dimension modèle vs collection
- ✅ Erreurs indexation silencieuses → freezes
- ✅ Importance backups avant opérations critiques

## 🔧 État de l'Installation

### Instances Déployées

| Instance | Port | Container | Status | Collections | Version |
|----------|------|-----------|--------|-------------|---------|
| **Production** | 6333 | `qdrant_production` | ✅ Actif | 15 | 1.7.4 |
| **Students** | 6335 | `qdrant_students` | ✅ Actif | 3 | 1.7.4 |

### Collections Problématiques Connues

| Collection | Instance | Problème | Statut | Correction |
|------------|----------|----------|--------|------------|
| `roo_tasks_semantic_index` | Production | Dimension incorrecte | ✅ Corrigé | 2025-10-13 |

### Dernières Opérations

| Date | Opération | Instance | Résultat | Détails |
|------|-----------|----------|----------|---------|
| 2025-10-13 | Correction freeze | Production | ✅ Succès | Recréation `roo_tasks_semantic_index` |
| 2025-10-08 | Migration Students | Students | ✅ Succès | Optimisation configuration |
| 2025-10-07 | Optimization | Production | ✅ Succès | Configuration HNSW |

## 🎯 Recommandations pour la Suite

### Monitoring

1. **Automatiser surveillance quotidienne**
   ```powershell
   # Ajouter à tâche planifiée Windows
   .\myia_qdrant\scripts\health\monitor_qdrant.ps1 -LogToFile
   ```

2. **Alerts sur métriques critiques**
   - Utilisation mémoire > 90%
   - Espace disque < 10%
   - Erreurs dans logs récents

### Backup

1. **Backup quotidien automatisé**
   - Rotation 7 jours
   - Compression archives > 7 jours
   - Vérification intégrité

2. **Backup avant toute opération critique**
   - Modification configuration
   - Migration de données
   - Mise à jour version Qdrant

### Diagnostic

1. **Check santé hebdomadaire complet**
   ```powershell
   .\myia_qdrant\scripts\diagnostics\analyze_issues.ps1 -ExportReport
   ```

2. **Analyse proactive des patterns**
   - Tendances usage mémoire
   - Croissance nombre de points
   - Performance indexation

## 📊 Métriques Actuelles (2025-10-13)

### Production

- **Collections**: 15 actives
- **Points totaux**: ~500K
- **Utilisation mémoire**: ~2.5G / 4G (62%)
- **Utilisation CPU**: ~15-25%
- **Espace disque**: 45% utilisé
- **Uptime**: 4h (depuis dernière correction)

### Students

- **Collections**: 3 actives
- **Points totaux**: ~50K
- **Utilisation mémoire**: ~1.2G / 2G (60%)
- **Utilisation CPU**: ~10-15%
- **Espace disque**: 45% utilisé (partagé avec Production)

## 🔗 Liens Utiles

### Documentation Qdrant

- [Documentation officielle](https://qdrant.tech/documentation/)
- [API Reference](https://qdrant.github.io/qdrant/redoc/index.html)
- [Performance Tuning](https://qdrant.tech/documentation/guides/optimize/)
- [Quantization Guide](https://qdrant.tech/documentation/guides/quantization/)

### Ressources Internes

- Configuration: `config/production.yaml`, `config/students.yaml`
- Docker Compose: `docker-compose.production.yml`, `docker-compose.students.yml`
- Environnements: `.env.production`, `.env.students`
- Backups: `backups/production/`, `backups/students/`

## ❓ FAQ

### Comment vérifier rapidement la santé?

```powershell
.\myia_qdrant\scripts\health\monitor_qdrant.ps1
```

### Comment créer un backup avant maintenance?

```powershell
.\myia_qdrant\scripts\backup\backup_qdrant.ps1
```

### Le service freeze, que faire?

1. Capturer les logs:
   ```powershell
   docker logs qdrant_production --tail 500 > freeze_logs.txt
   ```

2. Lancer diagnostic:
   ```powershell
   .\myia_qdrant\scripts\diagnostics\analyze_issues.ps1 -AnalyzeFreeze -ExportReport
   ```

3. Consulter: [`docs/incidents/`](docs/incidents/)

### Comment ajouter une nouvelle collection?

1. Vérifier standards: [`docs/configuration/qdrant_standards.md`](docs/configuration/qdrant_standards.md)
2. Valider dimension vs modèle
3. Créer backup: `.\myia_qdrant\scripts\backup\backup_qdrant.ps1`
4. Créer collection via API
5. Vérifier: `.\myia_qdrant\scripts\health\monitor_qdrant.ps1 -Collection "nouvelle_col"`

## 📝 Notes de Migration

### Depuis ancien `scripts/`

Les anciens scripts dans `D:\qdrant\scripts\` sont maintenant **obsolètes** et peuvent être archivés:

- ✅ `monitor_collection_health.ps1` → `myia_qdrant/scripts/health/monitor_qdrant.ps1`
- ✅ `monitor_qdrant_health_enhanced.ps1` → Fusionné dans `monitor_qdrant.ps1`
- ✅ `students_backup.ps1` → `myia_qdrant/scripts/backup/backup_qdrant.ps1`
- ✅ `analyze_freeze_logs.ps1` → `myia_qdrant/scripts/diagnostics/analyze_issues.ps1`
- ✅ `safe_restart_production.ps1` → `myia_qdrant/scripts/maintenance/restart_qdrant.ps1`

**Scripts ad-hoc à archiver:**
- `check_health_temp.ps1`, `check_status_temp.ps1` - Scripts temporaires
- `URGENT_data_recovery.ps1`, `fix_network_and_restart.ps1` - Scripts one-shot
- `test_production_with_wsl_binds.ps1` - Script de test

## 🤝 Contribution

Pour ajouter un nouveau script ou documentation:

1. Respecter la structure de dossiers
2. Utiliser paramètres cohérents (EnvFile, Port, ContainerName)
3. Inclure exemples d'usage en en-tête
4. Documenter dans ce README.md
5. Tester sur instance de test d'abord

## 📞 Support

En cas de problème critique:

1. Consulter [`docs/incidents/`](docs/incidents/) pour incidents similaires
2. Lancer diagnostic complet avec export
3. Documenter dans nouveau dossier `docs/incidents/YYYYMMDD_description/`

---

**Auteur**: Consolidation 2025-10-13  
**Maintenance**: Équipe MyIA
