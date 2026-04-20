# Script de scan des collections Qdrant pour détecter les configurations problématiques
# Date: 2025-10-13
# Usage: pwsh -File myia_qdrant/scripts/scan_collections_config.ps1

param(
    [string]$EnvFile = ".env.production",
    [string]$QdrantUrl = "http://localhost:6333"
)

Write-Host "`n╔════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  SCAN DES COLLECTIONS QDRANT - CONFIGURATION       ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Récupération de l'API Key
try {
    $apiKey = (Get-Content $EnvFile | Select-String "QDRANT__SERVICE__API_KEY").ToString().Split("=")[1].Trim()
    Write-Host "✓ API Key chargée depuis $EnvFile" -ForegroundColor Green
} catch {
    Write-Host "✗ Erreur: Impossible de lire l'API Key depuis $EnvFile" -ForegroundColor Red
    exit 1
}

# Liste des collections
Write-Host "`n▶ Récupération de la liste des collections..." -ForegroundColor Yellow
try {
    $response = curl -s -H "api-key: $apiKey" "$QdrantUrl/collections" | ConvertFrom-Json
    $collections = $response.result.collections
    Write-Host "✓ $($collections.name.Count) collections trouvées`n" -ForegroundColor Green
} catch {
    Write-Host "✗ Erreur lors de la récupération des collections" -ForegroundColor Red
    exit 1
}

# Scan de chaque collection
$problematic = @()
$results = @()

Write-Host "▶ Analyse des configurations...`n" -ForegroundColor Yellow

foreach ($col in $collections.name) {
    try {
        $config = curl -s -H "api-key: $apiKey" "$QdrantUrl/collections/$col" 2>$null | ConvertFrom-Json
        
        $indexingThreshold = $config.result.config.optimizer_config.indexing_threshold
        $maxSegmentSize = $config.result.config.optimizer_config.max_segment_size
        $vectorsCount = $config.result.vectors_count
        $pointsCount = $config.result.points_count
        
        $status = "✓"
        $statusColor = "Green"
        
        if ($indexingThreshold -eq 0) {
            $status = "⚠️"
            $statusColor = "Red"
            $problematic += $col
        }
        
        $results += [PSCustomObject]@{
            Collection = $col
            Status = $status
            IndexingThreshold = $indexingThreshold
            MaxSegmentSize = $maxSegmentSize
            PointsCount = $pointsCount
            VectorsCount = $vectorsCount
        }
        
        Write-Host "$status $col" -ForegroundColor $statusColor
        Write-Host "    Indexing Threshold: $indexingThreshold" -ForegroundColor Gray
        Write-Host "    Max Segment Size: $maxSegmentSize" -ForegroundColor Gray
        Write-Host "    Points: $pointsCount | Vectors: $vectorsCount`n" -ForegroundColor Gray
        
    } catch {
        Write-Host "✗ Erreur lors de l'analyse de $col" -ForegroundColor Red
    }
}

# Résumé
Write-Host "`n╔════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║                    RÉSUMÉ                          ║" -ForegroundColor Yellow
Write-Host "╚════════════════════════════════════════════════════╝`n" -ForegroundColor Yellow

Write-Host "Total collections analysées: $($collections.name.Count)" -ForegroundColor Cyan
Write-Host "Collections avec indexing_threshold = 0: $($problematic.Count)" -ForegroundColor $(if ($problematic.Count -gt 0) { "Red" } else { "Green" })

if ($problematic.Count -gt 0) {
    Write-Host "`n⚠️ COLLECTIONS PROBLÉMATIQUES ⚠️" -ForegroundColor Red
    foreach ($col in $problematic) {
        Write-Host "  - $col" -ForegroundColor Red
    }
    
    Write-Host "`n⚠️ Ces collections peuvent causer des freezes!" -ForegroundColor Red
    Write-Host "💡 Solution: Utiliser fix_collection_indexing.ps1 pour corriger" -ForegroundColor Yellow
} else {
    Write-Host "`n✓ Aucune collection problématique détectée" -ForegroundColor Green
}

# Export JSON pour analyse ultérieure
$outputFile = "myia_qdrant/diagnostics/collections_scan_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$results | ConvertTo-Json -Depth 10 | Out-File $outputFile
Write-Host "`n✓ Résultats exportés vers: $outputFile" -ForegroundColor Green

# Retourne le nombre de collections problématiques (pour utilisation dans d'autres scripts)
return $problematic.Count