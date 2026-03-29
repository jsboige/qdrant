# Script de validation et correction de la config Qdrant
# Vérifie la syntaxe YAML et cherche les doublons

param(
    [switch]$Fix = $false
)

$ErrorActionPreference = "Stop"

$configFile = "config/production.optimized.yaml"

Write-Host "`n🔍 Validation de la configuration YAML..." -ForegroundColor Cyan

# 1. Vérifier syntaxe YAML avec Python
Write-Host "`n1️⃣ Test syntaxe YAML..." -ForegroundColor Yellow

$pythonTest = @"
import yaml
import sys

try:
    with open('$configFile', 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    print('✅ Syntaxe YAML valide')
    sys.exit(0)
except yaml.YAMLError as e:
    print(f'❌ Erreur YAML: {e}')
    sys.exit(1)
except Exception as e:
    print(f'❌ Erreur: {e}')
    sys.exit(1)
"@

$pythonTest | python - 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Syntaxe YAML invalide!" -ForegroundColor Red
    exit 1
}

# 2. Chercher doublons indexing_threshold
Write-Host "`n2️⃣ Recherche de doublons 'indexing_threshold'..." -ForegroundColor Yellow

$matches = Select-String -Path $configFile -Pattern "^\s*indexing_threshold:" -AllMatches
$count = ($matches | Measure-Object).Count

Write-Host "Occurrences trouvées: $count" -ForegroundColor $(if ($count -eq 1) { "Green" } else { "Red" })

if ($count -gt 1) {
    Write-Host "`n❌ DOUBLON DÉTECTÉ!" -ForegroundColor Red
    $matches | ForEach-Object {
        Write-Host "  Ligne $($_.LineNumber): $($_.Line.Trim())" -ForegroundColor Yellow
    }
    
    if ($Fix) {
        Write-Host "`n🔧 Suppression des doublons (garde seulement le dernier)..." -ForegroundColor Cyan
        
        $content = Get-Content $configFile
        $newContent = @()
        $foundFirst = $false
        
        for ($i = 0; $i -lt $content.Count; $i++) {
            $line = $content[$i]
            if ($line -match "^\s*indexing_threshold:") {
                if (-not $foundFirst) {
                    $foundFirst = $true
                    continue  # Skip first occurrence
                }
            }
            $newContent += $line
        }
        
        # Backup avant modification
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        Copy-Item $configFile "$configFile.backup_$timestamp"
        Write-Host "✅ Backup créé: $configFile.backup_$timestamp" -ForegroundColor Green
        
        # Écrire nouveau contenu
        $newContent | Set-Content $configFile -Encoding UTF8
        Write-Host "✅ Doublons supprimés" -ForegroundColor Green
    } else {
        Write-Host "`nℹ️  Utilisez -Fix pour corriger automatiquement" -ForegroundColor Cyan
    }
    
    exit 1
}

Write-Host "`n✅ Configuration valide - Aucun doublon" -ForegroundColor Green
exit 0