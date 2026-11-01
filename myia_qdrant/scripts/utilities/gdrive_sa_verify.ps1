# gdrive_sa_verify.ps1 - Verification SERVER-SIDE des snapshots GDrive via compte de service (Q4-bis)
#
# Contexte (2026-11-01, ruling Q4-bis partie B) :
#   - SA "qdrant-backup-purger@myia-backups.iam.gserviceaccount.com" (projet GCP "myia-backups"),
#     cle JSON locale : <repo>/myia_qdrant/.gdrive_sa.json (gitignorer, JAMAIS commitee).
#   - Dossier partage : Backups-Cloud/qdrant-snapshots (Drive id 1XRXmorb4xmNq4JPxn7oFsKTVWdLOVobT),
#     role SA = Editeur (writer).
#   - MESURE (2026-11-01) : le SA peut LIRE l'arbre cote serveur (inventaire independant de DriveFS)
#     mais NE PEUT PAS supprimer les fichiers du user — capabilities canTrash=False / canDelete=False
#     (regle Google : un SA n'organise pas un Drive personnel). files.delete ET trashed=true => 403.
#     => la suppression definitive "par le SA" est IMPOSSIBLE en l'etat ; ce script ne fait que VERIFIER.
#     Piste complete (a arbitrer) : faire du SA l'UPLOADER (il devient proprietaire => canDelete vrai).
#
# Usage :
#   pwsh -File gdrive_sa_verify.ps1 -SnapshotName <file> [-ExpectedSizeBytes <n>]   # verif 1 fichier
#   pwsh -File gdrive_sa_verify.ps1 -Machine myia-ai-01                              # inventaire
#   pwsh -File gdrive_sa_verify.ps1 -WhatIfLike                                      # auth seule (dry-run)
#
# Sortie : texte loggable ; exit 0 = OK, 2 = absent/taille divergente, 3 = erreur auth/reseau, 4 = cle absente.
# Auto-relance : sous powershell.exe 5.1 (tache planifiee du backup), se relance via pwsh 7 (ImportFromPem
# n'existe pas en .NET Framework).

param(
    [string]$SnapshotName = '',
    [long]$ExpectedSizeBytes = -1,
    [string]$Machine = 'myia-ai-01',
    [string]$RootFolderId = '1XRXmorb4xmNq4JPxn7oFsKTVWdLOVobT',  # Backups-Cloud/qdrant-snapshots
    [switch]$WhatIfLike,
    [string]$SaKeyPath = (Join-Path $PSScriptRoot '..\..\.gdrive_sa.json')
)

$ErrorActionPreference = 'Stop'

# --- relance pwsh 7 si appele depuis Windows PowerShell 5.1 -------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { Write-Output 'ERROR: pwsh 7 requis (ImportFromPem) et introuvable'; exit 3 }
    # NB : -File et les tableaux de parametres se mordent la queue entre 5.1 et 7 (args vides /
    # valeurs negaives) — on passe par -Command, valeurs simples sans apostrophe.
    $sPath = $PSCommandPath.Replace("'", "''")
    $cmd = "& '$sPath' -ExpectedSizeBytes $ExpectedSizeBytes -Machine '$Machine' -RootFolderId '$RootFolderId' -SaKeyPath '$SaKeyPath'"
    if ($SnapshotName) { $cmd += " -SnapshotName '$($SnapshotName.Replace("'","''"))'" }
    if ($WhatIfLike)   { $cmd += ' -WhatIfLike' }
    & $pwsh -NoProfile -Command $cmd
    exit $LASTEXITCODE
}

if (-not (Test-Path $SaKeyPath)) { Write-Output "ERROR: cle SA absente: $SaKeyPath"; exit 4 }

# --- JWT RS256 -> access token (aucun secret n'est imprime) -------------------
function ConvertTo-B64Url([byte[]]$b) {
    [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')
}
$sa = Get-Content $SaKeyPath -Raw | ConvertFrom-Json
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$header = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
$claim  = @{ iss = $sa.client_email
             scope = 'https://www.googleapis.com/auth/drive'
             aud = 'https://oauth2.googleapis.com/token'
             exp = $now + 600; iat = $now } | ConvertTo-Json -Compress
$h = ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($header))
$c = ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($claim))
$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportFromPem($sa.private_key.Trim())
$sig = ConvertTo-B64Url ($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$h.$c"),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1))
try {
    $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$h.$c.$sig" -TimeoutSec 60
} catch { Write-Output "ERROR: echange jeton echoue: $($_.Exception.Message)"; exit 3 }
$hdr = @{ Authorization = "Bearer $($tok.access_token)" }

if ($WhatIfLike) { Write-Output "AUTH OK (SA=$($sa.client_email))"; exit 0 }

try {
    if ($SnapshotName) {
        # recherche par nom GLOBAL (les snapshots sont a 4 niveaux : racine/machine/collection/date/fichier ;
        # Drive n'a pas de requete recursive). Les noms portent collection + UUID + horodatage => uniques.
        $q = [uri]::EscapeDataString("name='$SnapshotName' and trashed=false")
        $r = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name,size,modifiedTime)&pageSize=5" -Headers $hdr -TimeoutSec 60
        if (-not $r.files.Count) { Write-Output "SAVERIFY: ABSENT server-side: $SnapshotName"; exit 2 }
        $f = $r.files[0]
        if ($ExpectedSizeBytes -ge 0 -and [long]$f.size -ne $ExpectedSizeBytes) {
            Write-Output "SAVERIFY: TAILLE DIVERGENTE: $SnapshotName drive=$($f.size) attendu=$ExpectedSizeBytes"
            exit 2
        }
        Write-Output "SAVERIFY: OK $SnapshotName (drive=$($f.size) o, modifie $($f.modifiedTime))"
        exit 0
    } else {
        # inventaire : machine -> collections -> fichiers (2 niveaux de parcours)
        $q = [uri]::EscapeDataString("name='$Machine' and '$RootFolderId' in parents and trashed=false")
        $r = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name)" -Headers $hdr -TimeoutSec 60
        if (-not $r.files.Count) { Write-Output "SAVERIFY: sous-dossier machine absent: $Machine"; exit 2 }
        $machId = $r.files[0].id
        $q2 = [uri]::EscapeDataString("'$machId' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false")
        $colls = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q2&fields=files(id,name)&pageSize=50" -Headers $hdr -TimeoutSec 60
        $nFiles = 0; $total = 0L; $newest = @()
        foreach ($coll in $colls.files) {
            $q3 = [uri]::EscapeDataString("'$($coll.id)' in parents and trashed=false")
            $dates = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q3&fields=files(id,name)&pageSize=100" -Headers $hdr -TimeoutSec 60
            foreach ($d in $dates.files) {
                $q4 = [uri]::EscapeDataString("'$($d.id)' in parents and trashed=false")
                $fl = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files?q=$q4&fields=files(id,name,size,modifiedTime)&pageSize=100" -Headers $hdr -TimeoutSec 60
                foreach ($file in $fl.files) { $nFiles++; $total += [long]$file.size; $newest += $file }
            }
        }
        Write-Output "SAVERIFY: $Machine = $nFiles fichiers server-side, $total o au total"
        $newest | Sort-Object modifiedTime -Descending | Select-Object -First 3 | ForEach-Object { "  - $($_.name) ($($_.size) o, $($_.modifiedTime))" }
        exit 0
    }
} catch {
    Write-Output "ERROR: appel Drive echoue: $($_.Exception.Message)"; exit 3
}
