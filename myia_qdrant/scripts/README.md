# 📚 Guide d'Utilisation des Scripts Qdrant Unifiés

**Date de consolidation** : 2025-10-13  
**Version** : 1.0  
**Environnements supportés** : `production` (port 6333) | `students` (port 6335)

---

## 🎯 Vue d'Ensemble

Ces scripts unifiés remplacent 15 scripts redondants par **7 scripts modulaires** qui fonctionnent avec plusieurs environnements Qdrant via le paramètre `-Environment`.

### ✨ Avantages

- ✅ **DRY (Don't Repeat Yourself)** : Un seul script par fonctionnalité
- ✅ **Interface unifiée** : Paramètre `-Environment [production|students]`
- ✅ **Maintenabilité** : Code centralisé et testé
- ✅ **Évolutivité** : Ajout facile de nouveaux environnements

---

## 📋 Liste des Scripts

| Script | Remplace | Fonction |
|--------|----------|----------|
| [`qdrant_backup.ps1`](#1-qdrant_backupps1) | 3 scripts | Sauvegarde complète |
| [`qdrant_migrate.ps1`](#2-qdrant_migrateps1) | 2 scripts | Migration de configuration |
| [`qdrant_monitor.ps1`](#3-qdrant_monitorp1) | 2 scripts | Monitoring de santé |
| [`qdrant_rollback.ps1`](#4-qdrant_rollbackps1) | 2 scripts | Rollback d'urgence |
| [`qdrant_restart.ps1`](#5-qdrant_restartps1) | 2 scripts | Redémarrage sécurisé |
| [`qdrant_update.ps1`](#6-qdrant_updateps1) | 1 script | Mise à jour version |
| [`qdrant_verify.ps1`](#7-qdrant_verifyps1) | 1 script | Vérification configuration |

---

## 1. `qdrant_backup.ps1`

**Fonction** : Créer une sauvegarde complète de l'environnement Qdrant

### Syntaxe
```powershell
.\qdrant_backup.ps1 -Environment <production|students> [-SkipSnapshot] [-BackupDir <path>]
```

### Paramètres
- `-Environment` : (requis) `production` ou `students`
- `-SkipSnapshot` : (optionnel) Ignorer la création de snapshot (plus rapide)
- `-BackupDir` : (optionnel) Répertoire de destination (défaut: `backups/<env>`)

### Exemples
```powershell
# Backup complet de production
.\qdrant_backup.ps1 -Environment production

# Backup rapide de students sans snapshot
.\qdrant_backup.ps1 -Environment students -SkipSnapshot

# Backup vers un répertoire personnalisé
.\qdrant_backup.ps1 -Environment production -BackupDir "C:\backups\qdrant"
```

### Ce qui est sauvegardé
- ✅ Snapshot Qdrant via API
- ✅ Fichier de configuration (`config/<env>.yaml`)
- ✅ Docker Compose (`docker-compose.<env>.yml`)
- ✅ Fichier ENV (`.env` ou `.env.students`)
- ✅ Liste des collections (JSON)
- ✅ Informations système (version, commit)
- ✅ Rapport de sauvegarde (JSON)

---

## 2. `qdrant_migrate.ps1`

**Fonction** : Migrer vers une nouvelle configuration de manière orchestrée

### Syntaxe
```powershell
.\qdrant_migrate.ps1 -Environment <production|students> [-DryRun] [-AutoConfirm] [-SkipBackup]
```

### Paramètres
- `-Environment` : (requis) `production` ou `students`
- `-DryRun` : (optionnel) Mode test sans modification
- `-AutoConfirm` : (optionnel) Mode automatique sans confirmation (CI/CD)
- `-SkipBackup` : (optionnel) Ignorer le backup pré-migration (RISQUÉ)

### Exemples
```powershell
# Migration interactive avec confirmations
.\qdrant_migrate.ps1 -Environment production

# Test de migration (simulation)
.\qdrant_migrate.ps1 -Environment students -DryRun

# Migration automatique pour CI/CD
.\qdrant_migrate.ps1 -Environment production -AutoConfirm

# Migration sans backup (RISQUÉ)
.\qdrant_migrate.ps1 -Environment students -SkipBackup
```

### Étapes de migration
1. ✅ Vérification des prérequis
2. ✅ Backup automatique (sauf si `-SkipBackup`)
3. ✅ Arrêt gracieux du service
4. ✅ Mise à jour des fichiers de configuration
5. ✅ Redémarrage du service
6. ✅ Validation post-migration
7. ✅ Rapport détaillé

---

## 3. `qdrant_monitor.ps1`

**Fonction** : Monitoring de la santé et des performances

### Syntaxe
```powershell
.\qdrant_monitor.ps1 -Environment <production|students> [-Continuous] [-RefreshInterval <seconds>] [-OutputFile <path>] [-ExportJson]
```

### Paramètres
- `-Environment` : (requis) `production` ou `students`
- `-Continuous` : (optionnel) Mode continu avec actualisation automatique
- `-RefreshInterval` : (optionnel) Intervalle de rafraîchissement en secondes (défaut: 30)
- `-OutputFile` : (optionnel) Fichier de sortie pour les logs
- `-ExportJson` : (optionnel) Export au format JSON pour automatisation

### Exemples
```powershell
# Monitoring unique
.\qdrant_monitor.ps1 -Environment production

# Monitoring continu avec refresh toutes les 30 secondes
.\qdrant_monitor.ps1 -Environment students -Continuous -RefreshInterval 30

# Export vers fichier texte
.\qdrant_monitor.ps1 -Environment production -OutputFile monitor.log

# Export JSON pour automatisation
.\qdrant_monitor.ps1 -Environment production -ExportJson -OutputFile status.json
```

### Métriques surveillées
- ✅ État du container Docker
- ✅ Health check API Qdrant
- ✅ Version et commit
- ✅ Utilisation CPU et mémoire
- ✅ I/O réseau et disque
- ✅ Nombre de collections
- ✅ Erreurs et avertissements dans les logs

---

## 4. `qdrant_rollback.ps1`

**Fonction** : Restaurer la configuration pré-migration en cas de problème

### Syntaxe
```powershell
.\qdrant_rollback.ps1 -Environment <production|students> [-Force] [-SkipValidation]
```

### Paramètres
- `-Environment` : (requis) `production` ou `students`
- `-Force` : (optionnel) Mode automatique sans confirmation (DANGEREUX)
- `-SkipValidation` : (optionnel) Ignorer la validation post-rollback

### Exemples
```powershell
# Rollback interactif avec confirmation
.\qdrant_rollback.ps1 -Environment production

# Rollback d'urgence automatique
.\qdrant_rollback.ps1 -Environment students -Force

# Rollback rapide sans validation
.\qdrant_rollback.ps1 -Environment production -SkipValidation
```

### Prérequis
- Fichiers de backup créés par `qdrant_backup.ps1` ou `qdrant_migrate.ps1`
- Fichiers `*.pre-migration-*` présents dans le répertoire de config

### ⚠️ Attention
Ce script arrête et redémarre le service Qdrant !

---

## 5. `qdrant_restart.ps1`

**Fonction** : Redémarrer le service de manière sécurisée

### Syntaxe
```powershell
.\qdrant_restart.ps1 -Environment <production|students> [-SkipSnapshot] [-Force] [-FixNetwork]
```

### Paramètres
- `-Environment` : (requis) `production` ou `students`
- `-SkipSnapshot` : (optionnel) Ignorer le snapshot de sécurité
- `-Force` : (optionnel) Redémarrage forcé sans confirmation
- `-FixNetwork` : (optionnel) Nettoyer les réseaux Docker avant redémarrage
- `-GracePeriodSeconds` : (optionnel) Délai d'arrêt gracieux (défaut: 60s)

### Exemples
```powershell
# Redémarrage sécurisé avec snapshot
.\qdrant_restart.ps1 -Environment production

# Redémarrage rapide sans snapshot
.\qdrant_restart.ps1 -Environment students -SkipSnapshot

# Redémarrage avec correction réseau Docker
.\qdrant_restart.ps1 -Environment production -FixNetwork

# Redémarrage forcé en urgence
.\qdrant_restart.ps1 -Environment production -Force -SkipSnapshot
```

### Mode `-FixNetwork`
Utile en cas de problèmes réseau Docker :
- Arrête tous les services Docker Compose
- Nettoie les réseaux orphelins
- Supprime le réseau `qdrant_default`
- Redémarre proprement le service

---

## 6. `qdrant_update.ps1`

**Fonction** : Mettre à jour la version de Qdrant

### Syntaxe
```powershell
.\qdrant_update.ps1 -Environment <production|students> [-SkipBackup] [-ToVersion <version>]
```

### Paramètres
- `-Environment` : (requis) `production` ou `students`
- `-SkipBackup` : (optionnel) Ignorer le backup pré-mise à jour (RISQUÉ)
- `-ToVersion` : (optionnel) Version cible spécifique (ex: "v1.8.0")

### Exemples
```powershell
# Mise à jour vers la dernière version
.\qdrant_update.ps1 -Environment production

# Mise à jour rapide sans backup (RISQUÉ)
.\qdrant_update.ps1 -Environment students -SkipBackup

# Mise à jour vers une version spécifique
.\qdrant_update.ps1 -Environment production -ToVersion "v1.8.0"
```

### Processus de mise à jour
1. ✅ Backup pré-mise à jour (optionnel)
2. ✅ Arrêt du service
3. ✅ Pull de la nouvelle image Docker
4. ✅ Démarrage avec la nouvelle image
5. ✅ Validation post-update
6. ✅ Rollback automatique en cas d'échec

---

## 7. `qdrant_verify.ps1`

**Fonction** : Vérifier la configuration et l'état du système

### Syntaxe
```powershell
.\qdrant_verify.ps1 -Environment <production|students|all> [-Detailed]
```

### Paramètres
- `-Environment` : (requis) `production`, `students` ou `all`
- `-Detailed` : (optionnel) Rapport détaillé avec informations supplémentaires

### Exemples
```powershell
# Vérification rapide de production
.\qdrant_verify.ps1 -Environment production

# Vérification détaillée de students
.\qdrant_verify.ps1 -Environment students -Detailed

# Vérification de tous les environnements
.\qdrant_verify.ps1 -Environment all
```

### Vérifications effectuées
- ✅ Docker disponible et version
- ✅ Fichiers de configuration existants
- ✅ Volumes Docker créés
- ✅ Container en cours d'exécution
- ✅ Connectivité API Qdrant
- ✅ Version Qdrant
- ✅ Collections accessibles
- ✅ **Score de santé** (pourcentage de checks réussis)

---

## 🔑 Configuration des Environnements

Chaque script utilise une configuration centralisée :

```powershell
$EnvironmentConfig = @{
    production = @{
        Port = 6333
        ContainerName = "qdrant_production"
        EnvFile = ".env"
        ConfigFile = "config/production.yaml"
        ComposeFile = "docker-compose.yml"
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ConfigFile = "config/students.yaml"
        ComposeFile = "docker-compose.students.yml"
    }
}
```

---

## 🚀 Workflows Typiques

### Workflow de Migration
```powershell
# 1. Vérifier l'état actuel
.\qdrant_verify.ps1 -Environment production -Detailed

# 2. Tester la migration (simulation)
.\qdrant_migrate.ps1 -Environment production -DryRun

# 3. Exécuter la migration réelle
.\qdrant_migrate.ps1 -Environment production

# 4. Vérifier le résultat
.\qdrant_monitor.ps1 -Environment production

# 5. En cas de problème, rollback
.\qdrant_rollback.ps1 -Environment production
```

### Workflow de Maintenance
```powershell
# 1. Backup avant maintenance
.\qdrant_backup.ps1 -Environment students

# 2. Mise à jour de version
.\qdrant_update.ps1 -Environment students

# 3. Redémarrage si nécessaire
.\qdrant_restart.ps1 -Environment students

# 4. Monitoring post-maintenance
.\qdrant_monitor.ps1 -Environment students -Continuous
```

### Workflow de Dépannage
```powershell
# 1. Diagnostic complet
.\qdrant_verify.ps1 -Environment production -Detailed

# 2. Vérifier les logs en continu
.\qdrant_monitor.ps1 -Environment production -Continuous

# 3. Redémarrage avec correction réseau
.\qdrant_restart.ps1 -Environment production -FixNetwork

# 4. Si problème persiste, rollback
.\qdrant_rollback.ps1 -Environment production
```

---

## 📁 Structure des Backups

Les backups sont organisés ainsi :

```
backups/
├── production/
│   ├── backup_20251013_193045.log
│   ├── backup_report_20251013_193045.json
│   ├── collections_20251013_193045.json
│   ├── system_info_20251013_193045.json
│   ├── production.yaml
│   ├── docker-compose.yml
│   └── .env
└── students/
    ├── backup_20251008_201500.log
    ├── backup_report_20251008_201500.json
    ├── collections_20251008_201500.json
    └── ...
```

---

## ⚠️ Bonnes Pratiques

### Avant toute opération critique
1. ✅ **Toujours faire un backup** : `qdrant_backup.ps1 -Environment <env>`
2. ✅ **Vérifier l'état du système** : `qdrant_verify.ps1 -Environment <env>`
3. ✅ **Tester en mode DryRun** si disponible

### Sécurité
- ❌ N'utilisez **jamais** `-SkipBackup` en production
- ❌ N'utilisez **jamais** `-Force` sans comprendre les conséquences
- ✅ Conservez les backups pendant au moins 7 jours
- ✅ Testez d'abord sur l'environnement `students` avant `production`

### Monitoring
- ✅ Utilisez `-Continuous` pour surveiller les opérations longues
- ✅ Exportez en JSON pour l'intégration avec des outils de monitoring
- ✅ Consultez les logs en cas de problème : `docker logs <container_name>`

---

## 🐛 Dépannage

### "Container non disponible"
```powershell
# Vérifier l'état
docker ps -a

# Redémarrer
.\qdrant_restart.ps1 -Environment <env>
```

### "API non accessible"
```powershell
# Vérifier les logs
docker logs qdrant_production --tail 50

# Vérifier la configuration
.\qdrant_verify.ps1 -Environment production -Detailed
```

### "Problème réseau Docker"
```powershell
# Redémarrer avec correction réseau
.\qdrant_restart.ps1 -Environment production -FixNetwork
```

### "Migration échouée"
```powershell
# Rollback immédiat
.\qdrant_rollback.ps1 -Environment production -Force
```

---

## 📝 Logs et Rapports

Tous les scripts génèrent des logs structurés :

- **Backup** : `backups/<env>/backup_<timestamp>.log`
- **Migration** : `logs/migration_<env>_<timestamp>.log`
- **Rollback** : `backups/<env>/rollback_<timestamp>.log`

Les rapports JSON permettent l'automatisation :
- `backup_report_<timestamp>.json`
- `migration_report_<env>_<timestamp>.json`
- `rollback_report_<timestamp>.json`

---

## 🔄 Migration depuis les Anciens Scripts

| Ancien Script | Nouveau Script | Commande Équivalente |
|---------------|----------------|---------------------|
| `backup_before_migration.ps1` | `qdrant_backup.ps1` | `-Environment production` |
| `students_backup.ps1` | `qdrant_backup.ps1` | `-Environment students` |
| `execute_migration.ps1` | `qdrant_migrate.ps1` | `-Environment production` |
| `students_migration.ps1` | `qdrant_migrate.ps1` | `-Environment students` |
| `monitor_qdrant_health_enhanced.ps1` | `qdrant_monitor.ps1` | `-Environment production` |
| `students_monitor.ps1` | `qdrant_monitor.ps1` | `-Environment students` |
| `rollback_migration.ps1` | `qdrant_rollback.ps1` | `-Environment production` |
| `students_rollback.ps1` | `qdrant_rollback.ps1` | `-Environment students` |
| `safe_restart_production.ps1` | `qdrant_restart.ps1` | `-Environment production` |
| `fix_network_and_restart.ps1` | `qdrant_restart.ps1` | `-Environment production -FixNetwork` |
| `update_production_simple.ps1` | `qdrant_update.ps1` | `-Environment production` |
| `verify_qdrant_config.ps1` | `qdrant_verify.ps1` | `-Environment production` |

---

## 📚 Ressources

- **Plan de consolidation** : [`CONSOLIDATION_PLAN.md`](CONSOLIDATION_PLAN.md)
- **Rapport de consolidation** : [`CONSOLIDATION_REPORT.md`](CONSOLIDATION_REPORT.md) *(à venir)*
- **Scripts archivés** : [`archive/`](archive/) *(scripts historiques pour référence)*

---

## 💡 Support

En cas de problème :
1. Consultez les logs générés par le script
2. Utilisez `qdrant_verify.ps1` pour un diagnostic complet
3. Vérifiez les logs Docker : `docker logs <container_name>`
4. Consultez les scripts archivés pour référence historique

---

**Version** : 1.0  
**Dernière mise à jour** : 2025-10-13