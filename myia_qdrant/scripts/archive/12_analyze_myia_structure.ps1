#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Analyse la structure de myia_qdrant/ pour identifier le désordre et proposer un plan de nettoyage
#>

$ErrorActionPreference = 'Stop'

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        ANALYSE DE LA STRUCTURE myia_qdrant/              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$rootPath = "myia_qdrant"

# 1. Scripts à la racine (devrait être vide ou minimal)
Write-Host "▶ 1. SCRIPTS À LA RACINE (devrait être dans scripts/):" -ForegroundColor Yellow
$rootScripts = Get-ChildItem $rootPath -Filter "*.ps1" -File
if ($rootScripts.Count -gt 0) {
    Write-Host "   ⚠ $($rootScripts.Count) scripts trouvés à la racine:" -ForegroundColor Red
    foreach ($script in $rootScripts) {
        Write-Host "      - $($script.Name)" -ForegroundColor Gray
    }
} else {
    Write-Host "   ✓ Aucun script à la racine" -ForegroundColor Green
}

# 2. Documentation à la racine
Write-Host "`n▶ 2. DOCUMENTATION À LA RACINE:" -ForegroundColor Yellow
$rootDocs = Get-ChildItem $rootPath -Filter "*.md" -File
Write-Host "   Documents trouvés: $($rootDocs.Count)" -ForegroundColor Cyan
foreach ($doc in $rootDocs) {
    $size = [math]::Round($doc.Length/1KB, 2)
    Write-Host "      - $($doc.Name) ($size KB)" -ForegroundColor Gray
}

# 3. Sous-répertoires
Write-Host "`n▶ 3. SOUS-RÉPERTOIRES:" -ForegroundColor Yellow
$subdirs = Get-ChildItem $rootPath -Directory
foreach ($dir in $subdirs) {
    $fileCount = (Get-ChildItem $dir.FullName -File -Recurse).Count
    Write-Host "      - $($dir.Name)/ ($fileCount fichiers)" -ForegroundColor Cyan
}

# 4. Scripts dans scripts/
Write-Host "`n▶ 4. CONTENU DE scripts/:" -ForegroundColor Yellow
$scriptsDir = Join-Path $rootPath "scripts"

# Scripts unifiés (qdrant_*.ps1)
$unifiedScripts = Get-ChildItem $scriptsDir -Filter "qdrant_*.ps1" -File
Write-Host "   ✓ Scripts unifiés (qdrant_*.ps1): $($unifiedScripts.Count)" -ForegroundColor Green
foreach ($s in $unifiedScripts) {
    Write-Host "      - $($s.Name)" -ForegroundColor Gray
}

# Autres scripts à la racine de scripts/
$otherRootScripts = Get-ChildItem $scriptsDir -Filter "*.ps1" -File | Where-Object { $_.Name -notlike "qdrant_*" }
if ($otherRootScripts.Count -gt 0) {
    Write-Host "`n   ⚠ Autres scripts à la racine de scripts/: $($otherRootScripts.Count)" -ForegroundColor Yellow
    foreach ($s in $otherRootScripts) {
        Write-Host "      - $($s.Name)" -ForegroundColor Gray
    }
}

# Sous-répertoires de scripts/
$scriptSubdirs = Get-ChildItem $scriptsDir -Directory
if ($scriptSubdirs.Count -gt 0) {
    Write-Host "`n   📁 Sous-répertoires de scripts/:" -ForegroundColor Cyan
    foreach ($subdir in $scriptSubdirs) {
        $files = Get-ChildItem $subdir.FullName -Filter "*.ps1" -File
        Write-Host "      - $($subdir.Name)/ ($($files.Count) scripts)" -ForegroundColor Gray
        foreach ($f in $files) {
            Write-Host "         • $($f.Name)" -ForegroundColor DarkGray
        }
    }
}

# 5. Diagnostics
Write-Host "`n▶ 5. DIAGNOSTICS/:" -ForegroundColor Yellow
$diagDir = Join-Path $rootPath "diagnostics"
if (Test-Path $diagDir) {
    $diagFiles = Get-ChildItem $diagDir -File
    Write-Host "   Fichiers: $($diagFiles.Count)" -ForegroundColor Cyan
    
    # Grouper par type
    $psFiles = $diagFiles | Where-Object { $_.Extension -eq ".ps1" }
    $mdFiles = $diagFiles | Where-Object { $_.Extension -eq ".md" }
    $jsonFiles = $diagFiles | Where-Object { $_.Extension -eq ".json" }
    $logFiles = $diagFiles | Where-Object { $_.Extension -in @(".txt", ".log") }
    
    Write-Host "      - Scripts (.ps1): $($psFiles.Count)" -ForegroundColor Gray
    Write-Host "      - Docs (.md): $($mdFiles.Count)" -ForegroundColor Gray
    Write-Host "      - JSON: $($jsonFiles.Count)" -ForegroundColor Gray
    Write-Host "      - Logs (.txt/.log): $($logFiles.Count)" -ForegroundColor Gray
}

# 6. Docs structure
Write-Host "`n▶ 6. DOCS/ STRUCTURE:" -ForegroundColor Yellow
$docsDir = Join-Path $rootPath "docs"
if (Test-Path $docsDir) {
    Get-ChildItem $docsDir -Recurse -Directory | ForEach-Object {
        $relPath = $_.FullName.Replace($docsDir, "").TrimStart("\")
        $fileCount = (Get-ChildItem $_.FullName -File).Count
        Write-Host "      - docs/$relPath/ ($fileCount fichiers)" -ForegroundColor Cyan
    }
}

# 7. Détection de duplication
Write-Host "`n▶ 7. DUPLICATION POTENTIELLE:" -ForegroundColor Yellow

# Comparer diagnostics/ et docs/incidents/20251013_freeze/
$diagDir = Join-Path $rootPath "diagnostics"
$incidentDir = Join-Path $rootPath "docs/incidents/20251013_freeze"

if ((Test-Path $diagDir) -and (Test-Path $incidentDir)) {
    $diagFiles = Get-ChildItem $diagDir -File | Select-Object -ExpandProperty Name
    $incidentFiles = Get-ChildItem $incidentDir -File | Select-Object -ExpandProperty Name
    
    $duplicates = $diagFiles | Where-Object { $incidentFiles -contains $_ }
    
    if ($duplicates.Count -gt 0) {
        Write-Host "   ⚠ $($duplicates.Count) fichiers potentiellement dupliqués:" -ForegroundColor Red
        foreach ($dup in $duplicates) {
            Write-Host "      - $dup" -ForegroundColor Gray
        }
    } else {
        Write-Host "   ✓ Pas de duplication détectée" -ForegroundColor Green
    }
}

# 8. Fichiers temporaires
Write-Host "`n▶ 8. FICHIERS TEMPORAIRES/OBSOLÈTES:" -ForegroundColor Yellow
$tempPatterns = @("*_temp*", "*_old*", "*_backup*", "*.tmp", "*_20251013*")
$tempFiles = @()

foreach ($pattern in $tempPatterns) {
    $found = Get-ChildItem $rootPath -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue
    $tempFiles += $found
}

if ($tempFiles.Count -gt 0) {
    Write-Host "   ⚠ $($tempFiles.Count) fichiers temporaires trouvés:" -ForegroundColor Yellow
    $tempFiles | Group-Object Extension | ForEach-Object {
        Write-Host "      - $($_.Name): $($_.Count) fichiers" -ForegroundColor Gray
    }
} else {
    Write-Host "   ✓ Pas de fichiers temporaires évidents" -ForegroundColor Green
}

# 9. Résumé et recommandations
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                   RECOMMANDATIONS                          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$recommendations = @()

if ($rootScripts.Count -gt 0) {
    $recommendations += "📌 Déplacer les $($rootScripts.Count) scripts de la racine vers scripts/"
}

if ($otherRootScripts.Count -gt 0) {
    $recommendations += "📌 Organiser les scripts non-unifiés dans des sous-répertoires appropriés"
}

if ((Test-Path $diagDir) -and (Test-Path $incidentDir)) {
    $recommendations += "📌 Consolider diagnostics/ et docs/incidents/20251013_freeze/"
}

if ($tempFiles.Count -gt 0) {
    $recommendations += "📌 Archiver ou supprimer les $($tempFiles.Count) fichiers temporaires"
}

$recommendations += "📌 Créer une structure claire: scripts/, docs/, archive/"
$recommendations += "📌 Mettre à jour INDEX.md pour refléter la nouvelle structure"

foreach ($rec in $recommendations) {
    Write-Host "   $rec" -ForegroundColor Yellow
}

Write-Host "`n✅ Analyse terminée" -ForegroundColor Green