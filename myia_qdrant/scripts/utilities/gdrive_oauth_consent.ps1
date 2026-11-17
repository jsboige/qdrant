# gdrive_oauth_consent.ps1 - consentement OAuth user ONE-SHOT (Q8-b pivot, 2026-11-17)
#
# Contexte : la retention offsite doit supprimer DEFINITIVEMENT (files.delete, sans corbeille)
# les snapshots rottes hors keep-3. Mesure 17/11 : un SA ne peut pas posseder de fichiers
# (403 Storage Quota Exceeded, My Drive consommateur) -> il faut supprimer EN TANT QUE USER.
# files.delete avec les identifiants du user = suppression permanente documentee.
#
# Ce helper fait le consentement ONE-SHOT (flow loopback IP, officiellement supporte pour
# les clients "Desktop app") :
#   1. lit client_id/client_secret depuis .gdrive_oauth_client.json (gitignore) ou les params
#   2. ouvre le navigateur sur l'ecran de consentement Google (scope drive complet)
#   3. capture le code d'autorisation via HttpListener sur http://localhost:8477/
#   4. l'echange contre un refresh token, ecrit .gdrive_oauth.json (gitignore)
#   5. verifie par un files.list inoffensif
#
# JAMAIS de token imprime (longueurs uniquement). Fichiers ecrits :
#   myia_qdrant/.gdrive_oauth.json = { client_id, client_secret, refresh_token }
#
# Usage : gdrive_oauth_consent.ps1 [-ClientId <id> -ClientSecret <secret>]
# Exit : 0 OK ; 1 client absent ; 2 callback timeout/annule ; 3 echange echoue ; 4 verification echouee.

param(
    [string]$ClientId = '',
    [string]$ClientSecret = '',
    [string]$ClientFile = (Join-Path $PSScriptRoot '..\..\.gdrive_oauth_client.json'),
    [string]$TokenFile  = (Join-Path $PSScriptRoot '..\..\.gdrive_oauth.json'),
    [int]$CallbackPort = 8477,
    [int]$TimeoutSec   = 300
)

$ErrorActionPreference = 'Stop'

# --- source des identifiants client -------------------------------------------
if (-not $ClientId -or -not $ClientSecret) {
    if (Test-Path $ClientFile) {
        $c = Get-Content $ClientFile -Raw | ConvertFrom-Json
        if (-not $ClientId)      { $ClientId     = $c.client_id }
        if (-not $ClientSecret)  { $ClientSecret = $c.client_secret }
    }
}
if (-not $ClientId -or -not $ClientSecret) {
    Write-Output 'ERROR: client_id/client_secret absents (params ou .gdrive_oauth_client.json).'
    Write-Output "       Creez un client OAuth 'Application de bureau' dans le projet GCP myia-backups,"
    Write-Output "       puis collez {\"client_id\":\"...\",\"client_secret\":\"...\"} dans : $ClientFile"
    exit 1
}

$scope      = 'https://www.googleapis.com/auth/drive'
$redirectUri = "http://localhost:$CallbackPort/"
# Construction par concatenation simple (PS 5.1 et 7 — pas de Join-String, absent de 5.1)
$authUrl = 'https://accounts.google.com/o/oauth2/v2/auth' + '?client_id=' + [uri]::EscapeDataString($ClientId) +
    '&redirect_uri=' + [uri]::EscapeDataString($redirectUri) + '&response_type=code' +
    '&scope=' + [uri]::EscapeDataString($scope) + '&access_type=offline&prompt=consent'

# --- ecouteur loopback AVANT d'ouvrir le navigateur ----------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($redirectUri)
try { $listener.Start() } catch { Write-Output "ERROR: impossible d'ecouter $redirectUri : $($_.Exception.Message)"; exit 2 }

Write-Output "CONSENT_URL ouverte dans le navigateur (port $CallbackPort, timeout $TimeoutSec s)..."
Write-Output "  Compte attendu : le titulaire du Drive (jsboige@gmail.com)."
Write-Output "  Permission demandee : voir/modifier/supprimer DEFINITIVEMENT les fichiers Drive."
Start-Process $authUrl

# --- capture du code ------------------------------------------------------------
# Bug 17/11 (relect. coord.) : GetContextAsync() appele a CHAQUE tour sans reutiliser la
# tache en attente — les appels abandonnes restent en file chez HttpListener et la requete
# du navigateur part au plus ancien, jamais lu -> navigateur pendu sur localhost et timeout
# (exit 2). Correctif : la tache est creee UNE fois avant la boucle ; on ne la recree jamais
# (on sort de la boucle des qu'une requete arrive).
$code = $null
$ctxTask = $listener.GetContextAsync()
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    if (-not $listener.IsListening) { break }
    $done = $ctxTask.AsyncWaitHandle.WaitOne(1000)
    if (-not $done) { continue }
    $ctx = $ctxTask.Result
    $resp = $ctx.Response
    $html = '<html><body><h3>OK - retour au terminal possible.</h3><p>Code capture ; cette fenetre peut etre fermee.</p></body></html>'
    $buf = [Text.Encoding]::UTF8.GetBytes($html)
    $resp.ContentType = 'text/html; charset=UTF-8'
    $resp.ContentLength64 = $buf.Length
    $resp.OutputStream.Write($buf, 0, $buf.Length)
    $resp.OutputStream.Close()
    if ($ctx.Request.QueryString['error']) {
        Write-Output "ERROR: consentement refuse : $($ctx.Request.QueryString['error'])"
        $listener.Stop(); exit 2
    }
    $code = $ctx.Request.QueryString['code']
    break
}
try { $listener.Stop() } catch {}
if (-not $code) { Write-Output 'ERROR: aucun code recu (timeout ou annulation).'; exit 2 }

# --- echange code -> refresh token ---------------------------------------------
try {
    $body = 'code=' + [uri]::EscapeDataString($code) +
        '&client_id=' + [uri]::EscapeDataString($ClientId) +
        '&client_secret=' + [uri]::EscapeDataString($ClientSecret) +
        '&redirect_uri=' + [uri]::EscapeDataString($redirectUri) +
        '&grant_type=authorization_code'
    $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' `
        -ContentType 'application/x-www-form-urlencoded' -Body $body -TimeoutSec 60
} catch { Write-Output "ERROR: echange code echoue : $($_.Exception.Message)"; exit 3 }
if (-not $tok.refresh_token) {
    Write-Output 'ERROR: pas de refresh_token dans la reponse (re-consentir avec prompt=consent).'
    Write-Output ("  cles recues : " + (($tok.PSObject.Properties.Name) -join ', '))
    exit 3
}

# --- ecriture du fichier token (JAMAIS imprime) ---------------------------------
$out = [ordered]@{
    client_id     = $ClientId
    client_secret = $ClientSecret
    refresh_token = $tok.refresh_token
    granted_scope = $tok.scope
    obtained_utc  = (Get-Date).ToUniversalTime().ToString('o')
}
[System.IO.File]::WriteAllText($TokenFile, ($out | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
Write-Output "TOKEN_FILE ecrit : $TokenFile (refresh_token longueur $($tok.refresh_token.Length), jamais affiche)"

# --- verification inoffensive ----------------------------------------------------
try {
    $vbody = 'client_id=' + [uri]::EscapeDataString($ClientId) +
        '&client_secret=' + [uri]::EscapeDataString($ClientSecret) +
        '&refresh_token=' + [uri]::EscapeDataString($tok.refresh_token) +
        '&grant_type=refresh_token'
    $acc = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' `
        -ContentType 'application/x-www-form-urlencoded' -Body $vbody -TimeoutSec 60
    $H = @{ Authorization = "Bearer $($acc.access_token)" }
    $lst = Invoke-RestMethod -Uri 'https://www.googleapis.com/drive/v3/files?pageSize=1&fields=files(id)' -Headers $H -TimeoutSec 60
    Write-Output "VERIFY_OK: refresh->access (longueur $($acc.access_token.Length)) + files.list repond."
    Write-Output 'PRET : gdrive_user_delete.ps1 peut maintenant supprimer definitivement.'
    exit 0
} catch { Write-Output "ERROR: verification echouee : $($_.Exception.Message)"; exit 4 }
