# Script de Test de Connectivité au Service Qwen3 8B Distant
# Date: 2025-11-04
# Objectif: Valider la connexion, compatibilité API OpenAI, et dimensions 4096

param(
    [Parameter(Mandatory=$false)]
    [string]$Qwen3Endpoint = "http://localhost:11434",
    
    [Parameter(Mandatory=$false)]
    [string]$ApiKey = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$Verbose
)

# Configuration
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Couleurs pour l'affichage
$ColorSuccess = "Green"
$ColorError = "Red"
$ColorWarning = "Yellow"
$ColorInfo = "Cyan"
$ColorHeader = "White"

Write-Host "🔍 TEST DE CONNECTIVITÉ QWEN3 8B DISTANT" -ForegroundColor $ColorHeader
Write-Host "=========================================" -ForegroundColor $ColorHeader
Write-Host ""

# Fonction pour afficher le temps écoulé
function Get-ElapsedTime {
    param([datetime]$StartTime)
    $elapsed = (Get-Date) - $StartTime
    return "{0:mm\:ss\.fff}" -f $elapsed
}

# Fonction pour tester la connectivité de base
function Test-BasicConnectivity {
    param([string]$Endpoint)
    
    Write-Host "📡 Test 1: Connectivité de base à $Endpoint" -ForegroundColor $ColorInfo
    $startTime = Get-Date
    
    try {
        $response = Invoke-WebRequest -Uri "$Endpoint" -Method Get -TimeoutSec 10 -UseBasicParsing:$false
        $elapsed = Get-ElapsedTime -StartTime $startTime
        
        if ($response.StatusCode -eq 200) {
            Write-Host "   ✅ Connectivité OK ($elapsed)" -ForegroundColor $ColorSuccess
            return $true
        } else {
            Write-Host "   ❌ Erreur HTTP $($response.StatusCode) ($elapsed)" -ForegroundColor $ColorError
            return $false
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "   ❌ Erreur de connexion: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        return $false
    }
}

# Fonction pour tester l'API OpenAI compatible
function Test-OpenAICompatibility {
    param([string]$Endpoint, [string]$ApiKey)
    
    Write-Host "🤖 Test 2: Compatibilité API OpenAI" -ForegroundColor $ColorInfo
    $startTime = Get-Date
    
    try {
        # Test de l'endpoint /v1/models
        $modelsUrl = "$Endpoint/v1/models"
        $headers = @{}
        if ($ApiKey) {
            $headers["Authorization"] = "Bearer $ApiKey"
        }
        
        $response = Invoke-RestMethod -Uri $modelsUrl -Method Get -Headers $headers -TimeoutSec 10
        $elapsed = Get-ElapsedTime -StartTime $startTime
        
        if ($response -and $response.models) {
            Write-Host "   ✅ API /v1/models accessible ($elapsed)" -ForegroundColor $ColorSuccess
            Write-Host "   📋 Modèles disponibles:" -ForegroundColor $ColorInfo
            
            # Chercher Qwen3 dans la liste des modèles
            $qwenModels = $response.models | Where-Object { $_.id -like "*qwen*" -or $_.id -like "*Qwen*" }
            
            if ($qwenModels) {
                foreach ($model in $qwenModels) {
                    Write-Host "      - $($model.id)" -ForegroundColor $ColorSuccess
                }
            } else {
                Write-Host "   ⚠️ Aucun modèle Qwen détecté, affichage des 5 premiers modèles:" -ForegroundColor $ColorWarning
                for ($i = 0; $i -lt [Math]::Min(5, $response.models.Count); $i++) {
                    Write-Host "      - $($response.models[$i].id)" -ForegroundColor $ColorInfo
                }
            }
            return $true
        } else {
            Write-Host "   ❌ Réponse inattendue de /v1/models ($elapsed)" -ForegroundColor $ColorError
            if ($Verbose) { Write-Host "   Réponse: $response" -ForegroundColor $ColorWarning }
            return $false
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "   ❌ Erreur API /v1/models: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        return $false
    }
}

# Fonction pour tester les embeddings et dimensions
function Test-EmbeddingDimensions {
    param([string]$Endpoint, [string]$ApiKey)
    
    Write-Host "📏 Test 3: Dimensions des embeddings (attendu: 4096)" -ForegroundColor $ColorInfo
    $startTime = Get-Date
    
    try {
        # Test d'embedding avec un texte simple
        $embedUrl = "$Endpoint/v1/embeddings"
        $headers = @{}
        if ($ApiKey) {
            $headers["Authorization"] = "Bearer $ApiKey"
        }
        $headers["Content-Type"] = "application/json"
        
        $body = @{
            "input" = "Test de dimension Qwen3 8B"
            "model" = "qwen3:8b"  # Nom probable du modèle
        } | ConvertTo-Json -Depth 3
        
        Write-Host "   📤 Envoi de requête d'embedding..." -ForegroundColor $ColorInfo
        
        $response = Invoke-RestMethod -Uri $embedUrl -Method Post -Headers $headers -Body $body -TimeoutSec 30
        $elapsed = Get-ElapsedTime -StartTime $startTime
        
        if ($response -and $response.data) {
            $embedding = $response.data[0].embedding
            $dimensions = $embedding.Count
            
            Write-Host "   ✅ Embedding généré avec succès ($elapsed)" -ForegroundColor $ColorSuccess
            Write-Host "   📏 Dimensions: $dimensions" -ForegroundColor $(if ($dimensions -eq 4096) { $ColorSuccess } else { $ColorError })
            
            if ($dimensions -eq 4096) {
                Write-Host "   ✅ Dimensions correctes (4096)" -ForegroundColor $ColorSuccess
            } else {
                Write-Host "   ❌ Dimensions incorrectes (attendu: 4096, reçu: $dimensions)" -ForegroundColor $ColorError
            }
            
            # Afficher les premières et dernières dimensions pour vérification
            if ($Verbose) {
                Write-Host "   🔍 Premières dimensions: $($embedding[0..4] -join ', ')" -ForegroundColor $ColorWarning
                Write-Host "   🔍 Dernières dimensions: $($embedding[-5..-1] -join ', ')" -ForegroundColor $ColorWarning
            }
            
            return @{
                Success = ($dimensions -eq 4096)
                Dimensions = $dimensions
                ResponseTime = $elapsed
            }
        } else {
            Write-Host "   ❌ Réponse d'embedding invalide ($elapsed)" -ForegroundColor $ColorError
            if ($Verbose) { Write-Host "   Réponse: $response" -ForegroundColor $ColorWarning }
            return @{
                Success = $false
                Dimensions = 0
                ResponseTime = $elapsed
            }
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "   ❌ Erreur embedding: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        return @{
            Success = $false
            Dimensions = 0
            ResponseTime = $elapsed
        }
    }
}

# Fonction pour tester la performance
function Test-Performance {
    param([string]$Endpoint, [string]$ApiKey)
    
    Write-Host "⚡ Test 4: Performance (latence réseau)" -ForegroundColor $ColorInfo
    
    $tests = @()
    $testTexts = @(
        "Test court",
        "Test de performance avec un texte un peu plus long pour évaluer la latence du réseau et la vitesse de traitement du service Qwen3 8B distant",
        "Test très long avec beaucoup de contenu pour simuler une requête réelle d'embedding dans une application de production avec des documents volumineux"
    )
    
    for ($i = 0; $i -lt $testTexts.Count; $i++) {
        $text = $testTexts[$i]
        $textLength = $text.Length
        Write-Host "   📊 Test $($i+1)/$($testTexts.Count) ($textLength caractères)" -ForegroundColor $ColorInfo
        
        $startTime = Get-Date
        
        try {
            $embedUrl = "$Endpoint/v1/embeddings"
            $headers = @{}
            if ($ApiKey) {
                $headers["Authorization"] = "Bearer $ApiKey"
            }
            $headers["Content-Type"] = "application/json"
            
            $body = @{
                "input" = $text
                "model" = "qwen3:8b"
            } | ConvertTo-Json -Depth 3
            
            $response = Invoke-RestMethod -Uri $embedUrl -Method Post -Headers $headers -Body $body -TimeoutSec 30
            $elapsed = Get-ElapsedTime -StartTime $startTime
            
            if ($response -and $response.data) {
                $dimensions = $response.data[0].embedding.Count
                $tests += @{
                    Test = $i + 1
                    TextLength = $textLength
                    Dimensions = $dimensions
                    ResponseTime = $elapsed
                    Success = ($dimensions -eq 4096)
                }
                Write-Host "      ✅ $($dimensions) dimensions ($elapsed)" -ForegroundColor $(if ($dimensions -eq 4096) { $ColorSuccess } else { $ColorError })
            } else {
                $tests += @{
                    Test = $i + 1
                    TextLength = $textLength
                    Dimensions = 0
                    ResponseTime = $elapsed
                    Success = $false
                }
                Write-Host "      ❌ Échec ($elapsed)" -ForegroundColor $ColorError
            }
        }
        catch {
            $elapsed = Get-ElapsedTime -StartTime $startTime
            $tests += @{
                Test = $i + 1
                TextLength = $textLength
                Dimensions = 0
                ResponseTime = $elapsed
                Success = $false
            }
            Write-Host "      ❌ Erreur: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        }
    }
    
    # Calculer les statistiques
    $successRate = ($tests | Where-Object { $_.Success }).Count / $tests.Count * 100
    $avgResponseTime = "N/A"
    
    # Extraire le temps en secondes des temps formatés mm:ss.fff
    $validTimes = $tests | Where-Object { $_.Success -and $_.ResponseTime -match "^\d+:\d+\.\d+$" } | ForEach-Object {
        $parts = $_.ResponseTime -split ':'
        [double]$parts[0] * 60 + [double]$parts[1]
    }
    
    if ($validTimes.Count -gt 0) {
        $avgSeconds = ($validTimes | Measure-Object -Average).Average
        $avgResponseTime = "{0:F2}s" -f $avgSeconds
    }
    
    Write-Host "   📈 Statistiques:" -ForegroundColor $ColorInfo
    Write-Host "      Succès: $successRate% ($($tests | Where-Object { $_.Success }).Count/$($tests.Count))" -ForegroundColor $(if ($successRate -eq 100) { $ColorSuccess } else { $ColorWarning })
    Write-Host "      Temps moyen: $avgResponseTime" -ForegroundColor $ColorInfo
    
    return @{
        SuccessRate = $successRate
        AverageResponseTime = $avgResponseTime
        Tests = $tests
    }
}

# Programme principal
function Main {
    Write-Host "🔧 Configuration:" -ForegroundColor $ColorHeader
    Write-Host "   Endpoint: $Qwen3Endpoint" -ForegroundColor $ColorInfo
    Write-Host "   API Key: $(if ($ApiKey) { '***' + $ApiKey.Substring($ApiKey.Length-4) } else { 'Non fournie' })" -ForegroundColor $ColorInfo
    Write-Host "   Verbose: $Verbose" -ForegroundColor $ColorInfo
    Write-Host ""
    
    # Test 1: Connectivité de base
    $basicConnectivity = Test-BasicConnectivity -Endpoint $Qwen3Endpoint
    if (-not $basicConnectivity) {
        Write-Host "❌ Échec du test de connectivité de base. Arrêt." -ForegroundColor $ColorError
        exit 1
    }
    
    Write-Host ""
    
    # Test 2: Compatibilité API OpenAI
    $apiCompatibility = Test-OpenAICompatibility -Endpoint $Qwen3Endpoint -ApiKey $ApiKey
    if (-not $apiCompatibility) {
        Write-Host "❌ Échec du test de compatibilité API OpenAI. Arrêt." -ForegroundColor $ColorError
        exit 2
    }
    
    Write-Host ""
    
    # Test 3: Dimensions des embeddings
    $embeddingTest = Test-EmbeddingDimensions -Endpoint $Qwen3Endpoint -ApiKey $ApiKey
    Write-Host ""
    
    # Test 4: Performance
    $performanceTest = Test-Performance -Endpoint $Qwen3Endpoint -ApiKey $ApiKey
    Write-Host ""
    
    # Résultat final
    Write-Host "📋 RÉSULTAT FINAL" -ForegroundColor $ColorHeader
    Write-Host "=================" -ForegroundColor $ColorHeader
    
    $overallSuccess = $basicConnectivity -and $apiCompatibility -and $embeddingTest.Success
    
    if ($overallSuccess) {
        Write-Host "✅ SUCCÈS GLOBAL" -ForegroundColor $ColorSuccess
        Write-Host ""
        Write-Host "🎯 Service Qwen3 8B distant validé:" -ForegroundColor $ColorSuccess
        Write-Host "   • Connectivité: OK" -ForegroundColor $ColorSuccess
        Write-Host "   • API OpenAI: Compatible" -ForegroundColor $ColorSuccess
        Write-Host "   • Dimensions: $($embeddingTest.Dimensions) (attendu: 4096)" -ForegroundColor $ColorSuccess
        Write-Host "   • Performance: $($performanceTest.AverageResponseTime) moyen, $($performanceTest.SuccessRate)% succès" -ForegroundColor $ColorSuccess
        Write-Host ""
        Write-Host "🚀 Le service est prêt pour la migration Qdrant!" -ForegroundColor $ColorSuccess
        exit 0
    } else {
        Write-Host "❌ ÉCHEC GLOBAL" -ForegroundColor $ColorError
        Write-Host ""
        Write-Host "🔍 Problèmes identifiés:" -ForegroundColor $ColorError
        if (-not $basicConnectivity) { Write-Host "   • Connectivité de base échouée" -ForegroundColor $ColorError }
        if (-not $apiCompatibility) { Write-Host "   • API OpenAI non compatible" -ForegroundColor $ColorError }
        if (-not $embeddingTest.Success) { Write-Host "   • Dimensions incorrectes: $($embeddingTest.Dimensions) (attendu: 4096)" -ForegroundColor $ColorError }
        Write-Host ""
        Write-Host "🔧 Actions recommandées:" -ForegroundColor $ColorWarning
        Write-Host "   1. Vérifier l'URL du service Qwen3" -ForegroundColor $ColorInfo
        Write-Host "   2. Vérifier la clé API" -ForegroundColor $ColorInfo
        Write-Host "   3. Confirmer que le service Qwen3 est bien démarré" -ForegroundColor $ColorInfo
        Write-Host "   4. Vérifier la compatibilité API OpenAI" -ForegroundColor $ColorInfo
        exit 3
    }
}

# Exécution principale
try {
    Main
}
catch {
    Write-Host "💥 Erreur inattendue dans le script: $($_.Exception.Message)" -ForegroundColor $ColorError
    Write-Host "📍 Stack trace: $($_.ScriptStackTrace)" -ForegroundColor $ColorWarning
    exit 99
}