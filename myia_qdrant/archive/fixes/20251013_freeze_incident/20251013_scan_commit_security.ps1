# Script de vérification de sécurité pour le dernier commit
# Date: 2025-10-13
# Objectif: Scanner le contenu des fichiers du commit pour détecter des clés d'API

param(
    [string]$CommitHash = "HEAD"
)

Write-Host "=== SCAN DE SÉCURITÉ DU COMMIT ===" -ForegroundColor Cyan
Write-Host "Commit analysé: $CommitHash" -ForegroundColor Yellow
Write-Host ""

# Patterns de détection de clés sensibles
$patterns = @(
    @{Name="API Key (generic)"; Pattern='(api[_-]?key|apikey)\s*[=:]\s*["''][a-zA-Z0-9_-]{15,}["'']'},
    @{Name="Secret"; Pattern='(secret|SECRET)\s*[=:]\s*["''][a-zA-Z0-9_-]{15,}["'']'},
    @{Name="Token"; Pattern='(token|TOKEN)\s*[=:]\s*["''][a-zA-Z0-9_-]{15,}["'']'},
    @{Name="Password"; Pattern='(password|PASSWORD)\s*[=:]\s*["''][a-zA-Z0-9_-]{8,}["'']'},
    @{Name="Qdrant API Key"; Pattern='QDRANT_API_KEY\s*[=:]\s*["''][a-zA-Z0-9_-]{15,}["'']'},
    @{Name="Bearer Token"; Pattern='Bearer\s+[a-zA-Z0-9_-]{20,}'}
)

# Obtenir la liste des fichiers du commit
Write-Host "Récupération de la liste des fichiers..." -ForegroundColor Gray
$files = git diff --name-only "$CommitHash~1" "$CommitHash"

if (-not $files) {
    Write-Host "ERREUR: Aucun fichier trouvé dans le commit" -ForegroundColor Red
    exit 1
}

$fileCount = ($files | Measure-Object).Count
Write-Host "Nombre de fichiers à scanner: $fileCount" -ForegroundColor Yellow
Write-Host ""

$suspiciousFiles = @()
$totalMatches = 0

foreach ($file in $files) {
    # Filtrer seulement les fichiers texte pertinents
    if ($file -notmatch '\.(ps1|md|json|yaml|yml|txt|sh|py|js|ts|cs|go|rs)$') {
        continue
    }
    
    Write-Host "Scanning: $file" -ForegroundColor Gray
    
    # Obtenir le contenu du fichier depuis le commit
    $content = git show "$CommitHash`:$file" 2>$null
    
    if (-not $content) {
        Write-Host "  [SKIP] Impossible de lire le fichier" -ForegroundColor DarkGray
        continue
    }
    
    $fileMatches = @()
    
    foreach ($pattern in $patterns) {
        $matches = [regex]::Matches($content, $pattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        
        if ($matches.Count -gt 0) {
            foreach ($match in $matches) {
                $fileMatches += @{
                    Type = $pattern.Name
                    Match = $match.Value
                    Position = $match.Index
                }
                $totalMatches++
            }
        }
    }
    
    if ($fileMatches.Count -gt 0) {
        Write-Host "  [ALERT] $($fileMatches.Count) correspondance(s) trouvée(s)" -ForegroundColor Red
        $suspiciousFiles += @{
            File = $file
            Matches = $fileMatches
        }
    } else {
        Write-Host "  [OK] Aucune clé détectée" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== RÉSULTAT DU SCAN ===" -ForegroundColor Cyan

if ($suspiciousFiles.Count -eq 0) {
    Write-Host "✅ AUCUNE CLÉ D'API DÉTECTÉE" -ForegroundColor Green
    Write-Host "Le commit est SÉCURISÉ pour être pushé" -ForegroundColor Green
    exit 0
} else {
    Write-Host "⚠️  ALERTES DE SÉCURITÉ DÉTECTÉES" -ForegroundColor Red
    Write-Host ""
    Write-Host "Nombre de fichiers suspects: $($suspiciousFiles.Count)" -ForegroundColor Red
    Write-Host "Nombre total de correspondances: $totalMatches" -ForegroundColor Red
    Write-Host ""
    
    foreach ($suspiciousFile in $suspiciousFiles) {
        Write-Host "Fichier: $($suspiciousFile.File)" -ForegroundColor Yellow
        foreach ($match in $suspiciousFile.Matches) {
            Write-Host "  - Type: $($match.Type)" -ForegroundColor Magenta
            Write-Host "    Valeur: $($match.Match.Substring(0, [Math]::Min(100, $match.Match.Length)))" -ForegroundColor DarkGray
            Write-Host ""
        }
    }
    
    Write-Host "⚠️  NE PAS PUSHER CE COMMIT AVANT DE CORRIGER LES PROBLÈMES" -ForegroundColor Red
    exit 1
}