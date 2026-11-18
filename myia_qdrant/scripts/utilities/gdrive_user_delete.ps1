# gdrive_user_delete.ps1 - suppression DEFINITIVE cote Drive, EN TANT QUE USER (Q8-b pivot, 2026-11-17)
#
# Contexte : la retention offsite rotte les snapshots hors keep-3. Via DriveFS (Remove-Item),
# chaque rotation part en CORBEILLE (~30-190 Go/nuit -> forfait 5 To sature, RX162). Mesure 17/11 :
# un SA ne peut pas posseder de fichiers (403 quota) -> impossible d'en faire l'uploader.
# PIVOT : l'upload reste DriveFS (fichiers du user) ; la SUPPRESSION passe par l'API Drive
# en tant que user : files.delete = suppression DEFINITIVE documentee, sans corbeille.
#
# Identifiants : refresh token OAuth user dans myia_qdrant/.gdrive_oauth.json (gitignore),
# obtenu ONE-SHOT via gdrive_oauth_consent.ps1. JAMAIS de token imprime (longueurs uniquement).
#
# Usage (PS 5.1 OK - pas de -SkipHttpErrorCheck, try/catch a la place) :
#   gdrive_user_delete.ps1 -DeleteDay 2026-11-14 [-Machine myia-ai-01] [-Collection ...]
#       -> supprime DEFINITIVEMENT <root>/<machine>/<collection>/<jour>/* + le dossier jour.
#          Idempotent : jour deja absent -> ALREADY_ABSENT exit 0. Garde : >10 items -> refus (exit 5).
#   gdrive_user_delete.ps1 -PurgeTrashSnapshots          -> LISTE les '*snapshot*' en corbeille (dry-run)
#   gdrive_user_delete.ps1 -PurgeTrashSnapshots -Execute -> les supprime DEFINITIVEMENT par ID
#      (chirurgical : uniquement les noms contenant 'snapshot' ; jamais d'emptyTrash global)
#
# GARDE EN AMONT (inchangee) : l'appelant (qdrant_snapshot_backup.ps1) ne lance la retention
# qu'APRES le SA gate (copies conservees confirmees server-side). Ce script ne supprime JAMAIS
# un dossier conserve par keep-3 : il ne connait que le dossier jour qu'on lui donne.
#
# Exit : 0 OK/absent ; 1 args ; 2 token absent ; 3 auth/reseau ; 5 garde/cap ou delete partiel ; 7 dossier introuvable.

param(
    [string]$DeleteDay = '',
    [switch]$PurgeTrashSnapshots,
    [switch]$Execute,
    [string]$Machine = '',
    [string]$Collection = 'roo_tasks_semantic_index',
    [string]$RootFolderId = '1XRXmorb4xmNq4JPxn7oFsKTVWdLOVobT',  # Backups-Cloud/qdrant-snapshots
    [string]$TokenFile = (Join-Path $PSScriptRoot '..\..\.gdrive_oauth.json')
)

$ErrorActionPreference = 'Stop'

if (-not $Machine) { $Machine = if ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLowerInvariant() } else { (hostname).ToLowerInvariant() } }
if (-not $DeleteDay -and -not $PurgeTrashSnapshots) { Write-Output 'ERROR: -DeleteDay ou -PurgeTrashSnapshots requis'; exit 1 }
if ($DeleteDay -and $DeleteDay -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Output "ERROR: -DeleteDay doit etre yyyy-MM-dd (recu: $DeleteDay)"; exit 1 }

# --- auth : refresh token -> access token ----------------------------------------
if (-not (Test-Path $TokenFile)) { Write-Output "ERROR: token OAuth absent ($TokenFile) - lancer gdrive_oauth_consent.ps1 d'abord"; exit 2 }
$tk = Get-Content $TokenFile -Raw | ConvertFrom-Json
try {
    $body = 'client_id=' + [uri]::EscapeDataString($tk.client_id) +
        '&client_secret=' + [uri]::EscapeDataString($tk.client_secret) +
        '&refresh_token=' + [uri]::EscapeDataString($tk.refresh_token) +
        '&grant_type=refresh_token'
    $acc = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' `
        -ContentType 'application/x-www-form-urlencoded' -Body $body -TimeoutSec 60
} catch { Write-Output "ERROR: rafraichissement token echoue : $($_.Exception.Message)"; exit 3 }
$script:H = @{ Authorization = "Bearer $($acc.access_token)" }
Write-Output "AUTH_OK: access token longueur $($acc.access_token.Length)"

# --- helpers (PS 5.1 compatible : try/catch, jamais -SkipHttpErrorCheck) -----------
function Find-Children([string]$Name, [string]$ParentId, [bool]$Folder) {
    $mi = if ($Folder) { " and mimeType='application/vnd.google-apps.folder'" } else { '' }
    $q = [uri]::EscapeDataString("name='$Name' and '$ParentId' in parents and trashed=false$mi")
    try {
        # NB 18/11 : sous PS 5.1 (l'appelant = powershell.exe), un PSCustomObject unique
        # n'a PAS de Count intrinseque (.Count = $null -> garde "-not .Count" vraie alors
        # que l'API avait tout renvoye, mesure passe 19:46 rc=7 x3). Le @() ICI ne suffit
        # PAS (le pipeline deroule les tableaux au retour) : c'est le @() AUX SITES
        # D'APPEL ci-dessous qui garantit Count=0/1/N et [0] corrects sur les 2 moteurs.
        return @((Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name,size)&pageSize=10" -Headers $script:H -TimeoutSec 60).files)
    } catch { Write-Output "ERROR: requete Drive echouee (name=$Name) : $($_.Exception.Message)"; exit 3 }
}
function Remove-ApiFile([string]$FileId, [string]$Label) {
    # 204 = supprime definitivement ; 404/410 = deja absent (idempotent) ; autre = echec.
    try {
        $r = Invoke-WebRequest -Method Delete -Uri "https://www.googleapis.com/drive/v3/files/$FileId" -Headers $script:H -TimeoutSec 120
        Write-Output "DELETED: $Label (HTTP $([int]$r.StatusCode))"
        return $true
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 404 -or $code -eq 410) { Write-Output "ALREADY_ABSENT: $Label (HTTP $code)"; return $true }
        Write-Output "DELETE_FAILED: $Label (HTTP $code) : $($_.Exception.Message)"
        return $false
    }
}

# --- mode 1 : purge chirurgicale de la corbeille (uniquement nos snapshots) -------
if ($PurgeTrashSnapshots) {
    # Relect. coord. 17/11 : 'name contains' de l'API Drive a une semantique de PREFIXE par
    # terme — '.snapshot' (avec point) peut rater des noms reels. On cherche 'snapshot' (plus
    # large), la chirurgicalite vient du dry-run : la liste est montree AVANT -Execute, et
    # 'screenshot' ne contient pas 'snapshot' (pas de faux positif de captures d'ecran).
    $q = [uri]::EscapeDataString("trashed=true and name contains 'snapshot'")
    $items = @()
    try {
        $page = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name,size)&pageSize=100" -Headers $script:H -TimeoutSec 60
        $items = @($page.files)
        while ($page.nextPageToken) {
            $page = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name,size)&pageSize=100&pageToken=$($page.nextPageToken)" -Headers $script:H -TimeoutSec 60
            $items += @($page.files)
        }
    } catch { Write-Output "ERROR: listage corbeille echoue : $($_.Exception.Message)"; exit 3 }
    Write-Output "TRASH_SNAPSHOTS: $($items.Count) item(s) 'snapshot' en corbeille"
    $total = 0L
    foreach ($i in $items) { Write-Output ("  {0} | {1} o" -f $i.name, $i.size); $total += [long]$i.size }
    Write-Output ("TOTAL: {0} octets ({1} Go)" -f $total, [Math]::Round($total/1GB, 2))
    if (-not $Execute) { Write-Output 'DRY-RUN : ajouter -Execute pour supprimer definitivement ces items.'; exit 0 }
    $fail = 0
    foreach ($i in $items) { if (-not (Remove-ApiFile $i.id $i.name)) { $fail++ } }
    if ($fail) { Write-Output "PARTIAL: $($fail)/$($items.Count) echecs - relancer"; exit 5 }
    Write-Output "PURGE_DONE: $($items.Count) items supprimes DEFINITIVEMENT de la corbeille"
    exit 0
}

# --- mode 2 : suppression definitive d'un dossier jour ------------------------------
$mDir = @(Find-Children $Machine $RootFolderId $true)
if (-not $mDir -or -not $mDir.Count) { Write-Output "ERROR: dossier machine '$Machine' introuvable sous $RootFolderId"; exit 7 }
$cDir = @(Find-Children $Collection $mDir[0].id $true)
if (-not $cDir -or -not $cDir.Count) { Write-Output "ERROR: dossier collection '$Collection' introuvable"; exit 7 }
$dDir = @(Find-Children $DeleteDay $cDir[0].id $true)
if (-not $dDir -or -not $dDir.Count) { Write-Output "ALREADY_ABSENT: dossier jour $DeleteDay introuvable (rien a faire)"; exit 0 }
$dayId = $dDir[0].id
Write-Output "TARGET: $Machine/$Collection/$DeleteDay -> $dayId"

$q2 = [uri]::EscapeDataString("'$dayId' in parents and trashed=false")
try {
    $kids = @((Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q2&fields=files(id,name,size,mimeType)&pageSize=100" -Headers $script:H -TimeoutSec 60).files)
} catch { Write-Output "ERROR: listage du dossier jour echoue : $($_.Exception.Message)"; exit 3 }

# Garde anti-mauvaise-cible : un dossier jour de rotation contient 1-2 snapshots ; >10 = inattendu.
if ($kids.Count -gt 10) {
    Write-Output "REFUSED: $($kids.Count) items dans le dossier jour (>10) - cible inattendue, investiguer avant"
    foreach ($k in $kids) { Write-Output "  $($k.name)" }
    exit 5
}
foreach ($k in $kids) { Write-Output ("  a supprimer : {0} | {1} o" -f $k.name, $k.size) }

$fail = 0
foreach ($k in $kids) { if (-not (Remove-ApiFile $k.id $k.name)) { $fail++ } }
if (-not (Remove-ApiFile $dayId "$DeleteDay (dossier)")) { $fail++ }

# Verification d'absence (preuve de preservation = keep-3 intact en amont, absence mesuree ici)
$chk = @(Find-Children $DeleteDay $cDir[0].id $true)
if ($chk -and $chk.Count) { Write-Output "ERROR: dossier jour $DeleteDay ENCORE present apres suppression"; exit 5 }
if ($fail) { Write-Output "PARTIAL: $fail echec(s) - relancer (idempotent)"; exit 5 }
Write-Output "DELETE_DONE: $Machine/$Collection/$DeleteDay supprime DEFINITIVEMENT (sans corbeille)"
exit 0
