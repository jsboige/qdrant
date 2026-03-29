# Guide de Test d'Authentification Qwen3 v2.0
# Date: 2025-11-06
# Objectif: Guide complet pour tester le service Qwen3 avec authentification avancée

## 📋 Vue d'ensemble

Ce guide fournit des instructions détaillées pour tester le service Qwen3 8B avec authentification, en utilisant le script amélioré [`test_qwen3_connectivity_v2.ps1`](../../scripts/test/test_qwen3_connectivity_v2.ps1).

### 🎯 Objectifs des Tests

- **Valider l'authentification** avec différents scénarios
- **Vérifier la compatibilité** API OpenAI avec authentification
- **Tester la robustesse** du système face aux erreurs d'authentification
- **Générer des rapports** détaillés pour diagnostic
- **Préparer la migration** vers Qwen3 en toute sécurité

---

## 🔧 Prérequis

### Configuration Requise

1. **PowerShell 7.0+** installé
2. **Accès réseau** au service Qwen3
3. **Clé API Qwen3** valide
4. **Permissions d'exécution** pour les scripts PowerShell

### Variables d'Environnement (Optionnelles)

```powershell
# Configuration optionnelle
$env:QWEN3_ENDPOINT = "http://qwen3-server:11434"
$env:QWEN3_API_KEY = "votre-clé-api-qwen3"
```

---

## 🚀 Scénarios de Test

### Scénario 1: Test Basique avec Authentification

**Objectif**: Valider la connexion avec une clé API valide

```powershell
# Test basique avec clé API
.\myia_qdrant\scripts\test\test_qwen3_connectivity_v2.ps1 `
    -Qwen3Endpoint "http://qwen3-server:11434" `
    -ApiKey "votre-clé-api-qwen3" `
    -Verbose
```

**Résultats attendus**:
- ✅ Connectivité de base établie
- ✅ Clé API validée et format reconnu
- ✅ API OpenAI accessible avec authentification
- ✅ Embeddings générés (4096 dimensions)
- ✅ Performance acceptable (< 2s)

### Scénario 2: Test Complet avec Scénarios d'Authentification

**Objectif**: Tester tous les scénarios d'authentification

```powershell
# Test complet avec scénarios d'authentification
.\myia_qdrant\scripts\test\test_qwen3_connectivity_v2.ps1 `
    -Qwen3Endpoint "http://qwen3-server:11434" `
    -ApiKey "votre-clé-api-qwen3" `
    -TestAuthScenarios `
    -GenerateReport `
    -Verbose
```

**Scénarios testés automatiquement**:
1. **Clé manquante**: Vérification que l'authentification est requise
2. **Clé invalide**: Test avec une clé incorrecte
3. **Clé mal formatée**: Test avec une clé au format incorrect

### Scénario 3: Test sans Validation d'Authentification

**Objectif**: Test rapide en ignorant la validation de format

```powershell
# Test sans validation d'authentification
.\myia_qdrant\scripts\test\test_qwen3_connectivity_v2.ps1 `
    -Qwen3Endpoint "http://qwen3-server:11434" `
    -ApiKey "votre-clé-api-qwen3" `
    -SkipAuthValidation `
    -Verbose
```

### Scénario 4: Test avec Génération de Rapport

**Objectif**: Générer un rapport détaillé pour analyse

```powershell
# Test avec génération de rapport
.\myia_qdrant\scripts\test\test_qwen3_connectivity_v2.ps1 `
    -Qwen3Endpoint "http://qwen3-server:11434" `
    -ApiKey "votre-clé-api-qwen3" `
    -TestAuthScenarios `
    -GenerateReport
```

**Rapport généré**: `qwen3_test_report_YYYYMMDD_HHMMSS.md`

---

## 🔍 Formats de Clé API Supportés

Le script valide automatiquement les formats de clé suivants:

### 1. Format UUID
```
12345678-1234-1234-1234-123456789abc
```

### 2. Format OpenAI
```
sk-1234567890abcdef1234567890abcdef12345678
```

### 3. Format Token Alphanumérique
```
abcdefghijklmnopqrstuvwxyz1234567890
```

### 4. Format Spécifique Qwen3
```
qwen3-abcdef1234567890abcdef1234567890abcdef
```

---

## 📊 Interprétation des Résultats

### Codes de Sortie

| Code | Signification | Action |
|------|---------------|--------|
| 0 | Succès complet | Le service est prêt pour la production |
| 1 | Échec connectivité | Vérifier l'URL et la connectivité réseau |
| 2 | Échec API OpenAI | Vérifier la compatibilité API |
| 3 | Échec tests | Vérifier la clé API et les permissions |
| 99 | Erreur script | Contacter le support technique |

### Messages d'Erreur Courants

#### Erreur 401: Non autorisé
```
❌ Erreur 401: Non autorisé - Clé API invalide
💡 Vérifier que la clé API est correcte et active
```

**Actions**:
- Vérifier la clé API fournie
- Confirmer que la clé n'est pas expirée
- Vérifier les permissions de la clé

#### Erreur 403: Accès interdit
```
❌ Erreur 403: Accès interdit - Permissions insuffisantes
💡 Vérifier que la clé API a les permissions nécessaires
```

**Actions**:
- Vérifier les permissions associées à la clé
- Contacter l'administrateur pour étendre les permissions
- Confirmer que la clé permet l'accès aux embeddings

#### Erreur 429: Trop de requêtes
```
❌ Erreur 429: Trop de requêtes - Rate limiting
💡 Attendre avant de réessayer ou vérifier les limites de taux
```

**Actions**:
- Attendre avant de relancer les tests
- Vérifier les limites de taux du service
- Implémenter un backoff exponentiel en production

---

## 🛠️ Dépannage Avancé

### Problème: Connectivité de base échouée

**Symptômes**:
```
❌ Erreur de connexion: Unable to connect to the remote server
```

**Diagnostic**:
```powershell
# Test de connectivité réseau
Test-NetConnection -ComputerName "qwen3-server" -Port 11434

# Test avec curl
curl -I http://qwen3-server:11434
```

**Solutions**:
1. Vérifier que le service Qwen3 est démarré
2. Confirmer la configuration réseau
3. Vérifier les firewall et règles de sécurité

### Problème: Format de clé non reconnu

**Symptômes**:
```
❌ Clé API invalide: Format de clé API non reconnu
💡 Suggestion: Vérifier que la clé API est correcte
```

**Diagnostic**:
```powershell
# Test manuel du format
$apiKey = "votre-clé"
if ($apiKey -match '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {
    Write-Host "Format UUID valide"
} else {
    Write-Host "Format non reconnu"
}
```

**Solutions**:
1. Obtenir une nouvelle clé API au format correct
2. Contacter l'administrateur du service Qwen3
3. Vérifier la documentation du format attendu

### Problème: Dimensions incorrectes

**Symptômes**:
```
❌ Dimensions incorrectes (attendu: 4096, reçu: 1536)
```

**Diagnostic**:
```powershell
# Test direct de l'API
$headers = @{ "Authorization" = "Bearer votre-clé" }
$body = @{ "input" = "test"; "model" = "qwen3:8b" } | ConvertTo-Json
$response = Invoke-RestMethod -Uri "http://qwen3-server:11434/v1/embeddings" -Method Post -Headers $headers -Body $body
$response.data[0].embedding.Count
```

**Solutions**:
1. Vérifier que le modèle utilisé est bien `qwen3:8b`
2. Confirmer la configuration du service Qwen3
3. Mettre à jour le modèle dans les applications clientes

---

## 📈 Critères de Validation

### Validation pour Production

Le service Qwen3 est prêt pour la production si :

✅ **Connectivité**: Test de connectivité réussi  
✅ **Authentification**: Clé API validée et scénarios passés  
✅ **API OpenAI**: Compatibilité confirmée  
✅ **Dimensions**: 4096 dimensions générées  
✅ **Performance**: Temps de réponse < 2s  
✅ **Stabilité**: Tests répétés cohérents  

### Validation pour Développement

Pour un environnement de développement :

✅ **Connectivité**: Test de connectivité réussi  
✅ **Authentification**: Clé API fonctionnelle  
✅ **API OpenAI**: Compatibilité de base  
⚠️ **Performance**: Temps de réponse < 5s acceptable  

---

## 🔄 Automatisation des Tests

### Script de Test Automatisé

```powershell
# test_qwen3_automated.ps1
param(
    [string]$Endpoint = "http://qwen3-server:11434",
    [string]$ApiKey = $env:QWEN3_API_KEY
)

Write-Host "🚀 Lancement des tests automatisés Qwen3" -ForegroundColor Cyan

# Test 1: Validation quotidienne
Write-Host "📅 Test de validation quotidienne" -ForegroundColor Yellow
$result1 = .\myia_qdrant\scripts\test\test_qwen3_connectivity_v2.ps1 `
    -Qwen3Endpoint $Endpoint `
    -ApiKey $ApiKey `
    -GenerateReport

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Validation quotidienne réussie" -ForegroundColor Green
} else {
    Write-Host "❌ Validation quotidienne échouée" -ForegroundColor Red
    # Envoyer une alerte
    Send-MailMessage -To "admin@company.com" -Subject "Alerte Qwen3" -Body "Tests échoués"
}

# Test 2: Test de charge (optionnel)
Write-Host "⚡ Test de charge" -ForegroundColor Yellow
for ($i = 1; $i -le 10; $i++) {
    Write-Host "Test $i/10"
    .\myia_qdrant\scripts\test\test_qwen3_connectivity_v2.ps1 `
        -Qwen3Endpoint $Endpoint `
        -ApiKey $ApiKey `
        -SkipAuthValidation
}
```

### Intégration CI/CD

```yaml
# .github/workflows/qwen3-test.yml
name: Test Qwen3 Authentication

on:
  schedule:
    - cron: '0 6 * * *'  # Tous les jours à 6h
  workflow_dispatch:

jobs:
  test-qwen3:
    runs-on: windows-latest
    steps:
    - uses: actions/checkout@v2
    
    - name: Test Qwen3 Authentication
      run: |
        .\myia_qdrant\scripts\test\test_qwen3_connectivity_v2.ps1 `
          -Qwen3Endpoint "${{ secrets.QWEN3_ENDPOINT }}" `
          -ApiKey "${{ secrets.QWEN3_API_KEY }}" `
          -TestAuthScenarios `
          -GenerateReport
      shell: pwsh
    
    - name: Upload Test Report
      uses: actions/upload-artifact@v2
      with:
        name: qwen3-test-report
        path: qwen3_test_report_*.md
```

---

## 📚 Références

### Documentation Connexe

- [`VALIDATION_CONNEXION_QWEN3_ET_PLAN_MIGRATION.md`](../migration/VALIDATION_CONNEXION_QWEN3_ET_PLAN_MIGRATION.md) - Plan de migration complet
- [`PLAN_MIGRATION_QWEN3_4096_DIMENSIONS.md`](../migration/PLAN_MIGRATION_QWEN3_4096_DIMENSIONS.md) - Plan technique détaillé
- [`RUNBOOK_QDRANT.md`](../operations/RUNBOOK_QDRANT.md) - Guide d'exploitation Qdrant

### Scripts Connexes

- [`test_qwen3_connectivity.ps1`](../../scripts/test/test_qwen3_connectivity.ps1) - Version originale du script
- [`analyze_migration_impact_1536_to_4096.ps1`](../../scripts/analysis/analyze_migration_impact_1536_to_4096.ps1) - Analyse d'impact migration
- [`migrate_collection_to_4096.ps1`](../../scripts/migration/migrate_collection_to_4096.ps1) - Script de migration

### Support

En cas de problème avec les tests d'authentification :

1. **Consulter les logs** du service Qwen3
2. **Vérifier le rapport** généré par le script
3. **Contacter l'administrateur** système
4. **Créer un ticket** avec les détails de l'erreur

---

**Version**: 2.0  
**Dernière mise à jour**: 2025-11-06  
**Auteur**: Équipe MyIA  
**Statut**: ✅ **PRÊT POUR UTILISATION**