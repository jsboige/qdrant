# 🚨 SCRIPT D'URGENCE - RÉCUPÉRATION DONNÉES QDRANT
# SITUATION: Perte des données de production lors de mise à jour
# Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Host "🚨 === SITUATION CRITIQUE - PERTE DONNÉES PRODUCTION === 🚨" -ForegroundColor Red
Write-Host ""

# État avant/après
Write-Host "📊 RÉSUMÉ SITUATION:" -ForegroundColor Yellow
Write-Host "• AVANT: 45+ collections (ws-xxx, roo_tasks_semantic_index)" -ForegroundColor Red
Write-Host "• APRÈS: 1 seule collection (roo_tasks_semantic_index)" -ForegroundColor Red
Write-Host "• CAUSE: Volumes Docker recréés vides lors restart" -ForegroundColor Red
Write-Host ""

Write-Host "🔍 TENTATIVES DE RÉCUPÉRATION..." -ForegroundColor Cyan

# 1. Vérifier si des volumes orphelins existent avec anciennes données
Write-Host "1. Recherche volumes orphelins..." -ForegroundColor Yellow
$allVolumes = docker volume ls --format "{{.Name}}"
$suspiciousVolumes = @()

foreach ($volume in $allVolumes) {
    # Volumes avec IDs cryptographiques (possibles anciens volumes qdrant)
    if ($volume -match "^[a-f0-9]{64}$") {
        $suspiciousVolumes += $volume
    }
}

if ($suspiciousVolumes.Count -gt 0) {
    Write-Host "   ⚠️  Volumes suspects trouvés (possibles anciennes données):" -ForegroundColor Yellow
    $suspiciousVolumes | ForEach-Object { Write-Host "   - $_" -ForegroundColor White }
} else {
    Write-Host "   ✗ Aucun volume suspect trouvé" -ForegroundColor Red
}
Write-Host ""

# 2. Vérifier les snapshots existants
Write-Host "2. Recherche snapshots de sauvegarde..." -ForegroundColor Yellow
$snapshotDirs = @(".\qdrant_snapshots", ".\snapshots", ".\backup*")
$foundSnapshots = @()

foreach ($dir in $snapshotDirs) {
    if (Test-Path $dir) {
        $foundSnapshots += $dir
        Write-Host "   ✓ Trouvé: $dir" -ForegroundColor Green
    }
}

if ($foundSnapshots.Count -eq 0) {
    Write-Host "   ✗ Aucun répertoire de snapshots trouvé" -ForegroundColor Red
}
Write-Host ""

# 3. Vérifier si d'autres instances Qdrant tournent avec les données
Write-Host "3. Vérification autres instances Qdrant..." -ForegroundColor Yellow
$qdrantContainers = docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" | Select-String "qdrant"

if ($qdrantContainers) {
    Write-Host "   Containers Qdrant actifs:" -ForegroundColor Cyan
    $qdrantContainers | ForEach-Object { Write-Host "   $_" -ForegroundColor White }
    
    # Test du service students qui était "unhealthy"
    Write-Host "   Test accès service Students (port 6335):" -ForegroundColor Cyan
    try {
        $studentsResponse = Invoke-RestMethod -Uri "http://localhost:6335/collections" -Method Get -TimeoutSec 5
        if ($studentsResponse.result.collections) {
            Write-Host "   ✓ Students a $($studentsResponse.result.collections.Count) collections !" -ForegroundColor Green
            Write-Host "   🎯 DONNÉES POSSIBLEMENT RÉCUPÉRABLES depuis Students !" -ForegroundColor Green
        }
    } catch {
        Write-Host "   ✗ Students inaccessible: $_" -ForegroundColor Red
    }
}
Write-Host ""

# 4. ACTIONS RECOMMANDÉES
Write-Host "🛠️  ACTIONS RECOMMANDÉES (PAR ORDRE DE PRIORITÉ):" -ForegroundColor Green
Write-Host "1. 🚨 ARRÊTER IMMÉDIATEMENT toute opération sur Production" -ForegroundColor Red
Write-Host "2. 📋 Vérifier si le service Students contient nos données" -ForegroundColor Yellow
Write-Host "3. 🔄 Si oui, faire migration Students → Production" -ForegroundColor Yellow
Write-Host "4. 🗂️  Analyser les volumes suspects pour données récupérables" -ForegroundColor Yellow
Write-Host "5. 💾 Vérifier s'il existe des sauvegardes externes" -ForegroundColor Yellow
Write-Host ""

# 5. Scripts de récupération
Write-Host "🔧 SCRIPTS DE RÉCUPÉRATION DISPONIBLES:" -ForegroundColor Cyan
Write-Host "• Vérifier Students: curl http://localhost:6335/collections" -ForegroundColor White
Write-Host "• Inspecter volume suspect: docker volume inspect <volume_id>" -ForegroundColor White
Write-Host "• Lister snapshots: Get-ChildItem .\* -Recurse -Include '*.snapshot'" -ForegroundColor White
Write-Host ""

Write-Host "⏰ TEMPS CRITIQUE - AGIR RAPIDEMENT !" -ForegroundColor Red
Write-Host "Les données peuvent être récupérables si elles sont dans Students ou volumes orphelins." -ForegroundColor Yellow

# Créer un log de l'incident
$incidentLog = @{
    timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    incident = "Production data loss during Qdrant update"
    before_collections = "45+ collections including ws-* and roo_tasks_semantic_index"
    after_collections = "1 collection: roo_tasks_semantic_index only"
    cause = "Docker volumes recreated empty during restart"
    recovery_options = @(
        "Check Students service (port 6335)",
        "Analyze suspicious volumes with crypto IDs",
        "Look for external snapshots",
        "Check backup directories"
    )
    status = "CRITICAL - Data recovery required"
}

$incidentLog | ConvertTo-Json -Depth 5 | Out-File "INCIDENT_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
Write-Host "📝 Log d'incident sauvegardé: INCIDENT_$(Get-Date -Format 'yyyyMMdd_HHmmss').json" -ForegroundColor Cyan