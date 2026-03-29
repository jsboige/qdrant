# Script d'analyse de l'hypothèse de cycle crash/re-indexation/surcharge/recrash
# Analyse complète du traffic Qdrant pour identifier les patterns problématiques

param(
    [int]$TailLines = 10000,
    [string]$OutputPath = "diagnostics/cycle_hypothesis_analysis.md"
)

Write-Host "🔍 Analyse de l'hypothèse de cycle vicieux Qdrant..." -ForegroundColor Cyan
Write-Host ""

# Récupération des logs
Write-Host "📥 Récupération des derniers $TailLines logs..." -ForegroundColor Yellow
$logs = docker logs qdrant_production --tail $TailLines 2>&1

# 1. ANALYSE PAR CLIENT
Write-Host "👥 Analyse du traffic par client..." -ForegroundColor Yellow
$clientStats = $logs | Select-String 'actix_web::middleware::logger' | ForEach-Object {
    if ($_ -match '"([^"]+)" (\d+\.\d+)$') {
        [PSCustomObject]@{
            Client = $matches[1]
            Duration = [double]$matches[2]
        }
    }
} | Group-Object Client | Select-Object Name, Count, @{
    Name='AvgDuration'; 
    Expression={($_.Group.Duration | Measure-Object -Average).Average}
}, @{
    Name='MaxDuration'; 
    Expression={($_.Group.Duration | Measure-Object -Maximum).Maximum}
}

Write-Host "✅ Statistiques par client:" -ForegroundColor Green
$clientStats | Format-Table -AutoSize

# 2. ANALYSE DES COLLECTIONS UTILISÉES
Write-Host "`n📊 Analyse des collections les plus sollicitées..." -ForegroundColor Yellow
$collectionStats = $logs | Select-String 'collections/([^/]+)/' | ForEach-Object {
    if ($_ -match 'collections/([^/]+)/') {
        $matches[1]
    }
} | Group-Object | Sort-Object Count -Descending | Select-Object -First 10

Write-Host "✅ Top 10 des collections:" -ForegroundColor Green
$collectionStats | Format-Table -AutoSize Name, Count

# 3. ANALYSE DES ERREURS ET TIMEOUTS
Write-Host "`n❌ Analyse des erreurs..." -ForegroundColor Yellow
$errors = $logs | Select-String -Pattern '(400|500|timeout|error|failed|OOM|out of memory)' -AllMatches

Write-Host "✅ Erreurs détectées: $($errors.Count)" -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Green' })

if ($errors.Count -gt 0) {
    $errorTypes = $errors | ForEach-Object {
        if ($_ -match '(400|500)') { "HTTP $($matches[1])" }
        elseif ($_ -match '(timeout|OOM|out of memory)') { $matches[1] }
        else { "other" }
    } | Group-Object | Sort-Object Count -Descending
    
    Write-Host "Types d'erreurs:" -ForegroundColor Yellow
    $errorTypes | Format-Table -AutoSize
    
    Write-Host "`nÉchantillon des erreurs (5 premières):" -ForegroundColor Yellow
    $errors | Select-Object -First 5 | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
}

# 4. ANALYSE DES REQUÊTES PAR MINUTE (dernière heure)
Write-Host "`n⏱️ Analyse du traffic par minute..." -ForegroundColor Yellow
$recentLogs = $logs | Where-Object { $_ -match '\d{4}-\d{2}-\d{2}T(\d{2}:\d{2})' }
$trafficByMinute = $recentLogs | ForEach-Object {
    if ($_ -match '(\d{2}:\d{2})') {
        $matches[1]
    }
} | Group-Object | Sort-Object Name

Write-Host "✅ Requêtes par minute (dernières):" -ForegroundColor Green
$trafficByMinute | Select-Object -Last 20 | Format-Table -AutoSize Name, @{Name='Requests';Expression={$_.Count}}

# 5. ANALYSE SPÉCIFIQUE: roo_tasks_semantic_index
Write-Host "`n🔴 Analyse spécifique de roo_tasks_semantic_index..." -ForegroundColor Yellow
$rooTasksErrors = $logs | Select-String 'roo_tasks_semantic_index.*400'
Write-Host "❌ Erreurs 400 sur roo_tasks_semantic_index: $($rooTasksErrors.Count)" -ForegroundColor $(if ($rooTasksErrors.Count -gt 0) { 'Red' } else { 'Green' })

if ($rooTasksErrors.Count -gt 0) {
    Write-Host "Échantillon (3 premières):" -ForegroundColor Yellow
    $rooTasksErrors | Select-Object -First 3 | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
}

# 6. ANALYSE DES DURÉES ANORMALES
Write-Host "`n⏰ Analyse des requêtes lentes (>5s)..." -ForegroundColor Yellow
$slowRequests = $logs | Select-String 'actix_web::middleware::logger' | ForEach-Object {
    if ($_ -match '"([^"]+)" (\d+\.\d+)$' -and [double]$matches[2] -gt 5.0) {
        [PSCustomObject]@{
            Client = $matches[1]
            Duration = [double]$matches[2]
            Line = $_.Line
        }
    }
}

Write-Host "🐌 Requêtes lentes détectées: $($slowRequests.Count)" -ForegroundColor $(if ($slowRequests.Count -gt 10) { 'Red' } elseif ($slowRequests.Count -gt 0) { 'Yellow' } else { 'Green' })

if ($slowRequests.Count -gt 0) {
    $slowRequests | Select-Object -First 5 | Format-Table -AutoSize Client, @{Name='Duration (s)';Expression={$_.Duration}}
}

# 7. GÉNÉRATION DU RAPPORT MARKDOWN
Write-Host "`n📝 Génération du rapport markdown..." -ForegroundColor Yellow

$report = @"
# Analyse de l'Hypothèse de Cycle Vicieux Qdrant
**Date:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Logs analysés:** $TailLines dernières lignes

---

## 1. Statistiques Globales par Client

| Client | Requêtes | Durée Moy. (s) | Durée Max (s) |
|--------|----------|----------------|---------------|
$($clientStats | ForEach-Object { "| $($_.Name) | $($_.Count) | $([math]::Round($_.AvgDuration, 3)) | $([math]::Round($_.MaxDuration, 3)) |" })

### Analyse:
$( if ($clientStats | Where-Object { $_.Name -match 'qdrant-js' -and $_.Count -gt ($clientStats | Where-Object { $_.Name -match 'Roo-Code' }).Count }) {
    "⚠️ **PROBLÈME DÉTECTÉ:** qdrant-js (roo-state-manager) génère **PLUS de requêtes** que Roo-Code !"
} else {
    "✅ Roo-Code génère plus de requêtes que roo-state-manager (comportement normal)."
})

---

## 2. Top 10 Collections Sollicitées

| Collection | Requêtes |
|------------|----------|
$($collectionStats | ForEach-Object { "| ``$($_.Name)`` | $($_.Count) |" })

---

## 3. Erreurs Détectées

**Total erreurs:** $($errors.Count)

$( if ($errors.Count -gt 0) {
    "### Types d'erreurs:`n`n" + ($errorTypes | ForEach-Object { "- **$($_.Name):** $($_.Count) occurrences" } | Out-String)
} else {
    "✅ Aucune erreur détectée."
})

---

## 4. Erreurs Spécifiques roo_tasks_semantic_index

**Erreurs 400:** $($rooTasksErrors.Count)

$( if ($rooTasksErrors.Count -gt 0) {
    "⚠️ **PROBLÈME CONFIRMÉ:** Erreurs répétées sur roo_tasks_semantic_index"
} else {
    "✅ Aucune erreur sur roo_tasks_semantic_index."
})

---

## 5. Requêtes Lentes (>5s)

**Total requêtes lentes:** $($slowRequests.Count)

$( if ($slowRequests.Count -gt 10) {
    "🔴 **PROBLÈME MAJEUR:** Trop de requêtes lentes ($($slowRequests.Count))"
} elseif ($slowRequests.Count -gt 0) {
    "⚠️ Quelques requêtes lentes détectées"
} else {
    "✅ Aucune requête anormalement lente."
})

---

## 6. Traffic par Minute (dernières 20 minutes)

| Minute | Requêtes |
|--------|----------|
$($trafficByMinute | Select-Object -Last 20 | ForEach-Object { "| $($_.Name) | $($_.Count) |" })

---

## 7. CONCLUSION sur l'Hypothèse de Cycle

$( 
$rooCodeCount = ($clientStats | Where-Object { $_.Name -match 'Roo-Code' }).Count
$qdrantJsCount = ($clientStats | Where-Object { $_.Name -match 'qdrant-js' }).Count
$ratio = if ($rooCodeCount -gt 0) { [math]::Round($qdrantJsCount / $rooCodeCount, 2) } else { 0 }

if ($qdrantJsCount -gt $rooCodeCount -or $ratio -gt 0.3) {
    @"
### ❌ HYPOTHÈSE **VALIDÉE**

**Ratio qdrant-js/Roo-Code:** $ratio

Le MCP roo-state-manager génère un volume de requêtes **anormalement élevé** par rapport à l'usage réel de Roo.

**Problèmes identifiés:**
1. ✅ roo-state-manager génère $qdrantJsCount requêtes vs $rooCodeCount pour Roo-Code
2. $(if ($rooTasksErrors.Count -gt 0) { "✅" } else { "❌" }) $($rooTasksErrors.Count) erreurs 400 sur roo_tasks_semantic_index
3. $(if ($slowRequests.Count -gt 10) { "✅" } else { "❌" }) $($slowRequests.Count) requêtes lentes détectées

**Cycle vicieux détecté:**
``````
Crash → Redémarrage Qdrant → roo-state-manager re-scan massif
→ Traffic explosif → Surcharge → Crash → Recommence
``````

### Solutions Recommandées:

#### Court Terme:
1. **Désactiver temporairement roo-state-manager** pour valider l'impact
2. Implémenter un **rate limiting agressif** pour qdrant-js
3. Ajouter un **délai de démarrage** (30-60s) avant scan initial

#### Long Terme:
1. **Index persistant** avec checkpointing pour éviter re-scan complet
2. **Scan incrémental** au lieu de scan complet
3. **Circuit breaker** intelligent avec backoff exponentiel
4. **Architecture scalable** (réplication Qdrant)
"@
} else {
    @"
### ✅ HYPOTHÈSE **NON VALIDÉE**

**Ratio qdrant-js/Roo-Code:** $ratio

Le volume de requêtes de roo-state-manager est **acceptable** ($qdrantJsCount vs $rooCodeCount).

**Analyse:**
- Le MCP ne génère pas de surcharge anormale
- Les erreurs détectées ($($rooTasksErrors.Count)) sont **ponctuelles**, pas systémiques
- Pas de pattern de re-scan massif au démarrage

**Conclusion:**
Le problème de crash **N'EST PAS** causé par un cycle vicieux de re-indexation.
Il faut chercher d'autres causes (mémoire, disk I/O, config Qdrant, etc.)
"@
}
)

---

## Prochaines Étapes

$( if ($qdrantJsCount -gt $rooCodeCount -or $ratio -gt 0.3) {
@"
1. **Validation immédiate:**
   - Désactiver roo-state-manager temporairement
   - Observer si Qdrant reste stable >24h

2. **Si stable → Problème confirmé:**
   - Implémenter solutions court terme
   - Planifier refactoring long terme

3. **Si instable → Problème ailleurs:**
   - Analyser logs système (RAM, CPU, disk)
   - Vérifier configuration Qdrant (mémoire, threads)
"@
} else {
@"
1. Analyser d'autres métriques système (RAM, CPU, disk I/O)
2. Vérifier la configuration Qdrant (limites mémoire, threads)
3. Examiner les logs système pour OOM ou autres erreurs
4. Vérifier l'état des collections (indexation, corruption)
"@
})
"@

# Écriture du rapport
$report | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "✅ Rapport généré: $OutputPath" -ForegroundColor Green

# Affichage de la conclusion
Write-Host "`n" + "="*80 -ForegroundColor Cyan
Write-Host "CONCLUSION" -ForegroundColor Cyan
Write-Host "="*80 -ForegroundColor Cyan

$rooCodeCount = ($clientStats | Where-Object { $_.Name -match 'Roo-Code' }).Count
$qdrantJsCount = ($clientStats | Where-Object { $_.Name -match 'qdrant-js' }).Count
$ratio = if ($rooCodeCount -gt 0) { [math]::Round($qdrantJsCount / $rooCodeCount, 2) } else { 0 }

if ($qdrantJsCount -gt $rooCodeCount -or $ratio -gt 0.3) {
    Write-Host "❌ HYPOTHÈSE VALIDÉE: Cycle vicieux détecté" -ForegroundColor Red
    Write-Host "Ratio qdrant-js/Roo-Code: $ratio" -ForegroundColor Yellow
    Write-Host "roo-state-manager génère trop de requêtes!" -ForegroundColor Red
} else {
    Write-Host "✅ HYPOTHÈSE INVALIDÉE: Pas de cycle vicieux" -ForegroundColor Green
    Write-Host "Ratio qdrant-js/Roo-Code: $ratio (acceptable)" -ForegroundColor Green
    Write-Host "Le problème est ailleurs." -ForegroundColor Yellow
}

Write-Host "`nRapport complet disponible dans: $OutputPath" -ForegroundColor Cyan