# Script de Test de Connectivité au Service Qwen3 8B Distant v2.0
# Date: 2025-11-06
# Objectif: Valider la connexion, compatibilité API OpenAI, dimensions 4096, et authentification avancée
# Améliorations: Tests d'authentification complets, validation de format, messages d'erreur spécifiques

param(
    [Parameter(Mandatory=$false)]
    [string]$Qwen3Endpoint = "http://localhost:11434",
    
    [Parameter(Mandatory=$false)]
    [string]$ApiKey = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$TestAuthScenarios = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipAuthValidation = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$Verbose = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$GenerateReport = $false
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
$ColorAuth = "Magenta"

# Variables globales pour le rapport
$TestResults = @()
$ScriptStartTime = Get-Date

Write-Host "🔍 TEST DE CONNECTIVITÉ QWEN3 8B DISTANT v2.0" -ForegroundColor $ColorHeader
Write-Host "=============================================" -ForegroundColor $ColorHeader
Write-Host "🔐 Améliorations: Tests d'authentification avancés" -ForegroundColor $ColorAuth
Write-Host ""

# Fonction pour afficher le temps écoulé
function Get-ElapsedTime {
    param([datetime]$StartTime)
    $elapsed = (Get-Date) - $StartTime
    return "{0:mm\:ss\.fff}" -f $elapsed
}

# Fonction pour masquer la clé API dans les logs
function Get-MaskedApiKey {
    param([string]$Key)
    if ([string]::IsNullOrEmpty($Key)) {
        return "Non fournie"
    }
    if ($Key.Length -le 8) {
        return "***" + $Key.Substring($Key.Length-3)
    }
    return $Key.Substring(0, 4) + "***" + $Key.Substring($Key.Length-4)
}

# Fonction pour valider le format de la clé API
function Test-ApiKeyFormat {
    param([string]$ApiKey)
    
    if ([string]::IsNullOrEmpty($ApiKey)) {
        return @{
            Valid = $false
            Message = "La clé API est vide ou manquante"
            Suggestion = "Fournir une clé API avec le paramètre -ApiKey"
        }
    }
    
    # Vérifier les formats courants
    $patterns = @(
        @{Pattern = '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'; Type = "UUID"; Description = "Format UUID standard"},
        @{Pattern = '^sk-[a-zA-Z0-9]{48}$'; Type = "OpenAI"; Description = "Format OpenAI (sk-...)"},
        @{Pattern = '^[a-zA-Z0-9]{32,64}$'; Type = "Token"; Description = "Token alphanumérique"},
        @{Pattern = '^qwen3-[a-zA-Z0-9_-]{20,}$'; Type = "Qwen3"; Description = "Format spécifique Qwen3"}
    )
    
    foreach ($p in $patterns) {
        if ($ApiKey -match $p.Pattern) {
            return @{
                Valid = $true
                Type = $p.Type
                Description = $p.Description
                Message = "Format valide: $($p.Description)"
            }
        }
    }
    
    return @{
        Valid = $false
        Message = "Format de clé API non reconnu"
        Suggestion = "Vérifier que la clé API est correcte (UUID, OpenAI, ou format Qwen3)"
    }
}

# Fonction pour ajouter un résultat au rapport
function Add-TestResult {
    param(
        [string]$TestName,
        [bool]$Success,
        [string]$Message,
        [string]$Details = "",
        [double]$ResponseTimeMs = 0
    )
    
    $result = @{
        TestName = $TestName
        Success = $Success
        Message = $Message
        Details = $Details
        ResponseTimeMs = $ResponseTimeMs
        Timestamp = Get-Date
    }
    
    $script:TestResults += $result
    
    if ($Verbose) {
        Write-Host "   📝 Résultat ajouté au rapport: $TestName" -ForegroundColor $ColorInfo
    }
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
            Add-TestResult -TestName "Connectivité de base" -Success $true -Message "Connectivité établie" -Details "HTTP 200, temps: $elapsed"
            return $true
        } else {
            Write-Host "   ❌ Erreur HTTP $($response.StatusCode) ($elapsed)" -ForegroundColor $ColorError
            Add-TestResult -TestName "Connectivité de base" -Success $false -Message "Erreur HTTP $($response.StatusCode)" -Details "Temps: $elapsed"
            return $false
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "   ❌ Erreur de connexion: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        Add-TestResult -TestName "Connectivité de base" -Success $false -Message "Erreur de connexion" -Details $($_.Exception.Message)
        return $false
    }
}

# Fonction pour tester la validation de clé API
function Test-ApiKeyValidation {
    param([string]$ApiKey)
    
    Write-Host "🔐 Test 2: Validation de la clé API" -ForegroundColor $ColorAuth
    $startTime = Get-Date
    
    $validation = Test-ApiKeyFormat -ApiKey $ApiKey
    $elapsed = Get-ElapsedTime -StartTime $startTime
    
    if ($validation.Valid) {
        Write-Host "   ✅ Clé API valide: $($validation.Description) ($elapsed)" -ForegroundColor $ColorSuccess
        Add-TestResult -TestName "Validation clé API" -Success $true -Message $validation.Message -Details "Type: $($validation.Type)"
        return $true
    } else {
        Write-Host "   ❌ Clé API invalide: $($validation.Message) ($elapsed)" -ForegroundColor $ColorError
        Write-Host "   💡 Suggestion: $($validation.Suggestion)" -ForegroundColor $ColorWarning
        Add-TestResult -TestName "Validation clé API" -Success $false -Message $validation.Message -Details $validation.Suggestion
        return $false
    }
}

# Fonction pour tester l'API OpenAI compatible avec authentification
function Test-OpenAICompatibility {
    param([string]$Endpoint, [string]$ApiKey)
    
    Write-Host "🤖 Test 3: Compatibilité API OpenAI avec authentification" -ForegroundColor $ColorInfo
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
            
            $modelList = ($response.models | ForEach-Object { $_.id }) -join ", "
            Add-TestResult -TestName "Compatibilité API OpenAI" -Success $true -Message "API /v1/models accessible" -Details "Modèles: $modelList"
            return $true
        } else {
            Write-Host "   ❌ Réponse inattendue de /v1/models ($elapsed)" -ForegroundColor $ColorError
            if ($Verbose) { Write-Host "   Réponse: $response" -ForegroundColor $ColorWarning }
            Add-TestResult -TestName "Compatibilité API OpenAI" -Success $false -Message "Réponse inattendue" -Details "Réponse: $response"
            return $false
        }
    }
    catch [System.Net.WebException] {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDesc = $_.Exception.Response.StatusDescription
        
        switch ($statusCode) {
            401 {
                Write-Host "   ❌ Erreur 401: Non autorisé - Clé API invalide ($elapsed)" -ForegroundColor $ColorError
                Write-Host "   💡 Vérifier que la clé API est correcte et active" -ForegroundColor $ColorWarning
                Add-TestResult -TestName "Compatibilité API OpenAI" -Success $false -Message "Erreur 401: Non autorisé" -Details "Clé API invalide ou expirée"
            }
            403 {
                Write-Host "   ❌ Erreur 403: Accès interdit - Permissions insuffisantes ($elapsed)" -ForegroundColor $ColorError
                Write-Host "   💡 Vérifier que la clé API a les permissions nécessaires" -ForegroundColor $ColorWarning
                Add-TestResult -TestName "Compatibilité API OpenAI" -Success $false -Message "Erreur 403: Accès interdit" -Details "Permissions insuffisantes"
            }
            429 {
                Write-Host "   ❌ Erreur 429: Trop de requêtes - Rate limiting ($elapsed)" -ForegroundColor $ColorError
                Write-Host "   💡 Attendre avant de réessayer ou vérifier les limites de taux" -ForegroundColor $ColorWarning
                Add-TestResult -TestName "Compatibilité API OpenAI" -Success $false -Message "Erreur 429: Rate limiting" -Details "Trop de requêtes"
            }
            default {
                Write-Host "   ❌ Erreur HTTP $statusCode`: $statusDesc ($elapsed)" -ForegroundColor $ColorError
                Add-TestResult -TestName "Compatibilité API OpenAI" -Success $false -Message "Erreur HTTP $statusCode" -Details $statusDesc
            }
        }
        return $false
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "   ❌ Erreur API /v1/models: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        Add-TestResult -TestName "Compatibilité API OpenAI" -Success $false -Message "Erreur inattendue" -Details $($_.Exception.Message)
        return $false
    }
}

# Fonction pour tester les scénarios d'authentification
function Test-AuthenticationScenarios {
    param([string]$Endpoint, [string]$ApiKey)
    
    Write-Host "🔐 Test 4: Scénarios d'authentification avancés" -ForegroundColor $ColorAuth
    $scenarios = @()
    
    # Scénario 1: Clé manquante
    Write-Host "   🧪 Scénario 4.1: Test sans clé API" -ForegroundColor $ColorInfo
    $startTime = Get-Date
    try {
        $modelsUrl = "$Endpoint/v1/models"
        $response = Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 10
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "      ⚠️ Succès inattendu sans clé API ($elapsed)" -ForegroundColor $ColorWarning
        $scenarios += @{ Scenario = "Clé manquante"; Success = $true; Message = "Service accessible sans authentification" }
    }
    catch [System.Net.WebException] {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 401) {
            Write-Host "      ✅ Erreur 401 attendue (authentification requise) ($elapsed)" -ForegroundColor $ColorSuccess
            $scenarios += @{ Scenario = "Clé manquante"; Success = $true; Message = "Authentification correctement requise" }
        } else {
            Write-Host "      ❌ Erreur inattendue: HTTP $statusCode ($elapsed)" -ForegroundColor $ColorError
            $scenarios += @{ Scenario = "Clé manquante"; Success = $false; Message = "Erreur HTTP $statusCode" }
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "      ❌ Erreur inattendue: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        $scenarios += @{ Scenario = "Clé manquante"; Success = $false; Message = $_.Exception.Message }
    }
    
    # Scénario 2: Clé invalide
    Write-Host "   🧪 Scénario 4.2: Test avec clé API invalide" -ForegroundColor $ColorInfo
    $startTime = Get-Date
    try {
        $modelsUrl = "$Endpoint/v1/models"
        $headers = @{ "Authorization" = "Bearer clé-invalide-12345" }
        $response = Invoke-RestMethod -Uri $modelsUrl -Method Get -Headers $headers -TimeoutSec 10
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "      ⚠️ Succès inattendu avec clé invalide ($elapsed)" -ForegroundColor $ColorWarning
        $scenarios += @{ Scenario = "Clé invalide"; Success = $false; Message = "Clé invalide acceptée (problème de sécurité)" }
    }
    catch [System.Net.WebException] {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 401) {
            Write-Host "      ✅ Erreur 401 attendue (clé invalide rejetée) ($elapsed)" -ForegroundColor $ColorSuccess
            $scenarios += @{ Scenario = "Clé invalide"; Success = $true; Message = "Clé invalide correctement rejetée" }
        } else {
            Write-Host "      ❌ Erreur inattendue: HTTP $statusCode ($elapsed)" -ForegroundColor $ColorError
            $scenarios += @{ Scenario = "Clé invalide"; Success = $false; Message = "Erreur HTTP $statusCode" }
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "      ❌ Erreur inattendue: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        $scenarios += @{ Scenario = "Clé invalide"; Success = $false; Message = $_.Exception.Message }
    }
    
    # Scénario 3: Clé mal formatée
    Write-Host "   🧪 Scénario 4.3: Test avec clé API mal formatée" -ForegroundColor $ColorInfo
    $startTime = Get-Date
    try {
        $modelsUrl = "$Endpoint/v1/models"
        $headers = @{ "Authorization" = "Bearer format-invalide" }
        $response = Invoke-RestMethod -Uri $modelsUrl -Method Get -Headers $headers -TimeoutSec 10
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "      ⚠️ Succès inattendu avec clé mal formatée ($elapsed)" -ForegroundColor $ColorWarning
        $scenarios += @{ Scenario = "Clé mal formatée"; Success = $false; Message = "Clé mal formatée acceptée (problème de sécurité)" }
    }
    catch [System.Net.WebException] {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 401) {
            Write-Host "      ✅ Erreur 401 attendue (clé mal formatée rejetée) ($elapsed)" -ForegroundColor $ColorSuccess
            $scenarios += @{ Scenario = "Clé mal formatée"; Success = $true; Message = "Clé mal formatée correctement rejetée" }
        } else {
            Write-Host "      ❌ Erreur inattendue: HTTP $statusCode ($elapsed)" -ForegroundColor $ColorError
            $scenarios += @{ Scenario = "Clé mal formatée"; Success = $false; Message = "Erreur HTTP $statusCode" }
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "      ❌ Erreur inattendue: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        $scenarios += @{ Scenario = "Clé mal formatée"; Success = $false; Message = $_.Exception.Message }
    }
    
    # Résumé des scénarios
    $successCount = ($scenarios | Where-Object { $_.Success }).Count
    $totalCount = $scenarios.Count
    $successRate = [math]::Round(($successCount / $totalCount) * 100, 1)
    
    Write-Host "   📊 Résumé des scénarios: $successCount/$totalCount réussis ($successRate%)" -ForegroundColor $(if ($successRate -eq 100) { $ColorSuccess } else { $ColorWarning })
    
    foreach ($scenario in $scenarios) {
        $status = if ($scenario.Success) { "✅" } else { "❌" }
        Write-Host "      $status $($scenario.Scenario): $($scenario.Message)" -ForegroundColor $(if ($scenario.Success) { $ColorSuccess } else { $ColorError })
    }
    
    Add-TestResult -TestName "Scénarios d'authentification" -Success ($successRate -eq 100) -Message "$successCount/$totalCount scénarios réussis" -Details "Taux de succès: $successRate%"
    
    return $successRate -eq 100
}

# Fonction pour tester les embeddings et dimensions
function Test-EmbeddingDimensions {
    param([string]$Endpoint, [string]$ApiKey)
    
    Write-Host "📏 Test 5: Dimensions des embeddings (attendu: 4096)" -ForegroundColor $ColorInfo
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
            "input" = "Test de dimension Qwen3 8B avec authentification"
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
            
            $result = @{
                Success = ($dimensions -eq 4096)
                Dimensions = $dimensions
                ResponseTime = $elapsed
            }
            
            Add-TestResult -TestName "Dimensions embeddings" -Success $result.Success -Message "Dimensions: $dimensions" -Details "Attendu: 4096, temps: $elapsed"
            return $result
        } else {
            Write-Host "   ❌ Réponse d'embedding invalide ($elapsed)" -ForegroundColor $ColorError
            if ($Verbose) { Write-Host "   Réponse: $response" -ForegroundColor $ColorWarning }
            Add-TestResult -TestName "Dimensions embeddings" -Success $false -Message "Réponse invalide" -Details "Réponse: $response"
            return @{
                Success = $false
                Dimensions = 0
                ResponseTime = $elapsed
            }
        }
    }
    catch [System.Net.WebException] {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDesc = $_.Exception.Response.StatusDescription
        
        switch ($statusCode) {
            401 {
                Write-Host "   ❌ Erreur 401: Non autorisé - Clé API invalide ($elapsed)" -ForegroundColor $ColorError
                Write-Host "   💡 Vérifier que la clé API est correcte pour les embeddings" -ForegroundColor $ColorWarning
            }
            403 {
                Write-Host "   ❌ Erreur 403: Accès interdit - Permissions insuffisantes ($elapsed)" -ForegroundColor $ColorError
                Write-Host "   💡 Vérifier que la clé API a les permissions pour les embeddings" -ForegroundColor $ColorWarning
            }
            429 {
                Write-Host "   ❌ Erreur 429: Trop de requêtes - Rate limiting ($elapsed)" -ForegroundColor $ColorError
                Write-Host "   💡 Attendre avant de réessayer les embeddings" -ForegroundColor $ColorWarning
            }
            default {
                Write-Host "   ❌ Erreur HTTP $statusCode`: $statusDesc ($elapsed)" -ForegroundColor $ColorError
            }
        }
        
        Add-TestResult -TestName "Dimensions embeddings" -Success $false -Message "Erreur HTTP $statusCode" -Details $statusDesc
        return @{
            Success = $false
            Dimensions = 0
            ResponseTime = $elapsed
        }
    }
    catch {
        $elapsed = Get-ElapsedTime -StartTime $startTime
        Write-Host "   ❌ Erreur embedding: $($_.Exception.Message) ($elapsed)" -ForegroundColor $ColorError
        Add-TestResult -TestName "Dimensions embeddings" -Success $false -Message "Erreur inattendue" -Details $($_.Exception.Message)
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
    
    Write-Host "⚡ Test 6: Performance (latence réseau)" -ForegroundColor $ColorInfo
    
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
    
    $result = @{
        SuccessRate = $successRate
        AverageResponseTime = $avgResponseTime
        Tests = $tests
    }
    
    Add-TestResult -TestName "Performance" -Success ($successRate -eq 100) -Message "Taux de succès: $successRate%" -Details "Temps moyen: $avgResponseTime"
    return $result
}

# Fonction pour générer un rapport détaillé
function New-TestReport {
    param([array]$Results, [string]$OutputPath = "")
    
    $report = @()
    $report += "# Rapport de Test Qwen3 v2.0 - Authentification Avancée"
    $report += ""
    $report += "Généré le: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += "Endpoint: $Qwen3Endpoint"
    $report += "Clé API: $(Get-MaskedApiKey -Key $ApiKey)"
    $report += ""
    
    # Résumé des tests
    $totalTests = $Results.Count
    $successTests = ($Results | Where-Object { $_.Success }).Count
    $successRate = if ($totalTests -gt 0) { [math]::Round(($successTests / $totalTests) * 100, 1) } else { 0 }
    
    $report += "## Résumé"
    $report += "- Tests totaux: $totalTests"
    $report += "- Tests réussis: $successTests"
    $report += "- Taux de succès: $successRate%"
    $report += ""
    
    # Détails des tests
    $report += "## Détails des Tests"
    $report += ""
    
    foreach ($result in $Results) {
        $status = if ($result.Success) { "✅ SUCCÈS" } else { "❌ ÉCHEC" }
        $report += "### $($result.TestName) - $status"
        $report += "- Message: $($result.Message)"
        if ($result.Details) {
            $report += "- Détails: $($result.Details)"
        }
        if ($result.ResponseTimeMs -gt 0) {
            $report += "- Temps de réponse: $($result.ResponseTimeMs)ms"
        }
        $report += "- Timestamp: $($result.Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))"
        $report += ""
    }
    
    # Recommandations
    $report += "## Recommandations"
    $failedTests = $Results | Where-Object { -not $_.Success }
    
    if ($failedTests.Count -eq 0) {
        $report += "✅ Tous les tests ont réussi. Le service Qwen3 est prêt pour la production."
    } else {
        $report += "⚠️ Certains tests ont échoué. Actions recommandées:"
        foreach ($failedTest in $failedTests) {
            $report += "- **$($failedTest.TestName)**: $($failedTest.Message)"
        }
    }
    
    $reportContent = $report -join "`n"
    
    if ($OutputPath) {
        $reportContent | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Host "📄 Rapport généré: $OutputPath" -ForegroundColor $ColorSuccess
    }
    
    return $reportContent
}

# Programme principal
function Main {
    Write-Host "🔧 Configuration:" -ForegroundColor $ColorHeader
    Write-Host "   Endpoint: $Qwen3Endpoint" -ForegroundColor $ColorInfo
    Write-Host "   API Key: $(Get-MaskedApiKey -Key $ApiKey)" -ForegroundColor $ColorInfo
    Write-Host "   Test Auth Scenarios: $TestAuthScenarios" -ForegroundColor $ColorInfo
    Write-Host "   Skip Auth Validation: $SkipAuthValidation" -ForegroundColor $ColorInfo
    Write-Host "   Verbose: $Verbose" -ForegroundColor $ColorInfo
    Write-Host "   Generate Report: $GenerateReport" -ForegroundColor $ColorInfo
    Write-Host ""
    
    # Test 1: Connectivité de base
    $basicConnectivity = Test-BasicConnectivity -Endpoint $Qwen3Endpoint
    if (-not $basicConnectivity) {
        Write-Host "❌ Échec du test de connectivité de base. Arrêt." -ForegroundColor $ColorError
        if ($GenerateReport) {
            New-TestReport -Results $TestResults -OutputPath "qwen3_test_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
        }
        exit 1
    }
    
    Write-Host ""
    
    # Test 2: Validation de la clé API (sauf si skip)
    $apiKeyValidation = $true
    if (-not $SkipAuthValidation) {
        $apiKeyValidation = Test-ApiKeyValidation -ApiKey $ApiKey
        if (-not $apiKeyValidation -and -not $TestAuthScenarios) {
            Write-Host "⚠️ Validation de clé API échouée, mais poursuite des tests..." -ForegroundColor $ColorWarning
        }
    } else {
        Write-Host "⏭️ Validation de clé API ignorée (SkipAuthValidation)" -ForegroundColor $ColorWarning
    }
    
    Write-Host ""
    
    # Test 3: Compatibilité API OpenAI
    $apiCompatibility = Test-OpenAICompatibility -Endpoint $Qwen3Endpoint -ApiKey $ApiKey
    if (-not $apiCompatibility) {
        Write-Host "❌ Échec du test de compatibilité API OpenAI. Arrêt." -ForegroundColor $ColorError
        if ($GenerateReport) {
            New-TestReport -Results $TestResults -OutputPath "qwen3_test_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
        }
        exit 2
    }
    
    Write-Host ""
    
    # Test 4: Scénarios d'authentification (optionnel)
    $authScenarios = $true
    if ($TestAuthScenarios) {
        $authScenarios = Test-AuthenticationScenarios -Endpoint $Qwen3Endpoint -ApiKey $ApiKey
        Write-Host ""
    }
    
    # Test 5: Dimensions des embeddings
    $embeddingTest = Test-EmbeddingDimensions -Endpoint $Qwen3Endpoint -ApiKey $ApiKey
    Write-Host ""
    
    # Test 6: Performance
    $performanceTest = Test-Performance -Endpoint $Qwen3Endpoint -ApiKey $ApiKey
    Write-Host ""
    
    # Résultat final
    Write-Host "📋 RÉSULTAT FINAL" -ForegroundColor $ColorHeader
    Write-Host "=================" -ForegroundColor $ColorHeader
    
    $overallSuccess = $basicConnectivity -and $apiCompatibility -and $embeddingTest.Success -and $authScenarios
    
    if ($overallSuccess) {
        Write-Host "✅ SUCCÈS GLOBAL" -ForegroundColor $ColorSuccess
        Write-Host ""
        Write-Host "🎯 Service Qwen3 8B distant validé:" -ForegroundColor $ColorSuccess
        Write-Host "   • Connectivité: OK" -ForegroundColor $ColorSuccess
        Write-Host "   • API OpenAI: Compatible" -ForegroundColor $ColorSuccess
        Write-Host "   • Authentification: $(if ($apiKeyValidation) { 'Validée' } else { 'À vérifier' })" -ForegroundColor $(if ($apiKeyValidation) { $ColorSuccess } else { $ColorWarning })
        if ($TestAuthScenarios) {
            Write-Host "   • Scénarios auth: OK" -ForegroundColor $ColorSuccess
        }
        Write-Host "   • Dimensions: $($embeddingTest.Dimensions) (attendu: 4096)" -ForegroundColor $ColorSuccess
        Write-Host "   • Performance: $($performanceTest.AverageResponseTime) moyen, $($performanceTest.SuccessRate)% succès" -ForegroundColor $ColorSuccess
        Write-Host ""
        Write-Host "🚀 Le service est prêt pour la migration Qdrant!" -ForegroundColor $ColorSuccess
        $exitCode = 0
    } else {
        Write-Host "❌ ÉCHEC GLOBAL" -ForegroundColor $ColorError
        Write-Host ""
        Write-Host "🔍 Problèmes identifiés:" -ForegroundColor $ColorError
        if (-not $basicConnectivity) { Write-Host "   • Connectivité de base échouée" -ForegroundColor $ColorError }
        if (-not $apiCompatibility) { Write-Host "   • API OpenAI non compatible" -ForegroundColor $ColorError }
        if (-not $apiKeyValidation) { Write-Host "   • Validation de clé API échouée" -ForegroundColor $ColorError }
        if (-not $authScenarios) { Write-Host "   • Scénarios d'authentification échoués" -ForegroundColor $ColorError }
        if (-not $embeddingTest.Success) { Write-Host "   • Dimensions incorrectes: $($embeddingTest.Dimensions) (attendu: 4096)" -ForegroundColor $ColorError }
        Write-Host ""
        Write-Host "🔧 Actions recommandées:" -ForegroundColor $ColorWarning
        Write-Host "   1. Vérifier l'URL du service Qwen3" -ForegroundColor $ColorInfo
        Write-Host "   2. Vérifier la clé API et son format" -ForegroundColor $ColorInfo
        Write-Host "   3. Confirmer que le service Qwen3 est bien démarré" -ForegroundColor $ColorInfo
        Write-Host "   4. Vérifier la compatibilité API OpenAI" -ForegroundColor $ColorInfo
        Write-Host "   5. Consulter les logs du service Qwen3 pour plus de détails" -ForegroundColor $ColorInfo
        $exitCode = 3
    }
    
    # Générer le rapport si demandé
    if ($GenerateReport) {
        $reportPath = "qwen3_test_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
        New-TestReport -Results $TestResults -OutputPath $reportPath
        Write-Host ""
        Write-Host "📊 Rapport détaillé disponible: $reportPath" -ForegroundColor $ColorInfo
    }
    
    exit $exitCode
}

# Exécution principale
try {
    Main
}
catch {
    Write-Host "💥 Erreur inattendue dans le script: $($_.Exception.Message)" -ForegroundColor $ColorError
    Write-Host "📍 Stack trace: $($_.ScriptStackTrace)" -ForegroundColor $ColorWarning
    
    if ($GenerateReport) {
        Add-TestResult -TestName "Erreur script" -Success $false -Message "Erreur inattendue" -Details $($_.Exception.Message)
        New-TestReport -Results $TestResults -OutputPath "qwen3_test_report_error_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
    }
    
    exit 99
}