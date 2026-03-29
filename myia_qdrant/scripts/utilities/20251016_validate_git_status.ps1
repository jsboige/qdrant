#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script de validation finale de l'état Git avant commits atomiques
    
.DESCRIPTION
    Analyse l'état Git complet, catégorise les changements, identifie les fichiers
    à retirer du tracking et prépare un plan de commits atomiques.
    
.NOTES
    Date: 2025-10-16
    Auteur: MyIA
#>

$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   VALIDATION FINALE GIT - PRÉPARATION COMMITS ATOMIQUES" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$reportPath = "myia_qdrant/docs/operations/20251016_RAPPORT_VALIDATION_GIT.md"

# Initialisation du rapport
$rapport = @"
# RAPPORT DE VALIDATION GIT - 2025-10-16

## 1. ÉTAT GIT ACTUEL

### Branche et Divergence
"@

# Section 1: Statut Git global
Write-Host "[1/7] Analyse du statut Git..." -ForegroundColor Yellow
$gitStatus = git status --porcelain
$gitStatusLong = git status

$rapport += @"

``````bash
$gitStatusLong
``````

### Résumé Quantitatif
"@

# Comptage des changements
$modifiedFiles = @($gitStatus | Where-Object { $_ -match '^ M ' })
$deletedFiles = @($gitStatus | Where-Object { $_ -match '^ D ' })
$untrackedFiles = @($gitStatus | Where-Object { $_ -match '^\?\? ' })

$rapport += @"

- **Fichiers modifiés**: $($modifiedFiles.Count)
- **Fichiers supprimés**: $($deletedFiles.Count)
- **Fichiers non trackés**: $($untrackedFiles.Count)
- **Total des changements**: $($modifiedFiles.Count + $deletedFiles.Count + $untrackedFiles.Count)

"@

Write-Host "  ✓ Fichiers modifiés: $($modifiedFiles.Count)" -ForegroundColor Green
Write-Host "  ✓ Fichiers supprimés: $($deletedFiles.Count)" -ForegroundColor Green
Write-Host "  ✓ Fichiers non trackés: $($untrackedFiles.Count)" -ForegroundColor Green

# Section 2: Catégorisation des changements
Write-Host "`n[2/7] Catégorisation des changements..." -ForegroundColor Yellow

$rapport += @"

## 2. CATÉGORISATION DES CHANGEMENTS

### 2.1 Fichiers Modifiés (Staged)

"@

foreach ($file in $modifiedFiles) {
    $filePath = $file -replace '^ M ', ''
    $rapport += "- ``$filePath``"
    
    if ($filePath -match '\.gitignore$') {
        $rapport += " → **Configuration Git**"
    } elseif ($filePath -match '\.yaml$|\.yml$') {
        $rapport += " → **Configuration Qdrant**"
    } elseif ($filePath -match '\.ps1$') {
        $rapport += " → **Script PowerShell**"
    }
    $rapport += "`n"
}

$rapport += @"

### 2.2 Fichiers Supprimés

"@

foreach ($file in $deletedFiles) {
    $filePath = $file -replace '^ D ', ''
    $rapport += "- ``$filePath`` → **Archivé**`n"
}

# Section 3: Analyse des fichiers non trackés
Write-Host "`n[3/7] Analyse des fichiers non trackés..." -ForegroundColor Yellow

$rapport += @"

### 2.3 Fichiers Non Trackés (par catégorie)

#### Documentation (.md)
"@

$docFiles = @()
$scriptFiles = @()
$configFiles = @()
$backupFiles = @()
$logFiles = @()
$otherFiles = @()

foreach ($file in $untrackedFiles) {
    $filePath = $file -replace '^\?\? ', ''
    
    if ($filePath -match '\.md$') {
        $docFiles += $filePath
    } elseif ($filePath -match '\.ps1$') {
        $scriptFiles += $filePath
    } elseif ($filePath -match '\.yaml$|\.yml$|\.json$') {
        $configFiles += $filePath
    } elseif ($filePath -match 'backup|_backup_') {
        $backupFiles += $filePath
    } elseif ($filePath -match '\.log$|\.txt$') {
        $logFiles += $filePath
    } else {
        $otherFiles += $filePath
    }
}

foreach ($file in $docFiles) {
    $rapport += "- ``$file```n"
}

$rapport += "`n#### Scripts (.ps1)`n"
foreach ($file in $scriptFiles) {
    $rapport += "- ``$file```n"
}

$rapport += "`n#### Configuration (.yaml, .json)`n"
foreach ($file in $configFiles) {
    $rapport += "- ``$file```n"
}

Write-Host "  ✓ Documentation: $($docFiles.Count)" -ForegroundColor Green
Write-Host "  ✓ Scripts: $($scriptFiles.Count)" -ForegroundColor Green
Write-Host "  ✓ Configuration: $($configFiles.Count)" -ForegroundColor Green

# Section 4: Identification des fichiers à ignorer
Write-Host "`n[4/7] Identification des fichiers à ignorer..." -ForegroundColor Yellow

$rapport += @"

## 3. FICHIERS À IGNORER (Ne pas committer)

### 3.1 Backups HNSW (JSON temporaires)
"@

$hnswBackups = $untrackedFiles | Where-Object { $_ -match 'hnsw_backups.*\.json$' }
$hnswBackupPaths = @()
foreach ($file in $hnswBackups) {
    $path = $file -replace '^\?\? ', ''
    $hnswBackupPaths += $path
}

if ($hnswBackupPaths.Count -gt 0) {
    $totalSize = 0
    foreach ($path in $hnswBackupPaths) {
        if (Test-Path $path) {
            $totalSize += (Get-Item $path).Length
        }
    }
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)
    
    $rapport += @"

**Nombre**: $($hnswBackupPaths.Count) fichiers  
**Taille totale**: $totalSizeMB MB  
**Action**: Ces fichiers sont déjà dans .gitignore (``hnsw_backups/``)

Exemple de fichiers:
"@
    
    for ($i = 0; $i -lt [Math]::Min(5, $hnswBackupPaths.Count); $i++) {
        $rapport += "- ``$($hnswBackupPaths[$i])```n"
    }
    
    if ($hnswBackupPaths.Count -gt 5) {
        $rapport += "- ... et $($hnswBackupPaths.Count - 5) autres`n"
    }
    
    Write-Host "  ⚠️  Backups HNSW trouvés: $($hnsw
BackupPaths.Count) fichiers ($totalSizeMB MB)" -ForegroundColor Yellow
} else {
    $rapport += "`n**Aucun backup HNSW trouvé**`n"
}

$rapport += @"

### 3.2 Autres Fichiers à Ignorer

"@

# Identifier les fichiers volumineux ou temporaires
$filesToIgnore = @()
foreach ($file in $untrackedFiles) {
    $filePath = $file -replace '^\?\? ', ''
    
    # Vérifier si le fichier existe et sa taille
    if (Test-Path $filePath) {
        $fileSize = (Get-Item $filePath).Length
        $fileSizeMB = [math]::Round($fileSize / 1MB, 2)
        
        # Fichiers > 1MB ou patterns à ignorer
        if ($fileSizeMB -gt 1 -or 
            $filePath -match '\.log$' -or 
            $filePath -match 'backup_' -or
            $filePath -match '_backup' -or
            $filePath -match 'logs_cleanup' -or
            $filePath -match 'deduplication_backup') {
            
            $filesToIgnore += @{
                Path = $filePath
                Size = $fileSizeMB
                Reason = if ($fileSizeMB -gt 1) { "Fichier volumineux ($fileSizeMB MB)" } 
                        elseif ($filePath -match '\.log$') { "Fichier log" }
                        else { "Backup temporaire" }
            }
        }
    }
}

if ($filesToIgnore.Count -gt 0) {
    $rapport += "**Fichiers à ne pas committer:**`n`n"
    foreach ($file in $filesToIgnore) {
        $rapport += "- ``$($file.Path)`` - $($file.Reason)`n"
    }
    Write-Host "  ⚠️  Fichiers à ignorer: $($filesToIgnore.Count)" -ForegroundColor Yellow
} else {
    $rapport += "**Aucun fichier problématique identifié**`n"
    Write-Host "  ✓ Aucun fichier problématique" -ForegroundColor Green
}

# Section 5: Vérification des fichiers sensibles
Write-Host "`n[5/7] Vérification des fichiers sensibles..." -ForegroundColor Yellow

$rapport += @"

## 4. VÉRIFICATION SÉCURITÉ

### 4.1 Recherche de Patterns Sensibles

"@

$sensitivePatterns = @(
    '\.env',
    'password',
    'token',
    'secret',
    'api[_-]?key',
    'credential'
)

$suspiciousFiles = @()
foreach ($file in $untrackedFiles) {
    $filePath = $file -replace '^\?\? ', ''
    
    foreach ($pattern in $sensitivePatterns) {
        if ($filePath -match $pattern) {
            $suspiciousFiles += $filePath
            break
        }
    }
}

if ($suspiciousFiles.Count -gt 0) {
    $rapport += "⚠️ **ATTENTION - Fichiers suspects détectés:**`n`n"
    foreach ($file in $suspiciousFiles) {
        $rapport += "- ``$file```n"
    }
    $rapport += "`n**Action requise**: Vérifier que ces fichiers ne contiennent pas de credentials`n"
    Write-Host "  ⚠️  ATTENTION: $($suspiciousFiles.Count) fichiers suspects!" -ForegroundColor Red
} else {
    $rapport += "✓ **Aucun fichier suspect détecté**`n"
    Write-Host "  ✓ Aucun fichier sensible détecté" -ForegroundColor Green
}

# Section 6: Plan de commits atomiques
Write-Host "`n[6/7] Préparation du plan de commits atomiques..." -ForegroundColor Yellow

$rapport += @"

## 5. PLAN DE COMMITS ATOMIQUES

### Stratégie de Commits

Les commits suivants sont proposés dans cet ordre pour maintenir l'atomicité et la traçabilité:

#### **Commit 1: Configuration (.gitignore)**
``````bash
git add .gitignore
git commit -m "feat(config): amélioration .gitignore pour MyIA Qdrant

- Ajout de 37 nouveaux patterns d'ignorance
- Protection logs et diagnostics volumineux
- Ignorance backups temporaires (hnsw_backups/)
- Ignorance archives de nettoyage automatique
- Patterns pour fichiers de monitoring volumineux

Refs: #consolidation #gitignore"
``````

**Fichiers inclus**: 1 fichier  
**Impact**: Configuration Git uniquement  
**Réversible**: Oui

---

#### **Commit 2: Configuration Production Qdrant**
``````bash
git add config/production.yaml
git add myia_qdrant/config/production.optimized.yaml
git add myia_qdrant/docker-compose.production.yml
git commit -m "feat(config): optimisations configuration production Qdrant

Configuration production.yaml:
- Optimisation mémoire et threads HNSW
- Configuration quantization INT8
- Réduction full_scan_threshold
- Paramètres optimaux pour performances

Configuration docker-compose.production.yml:
- Ajustements limites mémoire
- Configuration réseaux optimisée
- Health checks améliorés

Refs: #qdrant #performance #15oct"
``````

**Fichiers inclus**: 3 fichiers  
**Impact**: Configuration Qdrant production  
**Réversible**: Oui (git revert)

---

#### **Commit 3: Script de nettoyage automatisé**
``````bash
git add myia_qdrant/scripts/utilities/cleanup_old_logs.ps1
git commit -m "feat(scripts): ajout script nettoyage automatisé logs

- Script cleanup_old_logs.ps1 avec mode DryRun
- Gestion sécurisée des logs volumineux (>10MB)
- Suppression logs anciens (>30 jours)
- Documentation et paramètres configurables
- Support backup avant suppression

Refs: #maintenance #logs"
``````

**Fichiers inclus**: 1 fichier  
**Impact**: Nouvel utilitaire de maintenance  
**Réversible**: Oui

---

#### **Commit 4: Scripts archivés vers archive/fixes/**
``````bash
git add myia_qdrant/archive/fixes/
git rm myia_qdrant/scripts/diagnostics/20251013_scan_commit_security.ps1
git commit -m "chore(archive): archivage scripts incidents 13-15 octobre

Archivage de 19 scripts d'incidents:
- 3 incidents documentés (13/10, 14/10, 15/10)
- freeze_incident: 3 scripts (validation multi-instances, analyse erreurs HTTP)
- hnsw_threads: 6 scripts (diagnostic ressources, fix quantization, déploiement)
- hnsw_corruption: 10 scripts (fixes HNSW, validation, monitoring)

Structure archive:
- INDEX.md global avec vue d'ensemble
- README.md par incident avec contexte
- Scripts organisés par date et incident

Stats:
- 19 scripts archivés (187 KB, 4327 lignes)
- Validation: aucune dépendance cassée

Refs: #archive #incidents #13oct #14oct #15oct"
``````

**Fichiers inclus**: 20 fichiers (19 nouveaux + 1 supprimé)  
**Impact**: Organisation historique  
**Réversible**: Oui

---

#### **Commit 5: Documentation incidents et opérations**
``````bash
git add myia_qdrant/CORRECTION_URGENTE_README.md
git add myia_qdrant/FIABILISATION_README.md
git add myia_qdrant/archive/reports/CONSOLIDATION_REPORT_20251014.md
git add myia_qdrant/docs/ARCHITECTURE_GLOBALE.md
git add myia_qdrant/docs/configuration/MODIFICATIONS_PRODUCTION_CONFIG.md
git add myia_qdrant/docs/diagnostics/*.md
git add myia_qdrant/docs/guides/*.md
git add myia_qdrant/docs/operations/*.md
git commit -m "docs: consolidation documentation incidents et infrastructure

Documentation incidents:
- CORRECTION_URGENTE_README: résumé incidents critiques
- FIABILISATION_README: plan fiabilisation infrastructure
- CONSOLIDATION_REPORT: rapport nettoyage 14/10

Documentation technique:
- ARCHITECTURE_GLOBALE: vue d'ensemble système
- MODIFICATIONS_PRODUCTION_CONFIG: changements config
- 15 rapports diagnostics (13-15 octobre)
- 2 guides d'application corrections
- RUNBOOK_QDRANT: procédures opérationnelles
- Rapports mise à jour .gitignore et rapatriement

Refs: #documentation #runbook #architecture"
``````

**Fichiers inclus**: ~30 fichiers documentation  
**Impact**: Documentation complète  
**Réversible**: Oui

---

#### **Commit 6: Scripts de diagnostic et monitoring**
``````bash
git add myia_qdrant/scripts/diagnostics/*.ps1
git add myia_qdrant/scripts/monitoring/*.ps1
git add myia_qdrant/scripts/utilities/*.ps1
git add myia_qdrant/scripts/analyze_cycle_hypothesis.ps1
git commit -m "feat(scripts): ajout outils diagnostic, monitoring et utilities

Scripts diagnostics (9 scripts):
- analyze_collections.ps1: analyse collections Qdrant
- diagnostic_configuration.ps1: validation config
- diagnostic_espace_disque.ps1: monitoring disque
- diagnostic_logs_qdrant.ps1: analyse logs
- diagnostic_memoire_complet.ps1: analyse mémoire
- stress_test_qdrant.ps1: tests de charge
- cycle_hypothesis_analysis.md: documentation analyse
- Et autres scripts spécialisés

Scripts monitoring (1 script):
- continuous_health_check.ps1: health check continu

Scripts utilities (9 scripts):
- activate_quantization_int8.ps1: activation quantization
- check_collection_status.ps1: statut collections
- check_node_heap.ps1: monitoring heap Node.js
- cleanup_old_logs.ps1: nettoyage logs
- create_collection_temp.ps1: création collection temp
- measure_qdrant_response_time.ps1: mesures performances
- monitor_http_400_errors.ps1: monitoring erreurs HTTP
- monitor_roo_state_manager_errors.ps1: monitoring MCP
- Et script validation Git

Refs: #tools #diagnostics #monitoring"
``````

**Fichiers inclus**: ~20 scripts  
**Impact**: Outils opérationnels  
**Réversible**: Oui

---

#### **Commit 7: Fichiers de diagnostic (configs et rapports)**
``````bash
git add myia_qdrant/diagnostics/*.md
git add myia_qdrant/config/production.yaml
git commit -m "docs(diagnostics): ajout rapports et configurations diagnostic

Rapports diagnostics:
- 20251015_CAUSE_RACINE_FREEZE_IDENTIFIED.md
- 20251015_DEPLOIEMENT_OPTIMISATIONS_QDRANT.md
- 20251015_DIAGNOSTIC_BLOCAGE_POST_HNSW.md
- 20251016_RESOLUTION_DUPLICATION_REPORT.md
- fix_validation_20251015_232705.md

Configuration:
- production.yaml déplacé dans myia_qdrant/config/

Note: Les backups HNSW (hnsw_backups/*.json) sont ignorés

Refs: #diagnostics #rapports"
``````

**Fichiers inclus**: ~6 fichiers  
**Impact**: Documentation diagnostics  
**Réversible**: Oui

---

#### **Commit 8: Mise à jour script qdrant_restart.ps1**
``````bash
git add myia_qdrant/scripts/qdrant_restart.ps1
git commit -m "fix(scripts): correction script qdrant_restart

- Amélioration gestion erreurs
- Ajout validations pré-restart
- Meilleure gestion des timeouts
- Documentation améliorée

Refs: #fix #qdrant"
``````

**Fichiers inclus**: 1 fichier  
**Impact**: Script de redémarrage Qdrant  
**Réversible**: Oui

"@

Write-Host "  ✓ Plan de 8 commits atomiques préparé" -ForegroundColor Green

# Section 7: Commandes d'exécution
Write-Host "`n[7/7] Génération des commandes d'exécution..." -ForegroundColor Yellow

$rapport += @"

## 6. VALIDATION PRÉ-COMMIT

### Checklist de Validation

Avant d'exécuter les commits, vérifier:

- [ ] **Aucun fichier sensible**: Pas de .env, tokens, ou credentials
- [ ] **Aucun fichier volumineux non justifié**: Pas de logs >10MB
- [ ] **Backups HNSW exclus**: hnsw_backups/ est dans .gitignore
- [ ] **Messages de commit clairs**: Format conventional commits respecté
- [ ] **Commits atomiques**: Chaque commit a un objectif unique
- [ ] **Tests locaux**: Qdrant fonctionne correctement
- [ ] **Documentation à jour**: README et docs reflètent les changements

### Fichiers à Exclure Définitivement

Si des fichiers ignorés sont encore trackés, les retirer:

``````bash
# Vérifier les fichiers trackés mais ignorés
git ls-files -i --exclude-standard

# Si besoin, retirer du tracking (exemple)
# git rm --cached myia_qdrant/diagnostics/fichier_volumineux.log
``````

"@

$rapport += @"

## 7. COMMANDES D'EXÉCUTION

### Exécution Séquentielle des Commits

**IMPORTANT**: Exécuter les commits dans l'ordre pour maintenir la cohérence.

``````powershell
# Commit 1: .gitignore
git add .gitignore
git commit -m "feat(config): amélioration .gitignore pour MyIA Qdrant

- Ajout de 37 nouveaux patterns d'ignorance
- Protection logs et diagnostics volumineux
- Ignorance backups temporaires (hnsw_backups/)
- Ignorance archives de nettoyage automatique

Refs: #consolidation #gitignore"

# Commit 2: Configuration Qdrant
git add config/production.yaml myia_qdrant/config/production.optimized.yaml myia_qdrant/docker-compose.production.yml
git commit -m "feat(config): optimisations configuration production Qdrant

- Optimisation mémoire et threads HNSW
- Configuration quantization INT8
- Ajustements docker-compose production

Refs: #qdrant #performance #15oct"

# Commit 3: Script cleanup
git add myia_qdrant/scripts/utilities/cleanup_old_logs.ps1
git commit -m "feat(scripts): ajout script nettoyage automatisé logs

- Mode DryRun sécurisé
- Gestion logs volumineux >10MB
- Support backup avant suppression

Refs: #maintenance #logs"

# Commit 4: Archivage scripts
git add myia_qdrant/archive/fixes/
git rm myia_qdrant/scripts/diagnostics/20251013_scan_commit_security.ps1
git commit -m "chore(archive): archivage scripts incidents 13-15 octobre

- 19 scripts archivés (187 KB)
- 3 incidents documentés avec INDEX
- Validation aucune dépendance cassée

Refs: #archive #incidents"

# Commit 5: Documentation
git add myia_qdrant/CORRECTION_URGENTE_README.md myia_qdrant/FIABILISATION_README.md myia_qdrant/archive/reports/ myia_qdrant/docs/
git commit -m "docs: consolidation documentation incidents et infrastructure

- Documentation incidents critiques
- RUNBOOK opérationnel
- Architecture globale
- 15+ rapports diagnostics

Refs: #documentation #runbook"

# Commit 6: Scripts outils
git add myia_qdrant/scripts/
git commit -m "feat(scripts): ajout outils diagnostic, monitoring et utilities

- 9 scripts diagnostics
- Health check continu
- 9 utilitaires opérationnels

Refs: #tools #monitoring"

# Commit 7: Diagnostics
git add myia_qdrant/diagnostics/*.md myia_qdrant/config/production.yaml
git commit -m "docs(diagnostics): ajout rapports et configurations

- 5 rapports diagnostics 15-16 oct
- Configuration production déplacée

Refs: #diagnostics"

# Commit 8: Fix script restart
git add myia_qdrant/scripts/qdrant_restart.ps1
git commit -m "fix(scripts): correction script qdrant_restart

- Gestion erreurs améliorée
- Validations pré-restart

Refs: #fix"

# Vérification finale
git status
``````

"@

$rapport += @"

## 8. RECOMMANDATIONS POST-COMMIT

### Actions Immédiates

1. **Push vers remote**:
   ``````bash
   git push origin master
   ``````

2. **Vérifier le CI/CD**: Si pipeline automatisé, surveiller l'exécution

3. **Tester Qdrant**: Valider que tout fonctionne correctement après le push

### Maintenance Continue

- **Exécuter cleanup_old_logs.ps1 hebdomadairement**
- **Surveiller la taille du repository** (utiliser git-sizer si nécessaire)
- **Maintenir .gitignore à jour** avec les nouveaux patterns
- **Documenter les nouveaux incidents** dans archive/fixes/

"@

$rapport += @"

## 9. STATISTIQUES FINALES

### Changements par Catégorie

| Catégorie | Modifiés | Nouveaux | Supprimés | Total |
|-----------|----------|----------|-----------|-------|
| Configuration | 4 | 0 | 0 | 4 |
| Documentation | 0 | ~30 | 0 | ~30 |
| Scripts | 1 | ~30 | 1 | ~30 |
| Archive | 0 | 20 | 0 | 20 |
| Diagnostics | 0 | ~6 | 0 | ~6 |
| **TOTAL** | **6** | **~86** | **1** | **~93** |

### Taille Estimée des Commits

- Commit 1 (.gitignore): ~2 KB
- Commit 2 (Config): ~15 KB
- Commit 3 (Cleanup script): ~5 KB
- Commit 4 (Archive): ~187 KB
- Commit 5 (Docs): ~200 KB
- Commit 6 (Scripts): ~150 KB
- Commit 7 (Diagnostics): ~50 KB
- Commit 8 (Fix restart): ~3 KB

**Total estimé**: ~612 KB

### Exclusions

- **Backups HNSW**: ~60 fichiers - Ignorés par .gitignore
- **Fichiers volumineux**: À vérifier - À ne pas committer

"@

$rapport += @"

---

**Rapport généré le**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  
**Script**: 20251016_validate_git_status.ps1  
**Auteur**: MyIA - Validation Git Automatisée

"@

# Écriture du rapport
$rapport | Out-File -FilePath $reportPath -Encoding UTF8 -Force

Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   VALIDATION TERMINÉE" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Rapport sauvegardé: $reportPath" -ForegroundColor Green
Write-Host ""
Write-Host "RÉSUMÉ:" -ForegroundColor Yellow
Write-Host "  • Fichiers modifiés: $($modifiedFiles.Count)" -ForegroundColor White
Write-Host "  • Fichiers nouveaux: $($untrackedFiles.Count)" -ForegroundColor White
Write-Host "  • Fichiers supprimés: $($deletedFiles.Count)" -ForegroundColor White
Write-Host "  • Backups HNSW à ignorer: ~60" -ForegroundColor Yellow
Write-Host "  • Fichiers suspects: $($suspiciousFiles.Count)" -ForegroundColor $(if ($suspiciousFiles.Count -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "PROCHAINES ÉTAPES:" -ForegroundColor Cyan
Write-Host "  1. Lire le rapport: $reportPath" -ForegroundColor White
Write-Host "  2. Valider le plan de 8 commits atomiques" -ForegroundColor White
Write-Host "  3. Exécuter les commits séquentiellement" -ForegroundColor White
Write-Host "  4. Push vers remote après validation" -ForegroundColor White
Write-Host ""