# Script de diagnostic des freezes Qdrant Production
# Date: 2025-10-13
# Symptôme: ~10 redémarrages manuels en 5 jours, service freeze (ne répond plus)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DIAGNOSTIC FREEZES QDRANT PRODUCTION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Récupérer l'API key
Write-Host "=== 1. RECUPERATION API KEY ===" -ForegroundColor Yellow
$apiKey = (Get-Content .env.production | Select-String 'QDRANT__SERVICE__API_KEY=(.+)').Matches.Groups[1].Value
Write-Host "API Key récupérée: $($apiKey.Substring(0,8))..." -ForegroundColor Green
Write-Host ""

# 2. État du container
Write-Host "=== 2. ETAT DU CONTAINER ===" -ForegroundColor Yellow
docker inspect qdrant_production --format "Uptime: {{.State.StartedAt}}"
docker inspect qdrant_production --format "RestartCount: {{.RestartCount}}"
docker inspect qdrant_production --format "Status: {{.State.Status}}"
Write-Host ""

# 3. Métriques système
Write-Host "=== 3. METRIQUES SYSTEME ===" -ForegroundColor Yellow
docker stats qdrant_production --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
Write-Host ""

# 4. Configuration de la collection problématique
Write-Host "=== 4. CONFIGURATION roo_tasks_semantic_index ===" -ForegroundColor Yellow
try {
    $collectionInfo = Invoke-RestMethod -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers @{'api-key'=$apiKey} -Method Get
    Write-Host "Points count: $($collectionInfo.result.points_count)" -ForegroundColor Cyan
    Write-Host "Indexed vectors count: $($collectionInfo.result.indexed_vectors_count)" -ForegroundColor Cyan
    Write-Host "Status: $($collectionInfo.result.status)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor Cyan
    $collectionInfo.result.config | ConvertTo-Json -Depth 5
} catch {
    Write-Host "ERREUR lors de la récupération de la collection: $_" -ForegroundColor Red
}
Write-Host ""

# 5. Analyse des erreurs 400
Write-Host "=== 5. ANALYSE DES ERREURS 400 ===" -ForegroundColor Yellow
$errors400 = Get-Content freeze_analysis_logs.txt | Select-String -Pattern 'roo_tasks_semantic_index.*400'
Write-Host "Total erreurs 400 sur roo_tasks_semantic_index: $($errors400.Count)" -ForegroundColor Red
Write-Host ""

# Temps de réponse moyens des erreurs 400
Write-Host "Temps de réponse des erreurs 400:" -ForegroundColor Cyan
$errors400 | Select-Object -First 20 | ForEach-Object {
    if ($_.Line -match '(\d+\.\d+)$') {
        $matches[1]
    }
} | Measure-Object -Average -Maximum -Minimum | Format-Table Count, Average, Minimum, Maximum

# 6. Distribution temporelle des erreurs
Write-Host "=== 6. DISTRIBUTION TEMPORELLE DES ERREURS ===" -ForegroundColor Yellow
$errors400 | ForEach-Object {
    if ($_.Line -match '(\d{4}-\d{2}-\d{2}T\d{2})') {
        $matches[1]
    }
} | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 | Format-Table Count, Name
Write-Host ""

# 7. Test de latence actuelle
Write-Host "=== 7. TEST DE LATENCE ACTUELLE ===" -ForegroundColor Yellow
$testResults = @()
1..5 | ForEach-Object {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Invoke-RestMethod -Uri 'http://localhost:6333/collections' -Headers @{'api-key'=$apiKey} -Method Get -TimeoutSec 5
        $sw.Stop()
        $testResults += $sw.ElapsedMilliseconds
        Write-Host "Test $($_): $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
    } catch {
        $sw.Stop()
        Write-Host "Test $($_): TIMEOUT ou ERREUR après $($sw.ElapsedMilliseconds)ms" -ForegroundColor Red
        $testResults += -1
    }
    Start-Sleep -Milliseconds 500
}
Write-Host ""
Write-Host "Latence moyenne: $(($testResults | Where-Object {$_ -gt 0} | Measure-Object -Average).Average)ms" -ForegroundColor Cyan
Write-Host ""

# 8. Vérifier les événements Docker récents
Write-Host "=== 8. EVENEMENTS DOCKER RECENTS ===" -ForegroundColor Yellow
docker events --since 120h --filter 'container=qdrant_production' --until 1m --format '{{.Time}} {{.Action}}' 2>&1 | Select-Object -First 20
Write-Host ""

# 9. Analyser la config production
Write-Host "=== 9. CONFIGURATION PRODUCTION ===" -ForegroundColor Yellow
if (Test-Path "config/production.optimized.yaml") {
    Write-Host "Paramètres critiques:" -ForegroundColor Cyan
    Get-Content "config/production.optimized.yaml" | Select-String -Pattern "flush_interval|wal_capacity|max_indexing_threads|indexing_threshold"
}
Write-Host ""

# 10. Synthèse
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SYNTHESE DU DIAGNOSTIC" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "1. Erreurs 400 détectées: $($errors400.Count)" -ForegroundColor $(if ($errors400.Count -gt 100) { "Red" } else { "Yellow" })
Write-Host "2. Mémoire utilisée: Vérifier ci-dessus" -ForegroundColor Yellow
Write-Host "3. Collection problématique: roo_tasks_semantic_index" -ForegroundColor Yellow
Write-Host "4. Pattern: Requêtes PUT avec wait=true qui prennent 2-125 secondes" -ForegroundColor Red
Write-Host ""
Write-Host "=== HYPOTHESES PRINCIPALES ===" -ForegroundColor Cyan
Write-Host "H1. Bug roo-state-manager: Requêtes PUT malformées causant 400" -ForegroundColor Yellow
Write-Host "H2. Lock contention: wait=true bloque les requêtes pendant trop longtemps" -ForegroundColor Yellow
Write-Host "H3. Configuration WAL inadaptée: flush_interval trop court" -ForegroundColor Yellow
Write-Host "H4. Saturation mémoire: Proche de la limite (84%)" -ForegroundColor Yellow
Write-Host ""
Write-Host "DIAGNOSTIC TERMINE - Voir résultats ci-dessus" -ForegroundColor Green