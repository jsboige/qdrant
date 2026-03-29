# Script de test pour la nouvelle configuration Production avec bind mounts WSL
# Créé le: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Host "🧪 PHASE DE TEST - Configuration Production WSL Bind Mounts" -ForegroundColor Cyan

# Vérifier que les répertoires WSL existent
Write-Host "🔍 Vérification des répertoires WSL..." -ForegroundColor Yellow
$wslStoragePath = "\\wsl.localhost\Ubuntu\home\jesse\qdrant_data\storage"
$wslSnapshotsPath = "\\wsl.localhost\Ubuntu\home\jesse\qdrant_data\snapshots"

if (!(Test-Path $wslStoragePath)) {
    Write-Host "❌ ERREUR: $wslStoragePath n'existe pas!" -ForegroundColor Red
    exit 1
}

if (!(Test-Path $wslSnapshotsPath)) {
    Write-Host "⚠️ Création du répertoire snapshots..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $wslSnapshotsPath -Force
}

Write-Host "✅ Répertoires WSL vérifiés" -ForegroundColor Green

# Arrêter le service production actuel
Write-Host "🛑 Arrêt du service production actuel..." -ForegroundColor Yellow
docker-compose stop qdrant 2>$null
docker-compose rm -f qdrant 2>$null

# Démarrer avec la nouvelle configuration
Write-Host "🚀 Démarrage avec docker-compose.production.yml..." -ForegroundColor Yellow
docker-compose -f docker-compose.production.yml up -d

# Attendre le démarrage
Write-Host "⏳ Attente du démarrage (30 secondes)..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# Tester la connexion
Write-Host "🔗 Test de connexion..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:6333/collections" -Method GET -TimeoutSec 10
    $collections = ($response.Content | ConvertFrom-Json).result.collections
    
    Write-Host "✅ SUCCÈS: $($collections.Count) collections trouvées" -ForegroundColor Green
    
    # Vérifier les collections ws-*
    $wsCollections = $collections | Where-Object { $_.name -like "ws-*" }
    Write-Host "📊 Collections ws-*: $($wsCollections.Count)" -ForegroundColor Cyan
    
} catch {
    Write-Host "❌ ERREUR: Impossible de se connecter à l'API" -ForegroundColor Red
    Write-Host "Logs du container:" -ForegroundColor Yellow
    docker logs qdrant_production --tail 20
    exit 1
}

Write-Host "🎉 Test réussi ! Configuration WSL bind mounts opérationnelle" -ForegroundColor Green