# gdrive_user_upload.ps1 - upload offsite DIRECT via API Drive, EN TANT QUE USER (direction user 17/11)
#
# Contexte : le transit offsite passait par le montage DriveFS (G:) — chaque nuit y paie un 2e
# transit de ~190 Go par le cache C:, et l'upload peut echouer SILENCIEUSEMENT (mesure 17/11 :
# copie du jour presente en local G:, JAMAIS arrivee cote serveur, cache purges — classe
# 2026-09-03 ; la SA gate a correctement bloque la retention). Direction user (GO keep=1,
# Maintenance 17/11) : « upload vers Drive sans passer par le montage G:/DriveFS (API/rclone
# direct depuis le disque) ». Ce script fait l'upload resumable avec le token OAuth user
# (meme fichier .gdrive_oauth.json que gdrive_user_delete.ps1).
#
# Usage : gdrive_user_upload.ps1 -Upload <fichierLocal> [-Day yyyy-MM-dd] [-Machine m] [-Collection c]
#   Cree <root>/<machine>/<collection>/<jour>/ manquants, upload en tranches resumable 64 MiB,
#   reprise sur echec (interrogation de session 308 + Range), verification finale server-side.
#   Idempotent : fichier de meme taille deja present -> ALREADY_THERE exit 0 (jamais de doublon).
#
# Exit : 0 OK/already ; 1 args ; 2 divergent ; 3 auth/reseau/session ; 5 upload incomplet.

param(
    [Parameter(Mandatory = $true)][string]$Upload = '',
    [string]$Day = '',
    [string]$Machine = '',
    [string]$Collection = 'roo_tasks_semantic_index',
    [string]$RootFolderId = '1XRXmorb4xmNq4JPxn7oFsKTVWdLOVobT',
    [int]$ChunkMiB = 64,
    [string]$TokenFile = (Join-Path $PSScriptRoot '..\..\.gdrive_oauth.json')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Upload)) { Write-Output "ERROR: fichier local absent: $Upload"; exit 1 }
if (-not $Machine) { $Machine = if ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLowerInvariant() } else { (hostname).ToLowerInvariant() } }
if (-not $Day) { $Day = Get-Date -Format 'yyyy-MM-dd' }
if ($Day -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Output "ERROR: -Day doit etre yyyy-MM-dd (recu: $Day)"; exit 1 }

# --- auth user (refresh token) ------------------------------------------------------
if (-not (Test-Path $TokenFile)) { Write-Output "ERROR: token OAuth absent ($TokenFile)"; exit 3 }
$tk = Get-Content $TokenFile -Raw | ConvertFrom-Json
try {
    $acc = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body ('client_id=' + [uri]::EscapeDataString($tk.client_id) + '&client_secret=' + [uri]::EscapeDataString($tk.client_secret) + '&refresh_token=' + [uri]::EscapeDataString($tk.refresh_token) + '&grant_type=refresh_token') -TimeoutSec 60
} catch { Write-Output "ERROR: rafraichissement token echoue : $($_.Exception.Message)"; exit 3 }
$script:H = @{ Authorization = "Bearer $($acc.access_token)" }
Write-Output "AUTH_OK: access token longueur $($acc.access_token.Length)"

function Find-ChildByName([string]$Name, [string]$ParentId, [bool]$Folder) {
    $mi = if ($Folder) { " and mimeType='application/vnd.google-apps.folder'" } else { '' }
    $q = [uri]::EscapeDataString("name='$Name' and '$ParentId' in parents and trashed=false$mi")
    try { return (Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name,size)&pageSize=10" -Headers $script:H -TimeoutSec 60).files }
    catch { Write-Output "ERROR: requete Drive echouee (name=$Name) : $($_.Exception.Message)"; exit 3 }
}

# --- resolution/creation du chemin racine/machine/collection/jour --------------------
$cur = $RootFolderId
foreach ($name in @($Machine, $Collection, $Day)) {
    $found = Find-ChildByName $name $cur $true
    if ($found -and $found.Count) { $cur = $found[0].id }
    else {
        $meta = @{ name = $name; mimeType = 'application/vnd.google-apps.folder'; parents = @($cur) } | ConvertTo-Json -Compress
        try { $r = Invoke-RestMethod -Method Post -Uri 'https://www.googleapis.com/drive/v3/files' -ContentType 'application/json; charset=UTF-8' -Headers $script:H -Body $meta -TimeoutSec 60 }
        catch { Write-Output "ERROR: creation dossier '$name' echouee : $($_.Exception.Message)"; exit 3 }
        Write-Output "FOLDER_CREATED: $name"
        $cur = $r.id
    }
}
$dayFolderId = $cur
Write-Output "DAY_FOLDER: $Machine/$Collection/$Day -> $dayFolderId"

# --- idempotence : jamais deux envois du meme nom ------------------------------------
$leaf = Split-Path $Upload -Leaf
$localSize = (Get-Item $Upload).Length
$existing = Find-ChildByName $leaf $dayFolderId $false
if ($existing -and $existing.Count) {
    $srv = [long]$existing[0].size
    if ($srv -eq $localSize) { Write-Output "ALREADY_THERE: $leaf (server $srv o == local) — AUCUN envoi duplique"; exit 0 }
    Write-Output "DIVERGENT: $leaf server=$srv local=$localSize — ABORT (investiguer, ne pas ecraser)"; exit 2
}

# --- session resumable (POST -> 200 + Location) ---------------------------------------
$meta2 = @{ name = $leaf; parents = @($dayFolderId) } | ConvertTo-Json -Compress
try { $r = Invoke-WebRequest -Method Post -Uri 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,size' -Headers $script:H -ContentType 'application/json; charset=UTF-8' -Body $meta2 -TimeoutSec 120 }
catch { Write-Output "ERROR: session resumable refusee : $($_.Exception.Message)"; exit 3 }
$sessionUri = @($r.Headers['Location'])[0]
if (-not $sessionUri) { Write-Output 'ERROR: pas de session URI (Location absent)'; exit 3 }
Write-Output "SESSION_OK: resumable, chunk=$ChunkMiB MiB, total=$localSize o"

# --- PUT par tranches, statut VERIFIE, reprise 308 ------------------------------------
# (lecons du 17/11 matinee : toujours verifier le statut — un 4xx silencieux bouclerait
#  "avec succes" sans rien envoyer ; en 5.1 comme en 7, un statut d'echec leve, on le lit)
$chunkBytes = $ChunkMiB * 1MB
$fs = [IO.File]::OpenRead((Resolve-Path $Upload).Path)
$buf = New-Object byte[] $chunkBytes
$offset = 0L; $chunkIdx = 0; $failStreak = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    while ($offset -lt $localSize) {
        # Min en long PUIS cast : $localSize (187 Go) depasse Int32.Max — le cast direct
        # echouait (mesure 17/11 soir) ; le resultat est <= $chunkBytes (64 MiB, tient en int).
        $toRead = [Math]::Min([long]$chunkBytes, $localSize - $offset)
        $read = $fs.Read($buf, 0, [int]$toRead)
        if ($read -le 0) { Write-Output "ERROR: lecture a 0 octet a offset $offset"; exit 5 }
        $data = if ($read -eq $buf.Length) { $buf } else { $d2 = New-Object byte[] $read; [Array]::Copy($buf, $d2, $read); $d2 }
        $last = $offset + $read - 1
        $status = 0
        try {
            $resp = Invoke-WebRequest -Method Put -Uri $sessionUri -Headers @{ 'Content-Range' = "bytes $offset-$last/$localSize" } -ContentType 'application/octet-stream' -Body $data -TimeoutSec 900
            $status = [int]$resp.StatusCode
        } catch {
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } else { $status = -1 }
        }
        if ($status -eq 308 -or ($status -ge 200 -and $status -lt 300)) {
            $failStreak = 0
            $offset += $read; $chunkIdx++
            if ($chunkIdx % 32 -eq 0) {
                $pct = [Math]::Round(100 * $offset / $localSize, 1)
                $mbs = [Math]::Round(($offset/1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 1), 1)
                Write-Output "PROGRESS: $pct % ($offset o, $mbs MiB/s)"
            }
            continue
        }
        # echec HTTP : streak borne, reprise par interrogation de session
        $failStreak++
        if ($failStreak -ge 5) { Write-Output "ERROR: 5 echecs consecutifs a offset $offset (dernier statut $status)"; exit 5 }
        Start-Sleep -Seconds (10 * $failStreak)
        try {
            $st = Invoke-WebRequest -Method Put -Uri $sessionUri -Headers @{ 'Content-Range' = "bytes */$localSize" } -TimeoutSec 120
            if ([int]$st.StatusCode -eq 308) {
                $rng = @($st.Headers['Range'])[0]
                if ($rng -match 'bytes=0-(\d+)') { $rcv = [long]$Matches[1] + 1; if ($rcv -ne $offset) { $offset = $rcv; $fs.Position = $rcv; continue } }
            }
        } catch {}
        $fs.Position = $offset
    }
} finally { $fs.Close() }

# --- verification finale server-side ---------------------------------------------------
$fin = Find-ChildByName $leaf $dayFolderId $false
if (-not $fin -or -not $fin.Count) { Write-Output "ERROR: fichier absent apres upload (indexation Drive possible — reverifier avant de relancer, l'envoi est idempotent par taille)"; exit 5 }
$srvSize = [long]$fin[0].size
if ($srvSize -ne $localSize) { Write-Output "ERROR: taille finale divergente server=$srvSize local=$localSize"; exit 2 }
Write-Output "UPLOAD_DONE: $leaf server=$srvSize o en $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min"
exit 0
