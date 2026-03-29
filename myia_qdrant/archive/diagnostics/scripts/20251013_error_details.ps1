# Script pour extraire les détails des erreurs 400
# Date: 2025-10-13

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "EXTRACTION DETAILS ERREURS 400" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Extraire les messages d'erreur complets des dernières 100 requêtes avec erreur 400
Write-Host "=== DERNIERS MESSAGES D'ERREUR 400 ===" -ForegroundColor Yellow
Write-Host "Recherche des logs avec body d'erreur..." -ForegroundColor Cyan

# Extraire les lignes autour des erreurs 400 pour trouver le body
$logs = Get-Content freeze_analysis_logs.txt
$error400Lines = @()

for ($i = 0; $i -lt $logs.Count; $i++) {
    if ($logs[$i] -match 'roo_tasks_semantic_index.*400') {
        # Capturer la ligne d'erreur et les 5 lignes suivantes
        $context = @()
        for ($j = $i; $j -lt [Math]::Min($i + 6, $logs.Count); $j++) {
            $context += $logs[$j]
        }
        $error400Lines += [PSCustomObject]@{
            Index = $i
            Context = $context -join "`n"
        }
        
        if ($error400Lines.Count -ge 10) { break }
    }
}

Write-Host "Échantillon des 10 premières erreurs 400 avec contexte:" -ForegroundColor Yellow
$error400Lines | ForEach-Object {
    Write-Host "--- Erreur ligne $($_.Index) ---" -ForegroundColor Cyan
    Write-Host $_.Context
    Write-Host ""
}

# 2. Analyser la structure des requêtes qui échouent
Write-Host "=== ANALYSE DES TAILLES DE REPONSE 400 ===" -ForegroundColor Yellow
$responseSizes = Get-Content freeze_analysis_logs.txt | 
    Select-String -Pattern 'roo_tasks_semantic_index.*400\s+(\d+)' | 
    ForEach-Object {
        if ($_.Line -match '400\s+(\d+)') {
            [int]$matches[1]
        }
    } | 
    Group-Object | 
    Sort-Object Name

Write-Host "Distribution des tailles de réponse (bytes):" -ForegroundColor Cyan
$responseSizes | Format-Table @{Label="Taille (bytes)";Expression={$_.Name}}, Count -AutoSize

# 3. Vérifier si la collection peut être reconfigurée
Write-Host ""
Write-Host "=== SOLUTION PROPOSEE ===" -ForegroundColor Yellow
Write-Host "Problème identifié: max_indexing_threads: 0 (indexation désactivée)" -ForegroundColor Red
Write-Host ""
Write-Host "Solutions possibles:" -ForegroundColor Cyan
Write-Host "1. Recréer la collection avec max_indexing_threads > 0" -ForegroundColor Green
Write-Host "2. Désactiver wait=true dans roo-state-manager (workaround)" -ForegroundColor Yellow
Write-Host "3. Augmenter la mémoire allouée à 32GB pour éviter la saturation" -ForegroundColor Yellow
Write-Host ""

# 4. Analyser les patterns temporels d'erreurs pour identifier les moments critiques
Write-Host "=== MOMENTS DE FREEZE (concentrations d'erreurs) ===" -ForegroundColor Yellow
$hourlyErrors = Get-Content freeze_analysis_logs.txt | 
    Select-String -Pattern 'roo_tasks_semantic_index.*400' | 
    ForEach-Object {
        if ($_.Line -match '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})') {
            $matches[1]
        }
    } | 
    Group-Object | 
    Sort-Object Count -Descending | 
    Select-Object -First 20

Write-Host "Top 20 périodes avec le plus d'erreurs 400 (par minute):" -ForegroundColor Cyan
$hourlyErrors | Format-Table @{Label="Période";Expression={$_.Name}}, @{Label="Erreurs";Expression={$_.Count}} -AutoSize

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ANALYSE TERMINEE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan