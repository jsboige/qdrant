<#
.SYNOPSIS
    Active la scalar quantization int8 sur la collection roo_tasks_semantic_index
.DESCRIPTION
    Réduit l'utilisation RAM de ~75% en quantifiant les vecteurs 1536D
    Préserve la vitesse en gardant quantized vectors en RAM
.NOTES
    Basé sur best practices Qdrant découvertes via recherche SearXNG
    Référence: https://qdrant.tech/articles/what-is-vector-quantization/
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$QdrantUrl = "http://localhost:6333",
    
    [Parameter(Mandatory=$false)]
    [string]$CollectionName = "roo_tasks_semantic_index"
)

# Configuration
$ErrorActionPreference = "Stop"
$ApiKey = $env:QDRANT_API_KEY

if (-not $ApiKey) {
    Write-Error "Variable d'environnement QDRANT_API_KEY non définie"
    exit 1
}

Write-Host "=== ACTIVATION QUANTIZATION INT8 ===" -ForegroundColor Cyan
Write-Host "Collection: $CollectionName" -ForegroundColor Yellow
Write-Host "URL: $QdrantUrl" -ForegroundColor Yellow

# Vérifier état actuel de la collection
Write-Host "`n1. Vérification état actuel..." -ForegroundColor Cyan
$headers = @{
    "api-key" = $ApiKey
    "Content-Type" = "application/json"
}

try {
    $collectionInfo = Invoke-RestMethod -Uri "$QdrantUrl/collections/$CollectionName" -Headers $headers -Method Get
    
    Write-Host "   Points: $($collectionInfo.result.points_count)" -ForegroundColor Green
    Write-Host "   Status: $($collectionInfo.result.status)" -ForegroundColor Green
    
    # Vérifier si quantization déjà active
    if ($collectionInfo.result.config.params.quantization_config) {
        Write-Warning "   Quantization déjà configurée sur cette collection"
        Write-Host "`nConfiguration actuelle:" -ForegroundColor Yellow
        $collectionInfo.result.config.params.quantization_config | ConvertTo-Json -Depth 10
        
        $continue = Read-Host "`nVoulez-vous reconfigurer? (y/N)"
        if ($continue -ne 'y') {
            Write-Host "Opération annulée" -ForegroundColor Yellow
            exit 0
        }
    }
    
} catch {
    Write-Error "Impossible de récupérer info collection: $_"
    exit 1
}

# Activer scalar quantization int8
Write-Host "`n2. Application de la quantization int8..." -ForegroundColor Cyan

$quantizationConfig = @{
    quantization_config = @{
        scalar = @{
            type = "int8"
            quantile = $null
            always_ram = $true  # Garde quantized vectors en RAM pour vitesse maximale
        }
    }
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod `
        -Uri "$QdrantUrl/collections/$CollectionName" `
        -Headers $headers `
        -Method Patch `
        -Body $quantizationConfig
    
    Write-Host "   ✓ Quantization activée avec succès!" -ForegroundColor Green
    
} catch {
    Write-Error "Échec activation quantization: $_"
    exit 1
}

# Vérifier résultat
Write-Host "`n3. Vérification post-activation..." -ForegroundColor Cyan

Start-Sleep -Seconds 2

try {
    $updatedInfo = Invoke-RestMethod -Uri "$QdrantUrl/collections/$CollectionName" -Headers $headers -Method Get
    
    Write-Host "   Status: $($updatedInfo.result.status)" -ForegroundColor Green
    Write-Host "   Quantization:" -ForegroundColor Green
    $updatedInfo.result.config.params.quantization_config | ConvertTo-Json -Depth 10 | Write-Host
    
    # Calculer économie RAM théorique
    $vectorsCount = $updatedInfo.result.points_count
    $originalSize = $vectorsCount * 1536 * 4  # float32 = 4 bytes
    $quantizedSize = $vectorsCount * 1536 * 1  # int8 = 1 byte
    $savedBytes = $originalSize - $quantizedSize
    $savedMB = [Math]::Round($savedBytes / 1024 / 1024, 2)
    $savedPercent = [Math]::Round(($savedBytes / $originalSize) * 100, 1)
    
    Write-Host "`n4. Économie RAM estimée:" -ForegroundColor Cyan
    Write-Host "   Avant: $([Math]::Round($originalSize / 1024 / 1024, 2)) MB" -ForegroundColor Yellow
    Write-Host "   Après: $([Math]::Round($quantizedSize / 1024 / 1024, 2)) MB" -ForegroundColor Green
    Write-Host "   Économie: $savedMB MB ($savedPercent%)" -ForegroundColor Green
    
} catch {
    Write-Warning "Vérification post-activation échouée: $_"
}

Write-Host "`n=== QUANTIZATION INT8 ACTIVÉE ===" -ForegroundColor Green
Write-Host "La collection utilisera ~75% moins de RAM pour les vecteurs" -ForegroundColor Green
Write-Host "Les performances de recherche sont préservées (quantized en RAM)" -ForegroundColor Green