# INDEX - MyIA Qdrant Tools & Documentation

**Version**: 3.0  
**Dernière mise à jour**: 2025-10-13  
**Statut**: ✅ Réorganisé et optimisé

---

## 📋 Table des Matières

1. [Scripts Disponibles](#-scripts-disponibles)
2. [Documentation](#-documentation)
3. [Archives](#-archives)
4. [Structure du Projet](#-structure-du-projet)
5. [Guide d'Utilisation](#-guide-dutilisation)

---

## 🛠️ Scripts Disponibles

### Scripts de Configuration (`scripts/setup/`)

Scripts pour installer et configurer les services automatisés.

| Script | Description | Usage |
|--------|-------------|-------|
| [`setup_automated_backup.ps1`](scripts/setup/setup_automated_backup.ps1) | Configure les backups automatiques | `./scripts/setup/setup_automated_backup.ps1` |
| [`setup_automated_monitoring.ps1`](scripts/setup/setup_automated_monitoring.ps1) | Configure le monitoring automatique | `./scripts/setup/setup_automated_monitoring.ps1` |
| [`uninstall_automated_backup.ps1`](scripts/setup/uninstall_automated_backup.ps1) | Désinstalle les backups automatiques | `./scripts/setup/uninstall_automated_backup.ps1` |
| [`uninstall_automated_monitoring.ps1`](scripts/setup/uninstall_automated_monitoring.ps1) | Désinstalle le monitoring automatique | `./scripts/setup/uninstall_automated_monitoring.ps1` |

### Scripts Utilitaires (`scripts/utilities/`)

Scripts simples et autonomes pour les opérations courantes.

| Script | Description | Usage |
|--------|-------------|-------|
| [`backup.ps1`](scripts/utilities/backup.ps1) | Sauvegarde manuelle simple de Qdrant | `./scripts/utilities/backup.ps1` |
| [`restore.ps1`](scripts/utilities/restore.ps1) | Restauration depuis une sauvegarde | `./scripts/utilities/restore.ps1` |
| [`monitor_qdrant_health.ps1`](scripts/utilities/monitor_qdrant_health.ps1) | Monitoring basique de santé Qdrant | `./scripts/utilities/monitor_qdrant_health.ps1` |
| [`scan_collections_config.ps1`](scripts/utilities/scan_collections_config.ps1) | Scan des configurations de toutes les collections | `./scripts/utilities/scan_collections_config.ps1` |
| [`monitor_collection_health.ps1`](scripts/utilities/monitor_collection_health.ps1) | Monitoring continu de la santé des collections | `./scripts/utilities/monitor_collection_health.ps1` |

### Scripts de Diagnostic (`scripts/diagnostics/`)

Scripts pour diagnostiquer et réparer les problèmes Qdrant.

| Script | Description | Usage | Documentation |
|--------|-------------|-------|---------------|
| [`analyze_freeze_logs.ps1`](scripts/diagnostics/analyze_freeze_logs.ps1) | Analyse des logs lors de freeze Qdrant | `./scripts/diagnostics/analyze_freeze_logs.ps1` | - |
| [`fix_roo_tasks_semantic_index.ps1`](scripts/diagnostics/fix_roo_tasks_semantic_index.ps1) | Correction de l'index sémantique roo_tasks | `./scripts/diagnostics/fix_roo_tasks_semantic_index.ps1` | [archive/diagnostics/](archive/diagnostics/) |
| [`analyze_issues.ps1`](scripts/diagnostics/analyze_issues.ps1) | Analyse complète des problèmes Qdrant | `./scripts/diagnostics/analyze_issues.ps1` | - |

### Scripts Unifiés (Racine `scripts/`)

Scripts consolidés et avancés pour une gestion complète.

| Script | Description | Usage |
|--------|-------------|-------|
| [`qdrant_backup.ps1`](scripts/qdrant_backup.ps1) | Backup unifié avec options avancées | `./scripts/qdrant_backup.ps1` |
| [`qdrant_migrate.ps1`](scripts/qdrant_migrate.ps1) | Migration de données entre environnements | `./scripts/qdrant_migrate.ps1` |
| [`qdrant_monitor.ps1`](scripts/qdrant_monitor.ps1) | Monitoring avancé continu | `./scripts/qdrant_monitor.ps1` |
| [`qdrant_restart.ps1`](scripts/qdrant_restart.ps1) | Redémarrage sécurisé de Qdrant | `./scripts/qdrant_restart.ps1` |
| [`qdrant_rollback.ps1`](scripts/qdrant_rollback.ps1) | Rollback vers un état précédent | `./scripts/qdrant_rollback.ps1` |
| [`qdrant_update.ps1`](scripts/qdrant_update.ps1) | Mise à jour de la configuration | `./scripts/qdrant_update.ps1` |
| [`qdrant_verify.ps1`](scripts/qdrant_verify.ps1) | Vérification de l'intégrité | `./scripts/qdrant_verify.ps1` |

---

## 📚 Documentation

### Documentation Principale

| Document | Description | Lien |
|----------|-------------|------|
| **README.md** | Guide principal du projet | [README.md](README.md) |
| **REORGANIZATION_PLAN.md** | Plan de réorganisation (v3.0) | [REORGANIZATION_PLAN.md](REORGANIZATION_PLAN.md) |
| **INDEX.md** | Ce fichier - Index complet | [INDEX.md](INDEX.md) |

### Documentation Technique

#### Configuration (`docs/configuration/`)

| Document | Description |
|----------|-------------|
| [`qdrant_standards.md`](docs/configuration/qdrant_standards.md) | Standards de configuration Qdrant |

#### Incidents (`docs/incidents/`)

##### Incident du 13 Octobre 2025 (`docs/incidents/20251013_freeze/`)

| Document | Description | Taille |
|----------|-------------|--------|
| [`README.md`](docs/incidents/20251013_freeze/README.md) | Vue d'ensemble de l'incident | 3.24 KB |
| [`DIAGNOSTIC_FINAL.md`](docs/incidents/20251013_freeze/DIAGNOSTIC_FINAL.md) | Diagnostic final | 7.21 KB |
| [`CORRECTION_RAPPORT.md`](docs/incidents/20251013_freeze/CORRECTION_RAPPORT.md) | Rapport de correction | 10.13 KB |
| [`INCIDENT_POST_CORRECTION.md`](docs/incidents/20251013_freeze/INCIDENT_POST_CORRECTION.md) | Incident post-correction | 6.64 KB |
| [`RESOLUTION_FINALE.md`](docs/incidents/20251013_freeze/RESOLUTION_FINALE.md) | Résolution finale avec actions | 16.52 KB |

### Documentation Scripts

| Document | Description |
|----------|-------------|
| [`scripts/README.md`](scripts/README.md) | Documentation des scripts consolidés |
| [`scripts/CONSOLIDATION_PLAN.md`](scripts/CONSOLIDATION_PLAN.md) | Plan de consolidation des scripts |
| [`scripts/CONSOLIDATION_REPORT.md`](scripts/CONSOLIDATION_REPORT.md) | Rapport de consolidation |

---

## 📦 Archives

### Rapports Archivés (`archive/reports/`)

Rapports historiques de maintenance et de consolidation.

| Document | Description |
|----------|-------------|
| [`CLEANUP_REPORT_20251013.md`](archive/reports/CLEANUP_REPORT_20251013.md) | Rapport de nettoyage du 13 octobre 2025 |
| [`CONSOLIDATION_REPORT_20251013.md`](archive/reports/CONSOLIDATION_REPORT_20251013.md) | Rapport de consolidation du 13 octobre 2025 |

### Diagnostics Archivés (`archive/diagnostics/`)

Tous les fichiers de diagnostic de l'incident du 13 octobre 2025.

**Note**: Consultez [`archive/README.md`](archive/README.md) pour la liste complète des fichiers archivés et leur organisation.

| Type | Localisation | Description |
|------|--------------|-------------|
| Scripts | `archive/diagnostics/scripts/` | Scripts PowerShell de diagnostic (`.ps1`) |
| Logs | `archive/diagnostics/logs/` | Fichiers de logs (`.txt`, `.log`) |
| Rapports | `archive/diagnostics/` | Rapports et données (`.md`, `.json`) |

### Scripts Archivés (`scripts/archive/`)

Scripts obsolètes ou temporaires conservés pour référence.

| Script | Description |
|--------|-------------|
| `09_finalize_consolidation.ps1` | Finalisation de la consolidation |
| `10_verify_final_state.ps1` | Vérification de l'état final |
| `11_empty_scripts_directory.ps1` | Nettoyage du répertoire scripts |
| `12_analyze_myia_structure.ps1` | Analyse de la structure myia_qdrant |
| `backup_qdrant.ps1` | Ancien script de backup (remplacé par scripts unifiés) |
| `monitor_qdrant.ps1` | Ancien script de monitoring (remplacé) |
| `restart_qdrant.ps1` | Ancien script de redémarrage (remplacé) |
| `test_production_with_wsl_binds.ps1` | Test de production avec WSL |
| `URGENT_data_recovery.ps1` | Script de récupération d'urgence |

---

## 🗂️ Structure du Projet

```
myia_qdrant/
│
├── 📄 README.md                              # Guide principal
├── 📄 INDEX.md                               # Ce fichier - Index complet
├── 📄 REORGANIZATION_PLAN.md                 # Plan de réorganisation v3.0
│
├── 📁 scripts/                               # Scripts organisés
│   ├── 📁 setup/                             # Installation & configuration
│   │   ├── setup_automated_backup.ps1
│   │   ├── setup_automated_monitoring.ps1
│   │   ├── uninstall_automated_backup.ps1
│   │   └── uninstall_automated_monitoring.ps1
│   │
│   ├── 📁 utilities/                         # Scripts utilitaires simples
│   │   ├── backup.ps1
│   │   ├── restore.ps1
│   │   ├── monitor_qdrant_health.ps1
│   │   ├── scan_collections_config.ps1
│   │   └── monitor_collection_health.ps1
│   │
│   ├── 📁 diagnostics/                       # Scripts de diagnostic
│   │   ├── analyze_freeze_logs.ps1
│   │   ├── fix_roo_tasks_semantic_index.ps1
│   │   └── analyze_issues.ps1
│   │
│   ├── 📁 archive/                           # Scripts archivés
│   │   ├── 09_finalize_consolidation.ps1
│   │   ├── 10_verify_final_state.ps1
│   │   ├── 11_empty_scripts_directory.ps1
│   │   ├── 12_analyze_myia_structure.ps1
│   │   ├── backup_qdrant.ps1
│   │   ├── monitor_qdrant.ps1
│   │   ├── restart_qdrant.ps1
│   │   ├── test_production_with_wsl_binds.ps1
│   │   └── URGENT_data_recovery.ps1
│   │
│   ├── 🛠️ Scripts unifiés (racine scripts/)
│   │   ├── qdrant_backup.ps1                 # Backup unifié
│   │   ├── qdrant_migrate.ps1                # Migration
│   │   ├── qdrant_monitor.ps1                # Monitoring
│   │   ├── qdrant_restart.ps1                # Redémarrage
│   │   ├── qdrant_rollback.ps1               # Rollback
│   │   ├── qdrant_update.ps1                 # Mise à jour
│   │   └── qdrant_verify.ps1                 # Vérification
│   │
│   └── 📝 Documentation scripts
│       ├── README.md
│       ├── CONSOLIDATION_PLAN.md
│       ├── CONSOLIDATION_REPORT.md
│       └── consolidation_report_*.json
│
├── 📁 docs/                                  # Documentation
│   ├── configuration/
│   │   └── qdrant_standards.md               # Standards Qdrant
│   └── incidents/
│       └── 20251013_freeze/                  # Incident du 13/10
│           ├── README.md
│           ├── DIAGNOSTIC_FINAL.md
│           ├── CORRECTION_RAPPORT.md
│           ├── INCIDENT_POST_CORRECTION.md
│           ├── RESOLUTION_FINALE.md
│           └── [fichiers associés]
│
└── 📁 archive/                               # Fichiers archivés
    ├── README.md                             # Guide des archives
    ├── reports/                              # Rapports historiques
    │   ├── CLEANUP_REPORT_20251013.md
    │   └── CONSOLIDATION_REPORT_20251013.md
    └── diagnostics/                          # Diagnostics archivés
        ├── scripts/                          # Scripts de diagnostic
        ├── logs/                             # Logs de diagnostic
        └── [rapports et données]
```

---

## 📖 Guide d'Utilisation

### Démarrage Rapide

#### 1. Configuration Initiale

```powershell
# Configurer le monitoring automatique
./scripts/setup/setup_automated_monitoring.ps1

# Configurer les backups automatiques
./scripts/setup/setup_automated_backup.ps1
```

#### 2. Opérations Courantes

```powershell
# Backup manuel
./scripts/utilities/backup.ps1

# Monitoring de santé
./scripts/utilities/monitor_qdrant_health.ps1

# Monitoring des collections
./scripts/utilities/monitor_collection_health.ps1

# Scanner les configurations
./scripts/utilities/scan_collections_config.ps1
```

#### 3. Scripts Unifiés (Avancés)

```powershell
# Backup avancé avec options
./scripts/qdrant_backup.ps1

# Monitoring continu
./scripts/qdrant_monitor.ps1

# Redémarrage sécurisé
./scripts/qdrant_restart.ps1

# Vérification d'intégrité
./scripts/qdrant_verify.ps1
```

### Scénarios d'Usage

#### Scénario 1: Qdrant Freeze ou Lenteur

1. **Diagnostic initial**:
   ```powershell
   ./scripts/diagnostics/analyze_freeze_logs.ps1
   ```

2. **Analyse détaillée**:
   ```powershell
   ./scripts/diagnostics/analyze_issues.ps1
   ```

3. **Vérifier les collections**:
   ```powershell
   ./scripts/utilities/monitor_collection_health.ps1
   ```

4. **Si nécessaire, réparer**:
   ```powershell
   ./scripts/diagnostics/fix_roo_tasks_semantic_index.ps1
   ```

#### Scénario 2: Maintenance Préventive

1. **Backup avant maintenance**:
   ```powershell
   ./scripts/utilities/backup.ps1
   ```

2. **Scanner les configurations**:
   ```powershell
   ./scripts/utilities/scan_collections_config.ps1
   ```

3. **Redémarrage sécurisé**:
   ```powershell
   ./scripts/qdrant_restart.ps1
   ```

4. **Vérification post-maintenance**:
   ```powershell
   ./scripts/qdrant_verify.ps1
   ```

#### Scénario 3: Configuration Initiale

```powershell
# 1. Configurer les services automatisés
./scripts/setup/setup_automated_monitoring.ps1
./scripts/setup/setup_automated_backup.ps1

# 2. Vérifier que tout fonctionne
./scripts/utilities/monitor_qdrant_health.ps1

# 3. Créer un premier backup
./scripts/utilities/backup.ps1
```

### Référence des Incidents

Pour consulter les diagnostics passés et les solutions appliquées:

1. **Incident du 13 Octobre 2025** (Freeze Qdrant):
   - 📖 [Vue d'ensemble](docs/incidents/20251013_freeze/README.md)
   - 🔍 [Diagnostic final](docs/incidents/20251013_freeze/DIAGNOSTIC_FINAL.md)
   - ✅ [Solution appliquée](docs/incidents/20251013_freeze/CORRECTION_RAPPORT.md)
   - 📊 [Résolution finale](docs/incidents/20251013_freeze/RESOLUTION_FINALE.md)

2. **Fichiers de diagnostic archivés**:
   - 📁 [Archive complète](archive/diagnostics/)
   - 📄 [Guide des archives](archive/README.md)

---

## 🔗 Liens Utiles

- **Documentation Qdrant**: https://qdrant.tech/documentation/
- **API Reference**: https://qdrant.tech/documentation/api/
- **Standards de configuration**: [docs/configuration/qdrant_standards.md](docs/configuration/qdrant_standards.md)
- **Guide des archives**: [archive/README.md](archive/README.md)

---

## 📞 Support et Contribution

Pour toute question ou contribution:
1. Consulter la documentation dans `docs/`
2. Vérifier les incidents passés dans `docs/incidents/` et `archive/diagnostics/`
3. Utiliser les scripts de diagnostic dans `scripts/diagnostics/`
4. Consulter les rapports archivés dans `archive/reports/`

---

## 📝 Historique des Versions

- **v3.0** (2025-10-13) : Réorganisation complète de la structure
  - Scripts organisés en setup/, utilities/, diagnostics/
  - Création de l'archive/ pour les fichiers historiques
  - Nettoyage de la racine (0 scripts)
  - Suppression du répertoire diagnostics/ (tout archivé)
  
- **v2.0** (2025-10-13) : Consolidation des scripts
  - Création des scripts unifiés qdrant_*.ps1
  - Organisation par catégories

- **v1.0** (2025-07) : Version initiale

---

**Dernière mise à jour**: 2025-10-13 à 20:34 UTC+2  
**Statut**: ✅ Réorganisé selon REORGANIZATION_PLAN.md  
**Version**: 3.0 (Post-réorganisation)