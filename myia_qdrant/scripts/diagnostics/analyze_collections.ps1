# Analyse complète des collections Qdrant
param(
    [string]$ApiKey = "qdrant_MYSUPERSECRETKEY2024"
)

$headers = @{ 'api-key' = $ApiKey }
$baseUrl = "http://localhost:6333"

Write-Host "`n====== ANALYSE DES COLLECTIONS QDRANT ======`n" -ForegroundColor Cyan

# Récupérer toutes les collections
$collectionsResponse = Invoke-RestMethod -Uri "$baseUrl/collections" -Headers $headers -Method Get
$collections = $collectionsResponse.result.collections

Write-Host "Nombre total de collections: $($collections.Count)" -ForegroundColor Yellow
Write-Host "`n"

# Analyser chaque collection
$problemCollections = @()

foreach ($coll in $collections) {
    $collName = $coll.name
    
    try {
        $collInfo = Invoke-RestMethod -Uri "$baseUrl/collections/$collName" -Headers $headers -Method Get
        $result = $collInfo.result
        
        $points = $result.points_count
        $segments = $result.segments_count
        $indexed = $result.indexed_vectors_count
        $diskMB = [math]::Round($result.disk_data_size / 1MB, 2)
        $ramMB = [math]::Round($result.ram_data_size / 1MB, 2)
        $hnswThreads = $result.config.hnsw_config.max_indexing_threads
        
        # Détecter les problèmes potentiels
        $hasIssue = $false
        $issues = @()
        
        if ($segments -gt 10) {
            $hasIssue = $true
            $issues += "SEGMENTS ÉLEVÉS ($segments)"
        }
        if ($hnswThreads -eq 0) {
            $hasIssue = $true
            $issues += "HNSW THREADS=0 (CORRUPTION POSSIBLE)"
        }
        if ($points -gt 5000) {
            $hasIssue = $true
            $issues += "VOLUME ÉLEVÉ ($points points)"
        }
        if ($diskMB -gt 100) {
            $hasIssue = $true
            $issues += "TAILLE DISQUE (${diskMB}MB)"
        }
        
        if ($hasIssue) {
            $problemCollections += [PSCustomObject]@{
                Name = $collName
                Points = $points
                Segments = $segments
                DiskMB = $diskMB
                RAMMB = $ramMB
                HNSWThreads = $hnswThreads
                Issues = $issues -join ", "
            }
            
            Write-Host "⚠️  $collName" -ForegroundColor Red
        } else {
            Write-Host "✓  $collName" -ForegroundColor Green
        }
        
        Write-Host "   Points: $points | Segments: $segments | Disk: ${diskMB}MB | HNSW Threads: $hnswThreads"
        
        if ($issues.Count -gt 0) {
            Write-Host "   PROBLÈMES: $($issues -join ' | ')" -ForegroundColor Yellow
        }
        
        Write-Host ""
        
    } catch {
        Write-Host "❌ Erreur lors de l'analyse de $collName : $_" -ForegroundColor Red
    }
}

Write-Host "`n====== RÉSUMÉ DES COLLECTIONS PROBLÉMATIQUES ======`n" -ForegroundColor Cyan
if ($problemCollections.Count -eq 0) {
    Write-Host "Aucune collection problématique détectée." -ForegroundColor Green
} else {
    $problemCollections | Format-Table -AutoSize
    
    Write-Host "`nTOP 3 COLLECTIONS PAR SEGMENTS:" -ForegroundColor Yellow
    $problemCollections | Sort-Object Segments -Descending | Select-Object -First 3 | Format-Table Name, Segments, Points, DiskMB -AutoSize
    
    Write-Host "`nTOP 3 COLLECTIONS PAR TAILLE:" -ForegroundColor Yellow
    $problemCollections | Sort-Object DiskMB -Descending | Select-Object -First 3 | Format-Table Name, DiskMB, Points, Segments -AutoSize
}