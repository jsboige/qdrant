# Script d'analyse des collections pour identifier la cause du freeze
$headers = @{'api-key'='qdrant_admin'}

Write-Host "`n=== ANALYSE COLLECTIONS QDRANT ===" -ForegroundColor Cyan

$collections = (Invoke-RestMethod -Uri "http://localhost:6333/collections" -Headers $headers).result.collections

$problematiques = @()

foreach ($coll in $collections) {
    $name = $coll.name
    $info = (Invoke-RestMethod -Uri "http://localhost:6333/collections/$name" -Headers $headers).result
    
    $indexed = $info.indexed_vectors_count
    $points = $info.points_count
    $segments = $info.segments_count
    $threshold = $info.config.optimizer_config.indexing_threshold
    
    $indexRatio = if ($points -gt 0) { [math]::Round(($indexed / $points) * 100, 2) } else { 0 }
    
    $obj = [PSCustomObject]@{
        Collection = $name.Substring(0, [Math]::Min(40, $name.Length))
        Points = $points
        Indexed = $indexed
        IndexRatio = "$indexRatio%"
        Segments = $segments
        Threshold = $threshold
        Status = $info.optimizer_status
    }
    
    # Identifier collections problématiques
    if ($indexed -eq 0 -and $points -gt 0) {
        $problematiques += $obj
        Write-Host "🔥 PROBLEME: $name - $points points, 0 indexés (full scan!)" -ForegroundColor Red
    }
    elseif ($indexRatio -lt 50 -and $points -gt 1000) {
        $problematiques += $obj
        Write-Host "⚠️ ATTENTION: $name - Seulement $indexRatio% indexé" -ForegroundColor Yellow
    }
    
    $obj
}

Write-Host "`n=== RESUME ===" -ForegroundColor Cyan
Write-Host "Collections totales: $($collections.Count)"
Write-Host "Collections problématiques: $($problematiques.Count)" -ForegroundColor $(if ($problematiques.Count -gt 0) { "Red" } else { "Green" })

if ($problematiques.Count -gt 0) {
    Write-Host "`n🚨 COLLECTIONS A REINDEXER:" -ForegroundColor Red
    $problematiques | Format-Table -AutoSize
    
    Write-Host "`n💡 SOLUTION IMMEDIATE:" -ForegroundColor Cyan
    Write-Host "1. Baisser indexing_threshold à 20000 (au lieu de 2000000)" -ForegroundColor Yellow
    Write-Host "2. Forcer rebuild des index HNSW" -ForegroundColor Yellow
    Write-Host "3. Ou supprimer/recréer ces collections avec config correcte" -ForegroundColor Yellow
}