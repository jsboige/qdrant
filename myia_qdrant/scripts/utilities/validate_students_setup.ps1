# Script de validation de la configuration Qdrant Students
# Utilisation: .\validate_students_setup.ps1

Write-Host "🔍 Validation de la configuration Qdrant Students" -ForegroundColor Cyan

# Vérifier que les fichiers de configuration existent
Write-Host "`n📁 Vérification des fichiers..." -ForegroundColor Yellow
$files = @(
    "docker-compose.students.yml",
    "config/students.yaml",
    ".env.students"
)

foreach ($file in $files) {
    if (Test-Path $file) {
        Write-Host "✅ $file existe" -ForegroundColor Green
    } else {
        Write-Host "❌ $file manquant" -ForegroundColor Red
        exit 1
    }
}

# Vérifier que les ports sont disponibles
Write-Host "`n🌐 Vérification des ports..." -ForegroundColor Yellow
$ports = @(6335, 6336)

foreach ($port in $ports) {
    try {
        $connection = Test-NetConnection -ComputerName localhost -Port $port -WarningAction SilentlyContinue
        if ($connection.TcpTestSucceeded) {
            Write-Host "⚠️  Port $port est déjà utilisé" -ForegroundColor Yellow
        } else {
            Write-Host "✅ Port $port disponible" -ForegroundColor Green
        }
    } catch {
        Write-Host "✅ Port $port disponible" -ForegroundColor Green
    }
}

# Vérifier la syntaxe du docker-compose
Write-Host "`n🐳 Validation Docker Compose..." -ForegroundColor Yellow
try {
    $result = docker-compose -f docker-compose.students.yml config -q 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Syntaxe docker-compose.students.yml valide" -ForegroundColor Green
    } else {
        Write-Host "❌ Erreur dans docker-compose.students.yml : $result" -ForegroundColor Red
    }
} catch {
    Write-Host "⚠️  Docker Compose non disponible, validation ignorée" -ForegroundColor Yellow
}

# Afficher le résumé de la configuration
Write-Host "`n📊 Résumé de la configuration:" -ForegroundColor Cyan
Write-Host "  Container name: qdrant_students" -ForegroundColor White
Write-Host "  HTTP API port: 6335 -> 6333" -ForegroundColor White
Write-Host "  gRPC port: 6336 -> 6334" -ForegroundColor White
Write-Host "  Config file: ./config/students.yaml" -ForegroundColor White
Write-Host "  Storage volume: qdrant-students-storage" -ForegroundColor White
Write-Host "  Snapshots volume: qdrant-students-snapshots" -ForegroundColor White

Write-Host "`n🚀 Commande de démarrage:" -ForegroundColor Green
Write-Host "  docker-compose -f docker-compose.students.yml up -d" -ForegroundColor White

Write-Host "`n✅ Validation terminée !" -ForegroundColor Green