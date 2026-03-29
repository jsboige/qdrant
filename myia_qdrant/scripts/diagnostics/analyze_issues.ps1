# Script d'Analyse Diagnostique Qdrant
# Date: 2025-10-13
# Usage: Analyse des problèmes et collecte d'informations de diagnostic
#
# EXEMPLES:
#   .\analyze_issues.ps1                                             # Analyse complète
#   .\analyze_issues.ps1 -FocusOnCollection "roo_tasks_semantic_index"  # Collection spécifique
#   .\analyze_issues.ps1 -AnalyzeFreeze                              # Analyse spécifique freeze
#   .\analyze_issues.ps1 -ExportReport -OutputFile "diagnosis.md"    # Export rapport

[CmdletBinding()]
param(
    [string]$EnvFile = ".env.production",                # Fichier .env à utiliser
    [int]$Port = 6333,                                   # Port Qdrant
    [string]$ContainerName = "qdrant_production",        # Nom du container Docker
    [string]$FocusOnCollection = "",                     # Collection à analyser en détail
    [switch]$AnalyzeFreeze = $false,                     # Analyse spécifique des freezes
    [switch]$AnalyzeLogs = $false,                       # Analyser les logs en détail
    [int]$LogTailLines = 500,                            # Nombre de lignes de logs à analyser
    [switch]$ExportReport = $false,                      # Exporter un rapport
    [string]$OutputFile = ""                             # Fichier de sortie
)

$ErrorActionPreference = 'Continue'
$QdrantUrl = "http://localhost:$Port"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Fonction de logging avec couleurs
function Write-DiagnosticSection {
    param([string]$Title)
    Write-Host "`n╔$('═' * ($Title.Length + 2))╗" -ForegroundColor Cyan
    Write-Host "║ $Title ║" -ForegroundColor Cyan
    Write-Host "╚$('═' * ($Title.Length + 2))╝" -ForegroundColor Cyan
}

function Write-Finding {
    param(
        [string]$Message,
        [string]$Severity = "INFO"  # INFO, WARNING, CRITICAL
    )
    
    $icon = switch ($Severity) {
        "CRITICAL" { "✗" }
        "WARNING" { "⚠" }
        default { "ℹ" }
    }
    
    $color = switch ($Severity) {
        "CRITICAL" { "Red" }
        "WARNING" { "Yellow" }
        default { "Cyan" }
    }
    
    Write-Host "  $icon $Message" -ForegroundColor $color
}

# Récupérer l'API key
function Get-ApiKey {
    param([string]$EnvPath)
    
    if (-not (Test-Path $EnvPath)) {
        throw "Fichier .env introuvable: $EnvPath"
    }
    
    $envContent = Get-Content $EnvPath
    foreach ($line in $envContent) {
        if ($line -match "^QDRANT.*API_KEY=(.+)$") {
            return $matches[1]
        }
    }
    
    throw "Impossible de récupérer l'API key depuis $EnvPath"
}

# Structure pour stocker les résultats
$diagnosticData = @{
    Timestamp = Get-Date -Format 'o'
    Environment = $EnvFile
    QdrantUrl = $QdrantUrl
    ContainerName = $ContainerName
    Findings = @()
    ServiceHealth = $null
    CollectionsAnalysis = @()
    LogAnalysis = @()
    Recommendations = @()
}

try {
    $apiKey = Get-ApiKey -EnvPath $EnvFile
    $headers = @{
        'api-key' = $apiKey
        'Content-Type' = 'application/json'
    }
    
    Write-DiagnosticSection "Diagnostic Qdrant - $Timestamp"
    Write-Host "Environment: $EnvFile"
    Write-Host "URL: $QdrantUrl"
    Write-Host ""
    
    # 1. VÉRIFICATION DE LA SANTÉ DU SERVICE
    Write-DiagnosticSection "Service Health Check"
    
    try {
        $healthCheck = Invoke-RestMethod -Uri "$QdrantUrl/healthz" -Method Get -TimeoutSec 5
        $diagnosticData.ServiceHealth = "OK"
        Write-Finding "Service Qdrant répond correctement" "INFO"
    }
    catch {
        $diagnosticData.ServiceHealth = "ERROR"
        $diagnosticData.Findings += "Service Qdrant ne répond pas"
        Write-Finding "Service Qdrant ne répond pas: $($_.Exception.Message)" "CRITICAL"
    }
    
    # 2. STATISTIQUES DU CONTAINER
    Write-DiagnosticSection "Container Analysis"
    
    try {
        $containerInfo = docker inspect $ContainerName 2>&1 | ConvertFrom-Json
        if ($containerInfo) {
            $state = $containerInfo[0].State
            $config = $containerInfo[0].Config
            
            Write-Finding "Status: $($state.Status)" $(if ($state.Status -eq "running") { "INFO" } else { "CRITICAL" })
            Write-Finding "Started: $($state.StartedAt)"
            Write-Finding "Restarts: $($containerInfo[0].RestartCount)" $(if ($containerInfo[0].RestartCount -gt 0) { "WARNING" } else { "INFO" })
            
            if ($state.OOMKilled) {
                $diagnosticData.Findings += "Container tué par OOM (Out of Memory)"
                Write-Finding "Container a été tué par OOM!" "CRITICAL"
            }
            
            # Vérifier les limites de ressources
            $memLimit = $config.HostConfig.Memory
            if ($memLimit -gt 0) {
                Write-Finding "Memory Limit: $([math]::Round($memLimit / 1GB, 2)) GB"
            }
            else {
                $diagnosticData.Findings += "Aucune limite mémoire définie"
                Write-Finding "Aucune limite mémoire définie" "WARNING"
            }
        }
    }
    catch {
        Write-Finding "Impossible d'inspecter le container: $($_.Exception.Message)" "WARNING"
    }
    
    # 3. ANALYSE DES COLLECTIONS
    Write-DiagnosticSection "Collections Analysis"
    
    try {
        $collections = Invoke-RestMethod -Uri "$QdrantUrl/collections" -Headers $headers -Method Get
        
        foreach ($col in $collections.result.collections) {
            $colName = $col.name
            
            # Filtrer si une collection spécifique est demandée
            if ($FocusOnCollection -and $colName -ne $FocusOnCollection) {
                continue
            }
            
            Write-Host "`n  Collection: $colName" -ForegroundColor Magenta
            
            # Récupérer les détails
            $colDetails = Invoke-RestMethod -Uri "$QdrantUrl/collections/$colName" -Headers $headers -Method Get
            $result = $colDetails.result
            
            $colAnalysis = @{
                Name = $colName
                Status = $result.status
                VectorsCount = $result.vectors_count
                PointsCount = $result.points_count
                SegmentsCount = $result.segments_count
                IndexedVectors = $result.indexed_vectors_count
                Issues = @()
            }
            
            # Analyser les problèmes potentiels
            if ($result.status -ne "green") {
                $colAnalysis.Issues += "Status non optimal: $($result.status)"
                Write-Finding "Status: $($result.status)" "WARNING"
            }
            
            # Vérifier l'indexation
            if ($result.indexed_vectors_count -lt $result.vectors_count) {
                $notIndexed = $result.vectors_count - $result.indexed_vectors_count
                $colAnalysis.Issues += "Vecteurs non indexés: $notIndexed"
                Write-Finding "$notIndexed vecteurs non indexés" "WARNING"
            }
            
            # Vérifier la cohérence points/vectors
            if ($result.points_count -ne $result.vectors_count) {
                $colAnalysis.Issues += "Incohérence points/vectors"
                Write-Finding "Points: $($result.points_count), Vectors: $($result.vectors_count)" "WARNING"
            }
            
            # Vérifier le nombre de segments
            if ($result.segments_count -gt 10) {
                $colAnalysis.Issues += "Nombre élevé de segments: $($result.segments_count)"
                Write-Finding "Nombre élevé de segments ($($result.segments_count)) - Optimisation possible" "WARNING"
            }
            
            Write-Finding "Points: $($result.points_count)"
            Write-Finding "Vectors: $($result.vectors_count)"
            Write-Finding "Indexed: $($result.indexed_vectors_count)"
            Write-Finding "Segments: $($result.segments_count)"
            
            $diagnosticData.CollectionsAnalysis += $colAnalysis
        }
    }
    catch {
        $diagnosticData.Findings += "Échec d'analyse des collections: $($_.Exception.Message)"
        Write-Finding "Échec d'analyse des collections: $($_.Exception.Message)" "CRITICAL"
    }
    
    # 4. ANALYSE DES LOGS
    if ($AnalyzeLogs -or $AnalyzeFreeze) {
        Write-DiagnosticSection "Log Analysis"
        
        try {
            $logs = docker logs $ContainerName --tail $LogTailLines 2>&1
            
            # Compter les types d'erreurs
            $errors = $logs | Select-String -Pattern "ERROR" | Measure-Object | Select-Object -ExpandProperty Count
            $warnings = $logs | Select-String -Pattern "WARN" | Measure-Object | Select-Object -ExpandProperty Count
            $panics = $logs | Select-String -Pattern "panic" | Measure-Object | Select-Object -ExpandProperty Count
            
            Write-Finding "Errors: $errors"
            Write-Finding "Warnings: $warnings"
            Write-Finding "Panics: $panics" $(if ($panics -gt 0) { "CRITICAL" } else { "INFO" })
            
            # Analyse spécifique des freezes
            if ($AnalyzeFreeze) {
                Write-Host "`n  Recherche de patterns de freeze..." -ForegroundColor Yellow
                
                $freezePatterns = @(
                    "timeout",
                    "deadlock",
                    "hanging",
                    "blocked",
                    "stuck",
                    "slow query",
                    "long running"
                )
                
                foreach ($pattern in $freezePatterns) {
                    $matches = $logs | Select-String -Pattern $pattern -CaseSensitive:$false
                    if ($matches.Count -gt 0) {
                        Write-Finding "Pattern '$pattern' trouvé: $($matches.Count) occurrences" "WARNING"
                        $diagnosticData.LogAnalysis += @{
                            Pattern = $pattern
                            Count = $matches.Count
                            Samples = @($matches | Select-Object -First 3 -ExpandProperty Line)
                        }
                    }
                }
            }
            
            # Rechercher les erreurs récentes
            $recentErrors = $logs | Select-String -Pattern "ERROR|CRITICAL" | Select-Object -Last 10
            if ($recentErrors.Count -gt 0) {
                Write-Host "`n  Dernières erreurs:" -ForegroundColor Yellow
                foreach ($errorLine in $recentErrors) {
                    Write-Host "    $errorLine" -ForegroundColor Red
                }
            }
        }
        catch {
            Write-Finding "Impossible d'analyser les logs: $($_.Exception.Message)" "WARNING"
        }
    }
    
    # 5. RESSOURCES SYSTÈME
    Write-DiagnosticSection "System Resources"
    
    try {
        # Stats Docker
        $stats = docker stats $ContainerName --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $statsArray = $stats -split ','
            Write-Finding "CPU: $($statsArray[0])"
            Write-Finding "Memory: $($statsArray[1]) ($($statsArray[2]))"
            Write-Finding "Network I/O: $($statsArray[3])"
            Write-Finding "Block I/O: $($statsArray[4])"
            
            # Extraire le pourcentage mémoire
            if ($statsArray[2] -match '(\d+\.?\d*)%') {
                $memPercent = [double]$matches[1]
                if ($memPercent -gt 90) {
                    $diagnosticData.Findings += "Utilisation mémoire élevée: $memPercent%"
                    Write-Finding "Utilisation mémoire élevée!" "CRITICAL"
                }
                elseif ($memPercent -gt 75) {
                    Write-Finding "Utilisation mémoire modérée" "WARNING"
                }
            }
        }
        
        # Espace disque WSL
        Write-Host ""
        $diskSpace = wsl df -h /var/lib/docker 2>&1 | Select-Object -Skip 1
        if ($diskSpace) {
            Write-Finding "Espace disque WSL:"
            Write-Host "    $diskSpace"
            
            # Vérifier si proche de la limite
            if ($diskSpace -match '(\d+)%') {
                $diskPercent = [int]$matches[1]
                if ($diskPercent -gt 90) {
                    $diagnosticData.Findings += "Espace disque critique: $diskPercent%"
                    Write-Finding "Espace disque critique!" "CRITICAL"
                }
                elseif ($diskPercent -gt 80) {
                    Write-Finding "Espace disque limité" "WARNING"
                }
            }
        }
    }
    catch {
        Write-Finding "Impossible d'analyser les ressources: $($_.Exception.Message)" "WARNING"
    }
    
    # 6. RECOMMANDATIONS
    Write-DiagnosticSection "Recommendations"
    
    if ($diagnosticData.Findings.Count -eq 0) {
        Write-Finding "Aucun problème majeur détecté" "INFO"
        $diagnosticData.Recommendations += "Système semble stable"
    }
    else {
        Write-Host "`n  Problèmes identifiés:" -ForegroundColor Yellow
        foreach ($finding in $diagnosticData.Findings) {
            Write-Host "    • $finding" -ForegroundColor Red
        }
        
        Write-Host "`n  Recommandations:" -ForegroundColor Yellow
        
        # Recommandations basées sur les findings
        if ($diagnosticData.Findings -match "mémoire") {
            Write-Finding "Considérer l'augmentation de la limite mémoire du container"
            $diagnosticData.Recommendations += "Augmenter la mémoire allouée"
        }
        
        if ($diagnosticData.Findings -match "segments") {
            Write-Finding "Optimiser les collections avec trop de segments"
            $diagnosticData.Recommendations += "Exécuter une optimisation des segments"
        }
        
        if ($diagnosticData.Findings -match "indexés") {
            Write-Finding "Attendre la fin de l'indexation ou investiguer le blocage"
            $diagnosticData.Recommendations += "Vérifier l'état de l'indexation"
        }
        
        if ($diagnosticData.Findings -match "disque") {
            Write-Finding "Libérer de l'espace disque ou augmenter la limite WSL"
            $diagnosticData.Recommendations += "Nettoyer l'espace disque"
        }
    }
    
    # 7. EXPORT DU RAPPORT
    if ($ExportReport) {
        Write-Host ""
        Write-DiagnosticSection "Export Report"
        
        $reportFile = if ($OutputFile) { $OutputFile } else { "diagnostics/diagnosis_$Timestamp.md" }
        
        # Créer le rapport Markdown
        $report = @"
# Diagnostic Qdrant - $Timestamp

## Configuration
- **Environment**: $EnvFile
- **URL**: $QdrantUrl
- **Container**: $ContainerName
- **Status Service**: $($diagnosticData.ServiceHealth)

## Problèmes Identifiés

$($diagnosticData.Findings | ForEach-Object { "- $_" } | Out-String)

## Analyse des Collections

$(foreach ($col in $diagnosticData.CollectionsAnalysis) {
"### $($col.Name)
- Status: $($col.Status)
- Points: $($col.PointsCount)
- Vectors: $($col.VectorsCount)
- Indexed: $($col.IndexedVectors)
- Segments: $($col.SegmentsCount)
$(if ($col.Issues.Count -gt 0) { "- Issues:`n$($col.Issues | ForEach-Object { "  - $_" } | Out-String)" })
"
})

## Recommandations

$($diagnosticData.Recommendations | ForEach-Object { "- $_" } | Out-String)

## Données Brutes

``````json
$($diagnosticData | ConvertTo-Json -Depth 10)
``````
"@
        
        New-Item -ItemType Directory -Force -Path (Split-Path $reportFile) | Out-Null
        $report | Out-File $reportFile -Encoding UTF8
        
        Write-Finding "Rapport exporté: $reportFile" "INFO"
    }
    
    Write-Host ""
    Write-DiagnosticSection "Diagnostic Complete"
    
}
catch {
    Write-Host "`nERREUR FATALE: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}