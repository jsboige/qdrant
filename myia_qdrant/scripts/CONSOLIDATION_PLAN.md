# Plan de Consolidation des Scripts Qdrant
**Date**: 2025-10-13
**Objectif**: Consolider 15 scripts redondants en 7 scripts unifiés et modulaires

## 📊 Analyse des Scripts Existants

### Scripts Actuels (15)
| Fichier | Taille | Fonction | Duplication |
|---------|--------|----------|-------------|
| `backup_before_migration.ps1` | 10.6KB | Backup production | ✅ Dupliqué |
| `backup_production_before_update.ps1` | 9.9KB | Backup production | ✅ Dupliqué |
| `students_backup.ps1` | 11KB | Backup students | ✅ Dupliqué |
| `execute_migration.ps1` | 32KB | Migration production | ✅ Dupliqué |
| `students_migration.ps1` | 24KB | Migration students | ✅ Dupliqué |
| `monitor_qdrant_health_enhanced.ps1` | 17KB | Monitoring production | ✅ Dupliqué |
| `students_monitor.ps1` | 15KB | Monitoring students | ✅ Dupliqué |
| `rollback_migration.ps1` | 14.7KB | Rollback production | ✅ Dupliqué |
| `students_rollback.ps1` | 15.2KB | Rollback students | ✅ Dupliqué |
| `safe_restart_production.ps1` | 10KB | Restart sécurisé | ⚠️ Production only |
| `fix_network_and_restart.ps1` | 4KB | Fix réseau Docker | ⚠️ Production only |
| `update_production_simple.ps1` | 4.5KB | Mise à jour simple | ⚠️ Production only |
| `URGENT_data_recovery.ps1` | 5.3KB | Récupération urgence | 🗄️ À archiver |
| `verify_qdrant_config.ps1` | 7.7KB | Vérification config | ✅ À unifier |
| `test_production_with_wsl_binds.ps1` | 2.4KB | Test WSL binds | 🗄️ À archiver |

**Total**: ~145KB de code → Objectif: ~70KB (-50%)

## 🎯 Scripts Consolidés (7)

### 1. **qdrant_backup.ps1** ⭐
**Remplace**: 3 scripts (backup_before_migration, backup_production_before_update, students_backup)

**Signature**:
```powershell
.\qdrant_backup.ps1 -Environment [production|students] [-SkipSnapshot] [-BackupDir <path>]
```

**Fonctionnalités unifiées**:
- ✅ Création de snapshots via API
- ✅ Sauvegarde des fichiers de configuration
- ✅ Export de la liste des collections
- ✅ Logs horodatés
- ✅ Support multi-environnement (production port 6333, students port 6335)
- ✅ Lecture auto de l'API key (.env ou .env.students)

**Configuration dynamique**:
```powershell
$config = @{
    production = @{
        Port = 6333
        Container = "qdrant_production"
        EnvFile = ".env"
        ConfigFile = "config/production.optimized.yaml"
    }
    students = @{
        Port = 6335
        Container = "qdrant_students"
        EnvFile = ".env.students"
        ConfigFile = "config/students.optimized.yaml"
    }
}
```

---

### 2. **qdrant_migrate.ps1** ⭐
**Remplace**: 2 scripts (execute_migration, students_migration)

**Signature**:
```powershell
.\qdrant_migrate.ps1 -Environment [production|students] [-DryRun] [-AutoConfirm] [-SkipBackup]
```

**Fonctionnalités unifiées**:
- ✅ Vérification complète des prérequis
- ✅ Sauvegarde automatique avant migration
- ✅ Arrêt gracieux du service
- ✅ Copie des nouveaux fichiers de configuration
- ✅ Redémarrage avec validation
- ✅ Monitoring post-migration
- ✅ Rapport détaillé de migration
- ✅ Mode DRY-RUN pour tests
- ✅ Confirmations interactives

---

### 3. **qdrant_monitor.ps1** ⭐
**Remplace**: 2 scripts (monitor_qdrant_health_enhanced, students_monitor)

**Signature**:
```powershell
.\qdrant_monitor.ps1 -Environment [production|students] [-Continuous] [-RefreshInterval <seconds>] [-OutputFile <path>] [-ExportJson]
```

**Fonctionnalités unifiées**:
- ✅ Health check du service
- ✅ Statistiques du container Docker
- ✅ Comptage des erreurs dans les logs
- ✅ État des collections
- ✅ Espace disque
- ✅ Métriques de performance
- ✅ Mode continu avec refresh configurable
- ✅ Export JSON pour monitoring automatisé

---

### 4. **qdrant_rollback.ps1** ⭐
**Remplace**: 2 scripts (rollback_migration, students_rollback)

**Signature**:
```powershell
.\qdrant_rollback.ps1 -Environment [production|students] [-Force] [-SkipValidation]
```

**Fonctionnalités unifiées**:
- ✅ Restauration de la configuration pré-migration
- ✅ Arrêt et redémarrage du service
- ✅ Validation des fichiers de backup
- ✅ Logs détaillés de rollback
- ✅ Mode Force pour urgences
- ✅ Validation post-rollback

---

### 5. **qdrant_restart.ps1** ⭐
**Remplace**: 2 scripts (safe_restart_production, fix_network_and_restart)

**Signature**:
```powershell
.\qdrant_restart.ps1 -Environment [production|students] [-SkipSnapshot] [-Force] [-FixNetwork]
```

**Fonctionnalités unifiées**:
- ✅ Redémarrage sécurisé avec snapshot
- ✅ Nettoyage des réseaux Docker (mode -FixNetwork)
- ✅ Grace period configurable
- ✅ Health checks post-redémarrage
- ✅ Récupération automatique en cas d'échec

---

### 6. **qdrant_update.ps1** ⭐
**Remplace**: 1 script (update_production_simple)

**Signature**:
```powershell
.\qdrant_update.ps1 -Environment [production|students] [-SkipBackup] [-ToVersion <version>]
```

**Fonctionnalités**:
- ✅ Sauvegarde pré-mise à jour (optionnelle)
- ✅ Pull de la dernière image Docker
- ✅ Redémarrage du service
- ✅ Validation post-update
- ✅ Rollback automatique en cas d'échec

---

### 7. **qdrant_verify.ps1** ⭐
**Remplace**: 1 script (verify_qdrant_config)

**Signature**:
```powershell
.\qdrant_verify.ps1 -Environment [production|students|all] [-Detailed]
```

**Fonctionnalités**:
- ✅ Vérification Docker disponible
- ✅ Vérification des volumes
- ✅ Vérification des fichiers de config
- ✅ Test de connectivité API
- ✅ Rapport détaillé (mode -Detailed)

---

## 🗄️ Scripts à Archiver (2)

Ces scripts sont conservés dans `myia_qdrant/scripts/archive/` pour référence historique :

1. **URGENT_data_recovery.ps1** 
   - Script d'urgence spécifique à un incident passé
   - Utile pour référence en cas de problème similaire

2. **test_production_with_wsl_binds.ps1**
   - Script de test WSL spécifique
   - Configuration déjà validée et en production

---

## 📋 Stratégie d'Implémentation

### Phase 1: Création des Scripts Unifiés ✅
1. ✅ Créer la structure dans `myia_qdrant/scripts/`
2. ✅ Implémenter `qdrant_backup.ps1` (script le plus critique)
3. ✅ Implémenter `qdrant_migrate.ps1`
4. ✅ Implémenter `qdrant_monitor.ps1`
5. ✅ Implémenter `qdrant_rollback.ps1`
6. ✅ Implémenter `qdrant_restart.ps1`
7. ✅ Implémenter `qdrant_update.ps1`
8. ✅ Implémenter `qdrant_verify.ps1`

### Phase 2: Tests de Validation ✅
1. ✅ Tester chaque script en mode `-DryRun` (si applicable)
2. ✅ Tester avec `-Environment production` (lecture seule)
3. ✅ Tester avec `-Environment students` (lecture seule)
4. ✅ Valider la compatibilité backward

### Phase 3: Migration et Nettoyage ✅
1. ✅ Créer `myia_qdrant/scripts/archive/`
2. ✅ Déplacer URGENT_data_recovery.ps1 et test_production_with_wsl_binds.ps1 vers archive/
3. ✅ Déplacer tous les scripts consolidés vers `myia_qdrant/scripts/`
4. ✅ Supprimer tous les scripts de `scripts/`
5. ✅ Vérifier que `scripts/` est VIDE

### Phase 4: Documentation ✅
1. ✅ Créer `myia_qdrant/scripts/README.md` avec guide d'utilisation
2. ✅ Documenter les changements dans `CONSOLIDATION_REPORT.md`
3. ✅ Mettre à jour la documentation principale du projet

---

## 🔑 Pattern de Configuration Unifiée

Tous les scripts unifiés utilisent ce pattern :

```powershell
# Configuration des environnements
$EnvironmentConfig = @{
    production = @{
        Port = 6333
        ContainerName = "qdrant_production"
        EnvFile = ".env"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ConfigFile = "config/production.optimized.yaml"
        ComposeFile = "docker-compose.production.optimized.yml"
        BackupDir = "backups/production"
    }
    students = @{
        Port = 6335
        ContainerName = "qdrant_students"
        EnvFile = ".env.students"
        ApiKeyVar = "QDRANT__SERVICE__API_KEY"
        ConfigFile = "config/students.optimized.yaml"
        ComposeFile = "docker-compose.students.optimized.yml"
        BackupDir = "backups/students"
    }
}

# Sélection de l'environnement
$config = $EnvironmentConfig[$Environment]
$QdrantUrl = "http://localhost:$($config.Port)"
```

---

## 📊 Bénéfices de la Consolidation

### Réduction de Code
- **Avant**: 15 scripts, ~145KB
- **Après**: 7 scripts, ~70KB
- **Gain**: ~50% de réduction, -8 fichiers

### Maintenabilité
- ✅ **DRY (Don't Repeat Yourself)**: Code partagé entre production/students
- ✅ **Single Source of Truth**: Un seul script par fonctionnalité
- ✅ **Évolutivité**: Ajout facile de nouveaux environnements (ex: staging)

### Utilisation
- ✅ **Simplicité**: Interface unifiée avec paramètre `-Environment`
- ✅ **Découvrabilité**: Moins de scripts = plus facile à trouver
- ✅ **Documentation**: Un seul endroit pour chaque type d'opération

### Testabilité
- ✅ **Tests centralisés**: Tester une fois = tester tous les environnements
- ✅ **Modes DryRun**: Validation sans risque
- ✅ **Validation**: Checks intégrés dans tous les scripts

---

## 🚀 Commandes de Migration Rapide

```powershell
# 1. Créer la structure
New-Item -ItemType Directory -Path "myia_qdrant/scripts" -Force
New-Item -ItemType Directory -Path "myia_qdrant/scripts/archive" -Force

# 2. [Implémenter les 7 scripts unifiés]

# 3. Archiver les scripts spécifiques
Move-Item "scripts/URGENT_data_recovery.ps1" "myia_qdrant/scripts/archive/"
Move-Item "scripts/test_production_with_wsl_binds.ps1" "myia_qdrant/scripts/archive/"

# 4. Déplacer tous les nouveaux scripts
Move-Item "myia_qdrant/scripts/*.ps1" "scripts/" -Force

# 5. Vérifier le résultat
Get-ChildItem "scripts/" -File | Measure-Object
# Devrait retourner Count: 0
```

---

## ✅ Checklist de Validation

- [ ] Tous les scripts unifiés créés et testés
- [ ] Scripts archivés déplacés dans archive/
- [ ] README.md créé dans myia_qdrant/scripts/
- [ ] Tests en DryRun réussis pour chaque script
- [ ] Documentation mise à jour
- [ ] scripts/ est VIDE (0 fichiers)
- [ ] CONSOLIDATION_REPORT.md créé avec résultats

---

**Prochaine étape**: Créer le fichier README.md avec guide d'utilisation complet des nouveaux scripts.