<#
.SYNOPSIS
    Monte le VHDX Qdrant dans WSL Ubuntu sur /mnt/qdrant-e + restart qdrant_production (idempotent, requis au boot).
.DESCRIPTION
    Sequence reproductible apres redemarrage Windows :
      1) Mount-VHD E:\wsl-data\qdrant.vhdx (Hyper-V)
      2) wsl --mount \\.\PHYSICALDRIVEN --bare (expose dans WSL)
      3) blkid -L qdrant-e pour identifier /dev/sdX
      4) mount /dev/sdX /mnt/qdrant-e dans Ubuntu
      5) Wait Docker ready + docker compose down/up qdrant_production (refresh bind-mount cache)
      6) Verification finale : 62 collections via API
    Script idempotent : si tout est deja OK, exit 0 sans toucher.
    Necessite Admin (Mount-VHD + wsl --mount).
.CATEGORY
    maintenance
.REQUIRES
    Admin
.MACHINES
    myia-ai-01
.EXAMPLE
    # Manuel (UAC popup) :
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File 'G:\Mon Drive\Maintenance\maintenance\wsl\mount_qdrant_vhdx.ps1'"

    # Au logon via Task Scheduler (avec privileges Admin):
    schtasks /create /tn "Mount-Qdrant-VHDX" /tr "powershell -ExecutionPolicy Bypass -File 'C:\ProgramData\maint-scripts\mount_qdrant_vhdx.ps1'" /sc onlogon /rl HIGHEST /ru "MYIA-AI-01\jsboige"
.NOTES
    Cree le 2026-04-27 apres migration Qdrant -> VHDX.
    Update 2026-05-04 (postmortem 5e hang Docker) :
      - Phase 4 : utilise fstab (mount $MountPoint) au lieu de mount $deviceFound (split WSL session bug)
      - Phase 6 : verifie UNC \\wsl.localhost\Ubuntu\... accessible avant compose up (docker info insuffisant)
    Update 2026-05-24 (post-GPU-crash drift : auto-remediation etait CASSEE, exit 0x8) :
      - Phase 4 : monte dans la namespace de PID 1 (systemd) via `nsenter -t 1 -m -- mount`
                  (Docker resout les binds depuis la ns de PID 1, pas une session wsl fraiche)
                  + `mount --make-shared` (le mount nsenter brut est PRIVATE -> pas de propagation /mnt/wsl).
      - Phase 5 : verifie le DEVICE par label (findmnt SOURCE -> blkid LABEL == qdrant-e), pas juste
                  collection-count>0. Le rootfs leftover avait ~14 dirs de collections et PASSAIT l'ancien
                  check -> bind du mauvais store. Mauvais label => refus anti-split-brain (exit 6/2008).
      - Phase 6 : nettoyage SELECTIF des shims docker-desktop-bind-mounts qdrant stale entre down et up
                  (compose down ne les enleve pas ; ils restent colles au rootfs /dev/sdd). Filtre ROBUSTE :
                  source mountinfo contient "qdrant_data" ET device != device du VHDX -> ne nettoie que les
                  shims qdrant DRIFTES (sur rootfs), GARDE les sains (sur le VHDX), ne touche jamais les ~8
                  shims open-webui/vllm. NB: la source d'un shim qdrant sain est "/qdrant_data/storage"
                  (chemin DANS le fs qdrant-e), pas "/mnt/qdrant-e/qdrant_data/storage" -> un match par prefixe
                  $MountPoint echouerait. C'est le root-cause : le fix "compose recreate" documente etait INCOMPLET sans ca.
    Le mount n'est PAS persistant a travers les reboots Windows : VHDX se detache, /dev/sdX disparait.
    Ce script doit etre rejoue a chaque boot/logon avant que qdrant_production ne fonctionne.
    REQUIS : /etc/fstab dans Ubuntu doit contenir l'entree qdrant-e (cf. CLAUDE.md "Persistent in-Ubuntu mount via /etc/fstab").
    REQUIS : /etc/wsl.conf doit contenir [boot] systemd=true (sinon fstab ignore).

    Update 2026-11-24 (Maintenance #380 -- fail-closed avant le compose down/up) : l'ancien bloc
    decidait un recreate quand le healthcheck n'etait pas "healthy" (moteur Docker injoignable,
    healthcheck "starting", docker inspect en echec) ou quand le compteur de collections etait
    illisible (fallback "0"). Les deux sont des ETATS INCONNUS, pas des pannes prouvees : sur un
    montage sain, c'est un compose down/up de production decide par la garde. Desormais :
      - absent / arrete (preuve Docker "No such object" ou Running=false) => compose up, comme avant ;
      - healthy + compteur LU >= 50 => idempotent, exit 0, comme avant ;
      - healthy + compteur LU < 50 => preuve positive d'un mauvais store, recreate ;
      - healthy + compteur NON ENTIER => non mesure : exit 10, SAUF si le sentinel de l'alias a
        ete lu = 285 dans ce meme run (preuve positive du store) => exit 0 sans geste ;
      - moteur injoignable / healthcheck illisible => exit 10, aucun compose down/up.
    Un "compose introuvable" reste un avertissement suivi d'exit 0 (rien a relancer).
#>

[CmdletBinding()]
param(
    [string]$VhdxPath    = "E:\wsl-data\qdrant.vhdx",
    [string]$Distro      = "Ubuntu",
    [string]$Label       = "qdrant-e",
    [string]$MountPoint  = "/mnt/qdrant-e",
    [string]$ComposePath = "D:\qdrant\myia_qdrant\docker-compose.production.yml",
    [int]$WaitSeconds    = 30,
    [int]$DockerWaitSec  = 180,
    [switch]$SkipDocker,
    # Maintenance #380 : la sentinelle lue a travers l'alias (ou un namespace proxy dont le
    # sentinel vaut 285) prouve que le store est le bon. Dans ce cas seulement, "healthy" mais
    # compteur de collections illisible n'est plus un motif d'arret : le chemin rootfs vide est
    # exclu par le sentinel, donc aucun compose down/up. Option de parametre reservee aux tests ;
    # en production la preuve vient des sondes du script lui-meme ($script:AliasVerified).
    [switch]$AliasVerified = $false,
    # Repertoire de logs (surcharge par le selftest a commandes factices).
    [string]$LogDir        = "C:\ProgramData\maint-scripts\logs"
)

# 'Continue' et NON 'Stop' : sous 'Stop', le stderr d'une commande native (wsl.exe,
# nsenter, mount, eventcreate) devient une erreur TERMINANTE et le script ABORTE sur
#-le-champ. Symptome mesure le 03/11/2026 : les 3 executions du script de montage sont
# mortes AVANT la Phase 6 (compose down/up) — donc sans la recreation de qdrant, qui est
# justement la reparation qu'on attend du script. Points de truncation observes :
# Phase 2 (wsl --mount, stderr "deja joint"), Phase 5b (nsenter sur un pid qui disparait
# pendant le scan des namespaces). Chaque phase verifie deja son code de sortie
# explicitement et les cas bloquants sortent par FailExit : 'Continue' ne perd aucun
# controle, il supprime seulement les aborts invisibles. Le bloc Phase 6 avait deja
# ce meme correctif local (ligne ~277) : il est applique ici a tout le script.
$ErrorActionPreference = "Continue"
$logDir = $LogDir
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "mount-qdrant-vhdx-$(Get-Date -f yyyyMMdd-HHmmss).log"

function Log {
    param([string]$msg, [string]$lvl = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "HH:mm:ss"), $lvl, $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function NotifyEvent {
    param([int]$EventId, [string]$Type = "ERROR", [string]$Message)
    # eventcreate.exe : pas besoin de registration prealable, ID range 1-1000
    # Visible dans Event Viewer / source "QdrantMount". Type: ERROR, WARNING, INFORMATION
    try {
        & eventcreate.exe /T $Type /SO "QdrantMount" /ID $EventId /L APPLICATION /D $Message 2>&1 | Out-Null
    } catch {
        Log "NotifyEvent failed: $($_.Exception.Message)" "WARN"
    }
}

function FailExit {
    param([int]$Code, [int]$EventId, [string]$Message)
    Log $Message "ERROR"
    NotifyEvent -EventId $EventId -Type "ERROR" -Message ("Mount-Qdrant-VHDX exit=$Code : " + $Message + " — voir " + $logFile)
    exit $Code
}

# --- Check Admin ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "Privileges Admin requis (Mount-VHD + wsl --mount). Relancer avec Start-Process -Verb RunAs." "ERROR"
    exit 2
}

Log "=== Mount Qdrant VHDX -> $MountPoint + Restart qdrant ==="
Log "VHDX: $VhdxPath"
Log "Distro: $Distro / Label: $Label"
Log "Compose: $ComposePath"
Log "Log: $logFile"

# --- Phase 1: Mount-VHD ---
Log "Phase 1: Verification etat Mount-VHD..."
$vhd = Get-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
if (-not $vhd) {
    FailExit -Code 3 -EventId 703 -Message "VHDX introuvable: $VhdxPath"
}
if (-not $vhd.Attached) {
    Log "VHDX non attache. Mount-VHD..."
    try {
        Mount-VHD -Path $VhdxPath -PassThru | Out-Null
    } catch {
        FailExit -Code 3 -EventId 703 -Message "Mount-VHD a echoue sur $VhdxPath : $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
    $vhd = Get-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    if (-not $vhd) {
        FailExit -Code 3 -EventId 703 -Message "VHDX introuvable apres Mount-VHD: $VhdxPath"
    }
} else {
    # Garde 17/11 (compaction interrompue) : un VHDX attache en LECTURE SEULE (reste de la
    # phase 9 de compact_qdrant_vhdx.ps1 quand son processus meurt avant le finally) n'est
    # PAS "deja attache" au sens idempotent -- continuer l'exposerait en non-inscriptible
    # a WSL. On detache, puis on remonte en lecture-ecriture.
    $diskRo = $null
    try { $diskRo = (Get-Disk -Number $vhd.DiskNumber).IsReadOnly } catch {}
    if ($diskRo) {
        Log "VHDX attache en LECTURE SEULE (reste de compaction) -> Dismount-VHD puis Mount-VHD RW" "WARN"
        try {
            Dismount-VHD -Path $VhdxPath
        } catch {
            FailExit -Code 3 -EventId 703 -Message "Dismount-VHD (garde lecture seule) a echoue : $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 2
        $vhd = Get-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        if (-not $vhd) {
            FailExit -Code 3 -EventId 703 -Message "VHDX introuvable apres Dismount-VHD: $VhdxPath"
        }
        if ($vhd.Attached) {
            FailExit -Code 3 -EventId 703 -Message "VHDX toujours attache apres Dismount-VHD (garde lecture seule)"
        }
        try {
            Mount-VHD -Path $VhdxPath -PassThru | Out-Null
        } catch {
            FailExit -Code 3 -EventId 703 -Message "Mount-VHD RW a echoue apres detachement RO : $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 2
        $vhd = Get-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        if (-not $vhd) {
            FailExit -Code 3 -EventId 703 -Message "VHDX introuvable apres Mount-VHD RW: $VhdxPath"
        }
    } else {
        Log "VHDX deja attache (idempotent)"
    }
}
$diskNum = $vhd.DiskNumber
Log "VHDX attache: DiskNumber=$diskNum"

# --- Phase 2: wsl --mount --bare (idempotent) ---
Log "Phase 2: wsl --mount \\.\PHYSICALDRIVE$diskNum --bare..."
$mountOut = & wsl.exe --mount "\\.\PHYSICALDRIVE$diskNum" --bare 2>&1
$mountRc = $LASTEXITCODE
$mountStr = ($mountOut | Out-String).Trim()
Log "wsl --mount (rc=$mountRc): $mountStr"
if ($mountRc -ne 0 -and $mountStr -notmatch "already|deja|attache|attached") {
    Log "wsl --mount echec (rc=$mountRc)" "WARN"
}

# --- Phase 3: Identifier /dev/sdX dans Ubuntu ---
Log "Phase 3: Identification device dans Ubuntu (label=$Label)..."
$deviceFound = $null
for ($i = 0; $i -lt $WaitSeconds; $i++) {
    $blkidOut = & wsl.exe -d $Distro -u root -- bash -c "blkid -L $Label 2>/dev/null" 2>&1
    $blkidStr = ($blkidOut | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $blkidStr -match "/dev/sd[a-z]+") {
        $deviceFound = $matches[0]
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $deviceFound) {
    FailExit -Code 4 -EventId 704 -Message "Device label '$Label' non trouve apres ${WaitSeconds}s. wsl --mount --bare a echoue ou disque pas pret."
}
Log "Device: $deviceFound"

# --- Phase 4: mount via fstab DANS LE NAMESPACE DE PID 1 (celui que Docker lit) ---
# Lecon 04/05: mount $deviceFound $MountPoint en session elevee ad-hoc n'est PAS
# visible par la session user-context que Docker Desktop utilise (split WSL session).
# Lecon 24/05 (recovery post-crash GPU): meme `mount $MountPoint` lance via une
# session WSL peut atterrir dans un namespace different de PID 1. Docker Desktop
# resout ses bind-mounts depuis le namespace de PID 1 (systemd). On force donc le
# mount via `nsenter -t 1 -m` (+ `mount --make-shared` pour la propagation cross-distro
# vers /mnt/wsl). fstab fournit toujours device/options.
Log "Phase 4: mount $MountPoint via fstab dans le namespace PID 1 (nsenter)..."
$mountInfo = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mountpoint -q $MountPoint && findmnt -n -o SOURCE $MountPoint || echo UNMOUNTED" 2>&1
$mountInfoStr = (($mountInfo | Out-String) -split "`r?`n" | Where-Object { $_ -match "^/dev/sd|^UNMOUNTED" } | Select-Object -First 1)
if (-not $mountInfoStr) { $mountInfoStr = ($mountInfo | Out-String).Trim() }
$needMount = $true
if ($mountInfoStr -match "^/dev/sd[a-z]+$") {
    # Already mounted in PID-1 ns — verify it's the right disk (label qdrant-e)
    $currentDev = $matches[0]
    $labelOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "blkid -s LABEL -o value $currentDev 2>/dev/null" 2>&1
    $labelStr = (($labelOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^[A-Za-z0-9_-]+$" } | Select-Object -First 1)
    if ($labelStr -eq $Label) {
        Log "$MountPoint deja monte sur $currentDev (label=$Label) dans PID-1 ns (idempotent)"
        $needMount = $false
    } elseif ([string]::IsNullOrWhiteSpace($labelStr)) {
        # 23/11/2026 : un label ILLISIBLE (sortie blkid vide -- wsl.exe sourd sous charge I/O,
        # Wsl/Service/0x8007274c) signifie "je ne sais pas", PAS "mauvais disque". Le umount de la
        # branche ci-dessous a ete execute sur ce faux negatif le 23/11 14:38Z : /mnt/qdrant-e
        # demonte puis remonte sous le conteneur, 0 collections visibles pendant la fenetre, et
        # l'alias /srv/qdrant-e tombe par propagation (meme peer group shared). Aucun geste ici :
        # la Phase 5 tranche PAR DEVICE et refuse (exit 6) si le label reste illisible.
        Log "$MountPoint monte sur $currentDev mais label ILLISIBLE (sortie blkid vide) -- sonde sourde, AUCUN umount ; la Phase 5 tranche par device" "WARN"
        $needMount = $false
    } else {
        Log "$MountPoint monte sur $currentDev mais label='$labelStr' (attendu '$Label') -- umount + remount" "WARN"
        & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "umount $MountPoint" 2>&1 | Out-Null
    }
}
if ($needMount) {
    $mountFsOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mkdir -p $MountPoint && mount $MountPoint 2>&1 && mountpoint -q $MountPoint && echo MOUNT_OK" 2>&1
    $mountFsRc = $LASTEXITCODE
    $mountFsStr = ($mountFsOut | Out-String).Trim()
    Log "mount via fstab/nsenter (rc=$mountFsRc): $mountFsStr"
    if ($mountFsRc -ne 0 -or $mountFsStr -notmatch "MOUNT_OK") {
        # Fallback: explicit device mount dans PID-1 ns
        Log "fstab mount echoue, fallback explicit $deviceFound (PID-1 ns)" "WARN"
        $mountFsOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mount $deviceFound $MountPoint && echo MOUNT_OK" 2>&1
        $mountFsRc = $LASTEXITCODE
        $mountFsStr = ($mountFsOut | Out-String).Trim()
        Log "fallback mount (rc=$mountFsRc): $mountFsStr"
        if ($mountFsRc -ne 0 -or $mountFsStr -notmatch "MOUNT_OK") {
            FailExit -Code 5 -EventId 706 -Message "mount $MountPoint echec total (fstab et fallback, PID-1 ns). Verifier /etc/fstab et que disque label '$Label' est attache."
        }
    }
    Log "$MountPoint monte OK (fstab, PID-1 ns)"
}
# Propagation: un mount nsenter est PRIVE par defaut (pas de flag shared:) -> le
# helper de bind cross-distro de Docker Desktop (/mnt/wsl) ne le verrait pas.
# make-shared est idempotent. Lecon 24/05.
& wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "mount --make-shared $MountPoint" 2>&1 | Out-Null
Log "$MountPoint marque shared (propagation cross-distro)"

# --- Alias /srv (DD 29.5.x, 24/09/2026) ---
# Le proxy cross-distro de Docker Desktop 29.5.x classe les sources sous /mnt/* comme
# drvfs-automount : un bind \\wsl.localhost\Ubuntu\mnt\... echoue a la CREATION de
# conteneur ("timed out waiting ... to be automounted"), alors qu'un chemin hors /mnt
# (ex. /srv) passe comme chemin ordinaire. Le compose utilise donc l'alias
# \\wsl.localhost\Ubuntu\srv\qdrant-e\... (overlay docker-compose.production.pathfix.yml).
# Idempotent : bind deja present -> no-op.
$aliasPoint = "/srv/qdrant-e"
# Maintenance #380 : la sentinelle lue a travers l'alias est une preuve POSITIVE du store, utile
# quand le compteur de collections est illisible. Elle est portee par une variable de script pour
# etre transmise a la decision de restart (le switch de parametre reste disponible pour les tests).
$script:AliasVerified = $false
# 13/11/2026 : l'echec du bind etait MASQUE (2>&1 | Out-Null + log inconditionnel) -- apres le
# reboot du 13/11 l'alias est reste mort 65 min sans aucune trace dans le log. On capture le rc
# et on VERIFIE le sentinel A TRAVERS l'alias ; 2eme tentative = purge d'un bind perime.
#
# 23/11/2026 -- LE GESTE ET SA CONDITION DANS LE MEME APPEL wsl.exe. L'ancienne boucle separait
# la lecture du sentinel (preuve) et le umount de la 2e tentative : sous charge I/O, wsl.exe rend
# rc=-1 (Wsl/Service/0x8007274c) alors que l'alias est SAIN ; le `break` exigeait rc=0, donc un
# alias sain non prouve entrait en 2e tentative = umount INCONDITIONNEL d'un alias sain, et si
# le re-bind echouait a son tour l'alias restait mort (mesure 23/11 17:00Z et 18:21Z : "ECHEC apres
# 3 tentative(s) rc=-1 sentinel='0'" puis "Idempotent ... skip restart", exit 0). Desormais le
# diagnostic ET le geste tiennent dans UN SEUL payload bash : soit wsl.exe repond et le umount ne
# tombe que sur un sentinel lu NON-285 dans cette meme execution, soit wsl.exe est sourd et RIEN
# ne s'execute (nouvel essai, aucune decision sur une sonde muette).
# Cas couverts : sain (make-shared seulement) ; absent (bind) ; perime (device detache, sentinel
# illisible : umount -l puis bind -- garde 17/11 preservee).
$aliasScript = @'
expected=285
alias=/srv/qdrant-e
mpt=/mnt/qdrant-e
sent=$alias/qdrant_data/storage/.qdrant_vhdx_sentinel
sz=$(cat $sent 2>/dev/null | wc -c | tr -d '[:space:]')
if [ "$sz" = "$expected" ]; then
  mount --make-shared $alias 2>/dev/null
  echo "alias-ok:sain"
  exit 0
fi
mountpoint -q $alias && umount -l $alias 2>/dev/null
mount --bind $mpt $alias && mount --make-shared $alias
sz2=$(cat $sent 2>/dev/null | wc -c | tr -d '[:space:]')
if [ "$sz2" = "$expected" ]; then echo "alias-ok:repare"; else echo "alias-ko:$sz2"; fi
'@
# CR-proof : voir $nsScript ci-dessous (lecon 31/10) -- strip des \r AVANT l'encodage.
$aliasScriptLf = $aliasScript -replace "`r", ""
$aliasB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($aliasScriptLf))
$aliasVerdict = ""
$aliasRc = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    $aliasOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "echo $aliasB64 | base64 -d | bash" 2>&1
    $aliasRc = $LASTEXITCODE
    $aliasVerdict = [string](@((($aliasOut | Out-String).Trim() -split "`r?`n") | Where-Object { $_ -match "^alias-(ok|ko):" }) | Select-Object -First 1)
    if ($aliasVerdict) { break }
}
if ($aliasVerdict -match "^alias-ok:") {
    $script:AliasVerified = $true
    Log "Alias $aliasPoint -> $MountPoint verifie par le sentinel ($($aliasVerdict.Split(':')[1]), tentative $attempt)" "OK"
} elseif ($aliasVerdict) {
    Log "Alias $aliasPoint -> $MountPoint NON VERIFIE apres bind : $aliasVerdict -- un compose up binderait le rootfs" "ERR"
} else {
    Log "Alias $aliasPoint -> $MountPoint : sonde sourde (wsl.exe sans reponse, rc=$aliasRc) apres $($attempt - 1) tentative(s) -- AUCUN geste, etat INCONNU ; le sweep verifie les 2 namespaces" "WARN"
}

# --- Phase 5: Verification PAR DEVICE (label), pas seulement compte collections ---
# Lecon 24/05: le rootfs leftover contient ~14 collection dirs stale -> un simple
# count>0 PASSE meme quand le bind est sur le rootfs (faux positif). On exige que
# le device de $MountPoint porte le label '$Label' = preuve que c'est le VHDX.
Log "Phase 5: Verification device + collections..."
$srcOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "findmnt -n -o SOURCE $MountPoint 2>/dev/null" 2>&1
$srcDev = (($srcOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^/dev/sd[a-z]+$" } | Select-Object -First 1)
if (-not $srcDev) {
    FailExit -Code 6 -EventId 707 -Message "Impossible de lire le device de $MountPoint (PID-1 ns). Raw=$(($srcOut | Out-String).Trim())"
}
$srcLabelOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "blkid -s LABEL -o value $srcDev 2>/dev/null" 2>&1
$srcLabel = (($srcLabelOut | Out-String) -split "`r?`n" | Where-Object { $_ -match "^[A-Za-z0-9_-]+$" } | Select-Object -First 1)
if ($srcLabel -ne $Label) {
    FailExit -Code 6 -EventId 708 -Message "$MountPoint monte sur $srcDev label='$srcLabel' (attendu '$Label'). Mount sur rootfs/disque incorrect -- refus (anti-split-brain)."
}
Log "OK: $MountPoint sur $srcDev label=$srcLabel (VHDX confirme)" "OK"
$collOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "ls $MountPoint/qdrant_data/storage/collections 2>/dev/null | wc -l" 2>&1
$lines = @(($collOut | Out-String) -split "`r?`n" | Where-Object { $_.Trim() -match "^\d+$" })
$collCount = if ($lines.Count -gt 0) { [int]$lines[-1].Trim() } else { 0 }
if ($collCount -gt 0) {
    Log "Collections visibles sur ${MountPoint}: $collCount" "OK"
} else {
    # 23/11/2026 : 0 collections sur un VHDX confirme par label = fenetre transitoire post-remount
    # ou lecture avortee (mesure 14:38Z, loggee [OK] a l'epoque). Informatif, pas fatal : le compteur
    # interne du conteneur (Phase 6) reste la verite de service.
    Log "Collections visibles sur ${MountPoint}: 0 -- INCOHERENT avec un VHDX confirme par label (fenetre post-remount ou lecture avortee)" "WARN"
}
# --- Phase 5b: reparer les namespaces de montage PERIMES (proxy Docker Desktop) ---
# Lecon 2026-10-29 (panne 23:22 -> 23:49) : le proxy docker-desktop-user-distro vit dans un
# namespace de montage COPIE et PRIVE (mnt:[...] different de PID 1). Apres un detachement /
# remontage du VHDX, il garde son /mnt/qdrant-e pointe sur l'ANCIEN device -> "input/output
# error" sur "stating /mnt/qdrant-e/qdrant_data/storage" a chaque compose up, alors que le
# montage de PID 1 est sain et verifie par label. Aucune propagation ne traverse un namespace
# prive, et le chemin de repli /srv retombe sur le rootfs (dossier vide) : la seule reparation
# est un remontage DANS le namespace fautif. Idempotent : on ne touche que les namespaces ou
# la sentinelle est illisible.
Log "Phase 5b: verification des namespaces de montage perimes..."
$nsScript = @'
expected=285
mydev=$(readlink /proc/1/ns/mnt)
srcdev=$(findmnt -n -o SOURCE /mnt/qdrant-e)
seen=""
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  ns=$(readlink $d/ns/mnt 2>/dev/null) || continue
  [ "$ns" = "$mydev" ] && continue
  case " $seen " in *" $ns "*) continue ;; esac
  seen="$seen $ns"
  grep -q " /mnt/qdrant-e " $d/mountinfo 2>/dev/null || continue
  sz=$(nsenter -t $pid -m -- stat -c %s /mnt/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>/dev/null)
  [ "$sz" = "$expected" ] && continue
  echo "ns-perime:$ns (pid $pid) sentinelle='${sz}' -> remontage par LABEL"
  nsenter -t $pid -m -- bash -c "umount -l /mnt/qdrant-e 2>/dev/null; mount -t ext4 $srcdev /mnt/qdrant-e 2>/dev/null || mount -t ext4 /dev/disk/by-label/qdrant-e /mnt/qdrant-e" 2>&1
  sz2=$(nsenter -t $pid -m -- stat -c %s /mnt/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>/dev/null)
  echo "  apres: sentinelle='${sz2}'"
done
echo "ns-scan-done"
'@
# CR-proof (lecon 31/10, meme cause que compact_qdrant_vhdx.ps1) : un checkout git avec
# autocrlf=true reecrit ce fichier en CRLF ; le here-string capture alors des \r qui
# cassent le parseur bash au decode ("syntax error near unexpected token `$'do\r'").
# Symptome observe 03/11/2026 : le scan de namespaces ne s'executait PLUS du tout
# (aucun "ns-scan-done" dans les logs) et le pipeline bash mourait silencieusement.
# On strip les \r AVANT l'encodage, quelles que soient les fins de ligne du fichier.
$nsScriptLf = $nsScript -replace "`r", ""
$nsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nsScriptLf))
$nsOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "echo $nsB64 | base64 -d | bash" 2>&1
foreach ($l in (($nsOut | Out-String).Trim() -split "`r?`n")) { if ($l) { Log "  $l" } }


# --- Phase 6: Wait Docker + Restart qdrant_production ---
if ($SkipDocker) {
    Log "Phase 6 SKIPPED (--SkipDocker)"
    exit 0
}

Log "Phase 6: Wait Docker Desktop ready (timeout=${DockerWaitSec}s)..."
# Docker emet des warnings sur stderr qui sous $ErrorActionPreference=Stop deviennent terminating.
# On switch en Continue pour tout le bloc Phase 6 (le script exit ensuite).
$ErrorActionPreference = "Continue"
# Lecon 01/05: docker info repond OK avant que le user-distro proxy
# (\\wsl.localhost\$Distro\) soit fonctionnel. Verifier les DEUX:
#   1) docker info (engine ready)
#   2) Test-Path UNC vers le mountpoint qdrant (user-distro proxy ready)
# Lecon 28/05 (2 containers REMOVED en 8h apres hard crashes Windows): le proxy plan9 UNC
# revient AVANT la socket Docker bind-mount service (/run/guest-services/distro-services/ubuntu.sock).
# Sans elle, `compose up` echoue:
#   "Error response from daemon: accessing specified distro mount service: stat
#    /run/guest-services/distro-services/ubuntu.sock: no such file or directory"
# -> container reste a l'etat REMOVED, schtask exit 8, watchdog WARN sans remediation.
# FIX: verifier explicitement la presence de la socket avant de proceder a compose down/up.
$dockerReady = $false
$uncProbe = "\\wsl.localhost\$Distro\mnt\qdrant-e\qdrant_data\storage\raft_state.json"
# Docker Desktop 29.5.x: la socket "distro mount service" a DEMENAGE de
#   /run/guest-services/distro-services/ubuntu.sock (ancien) vers
#   /mnt/wsl/docker-desktop/shared-sockets/guest-services/distro-services/ubuntu.sock (nouveau).
# On teste les DEUX via `wsl test -S` (fiable, contrairement au Test-Path UNC sur /run
# qui n'existe plus) pour rester compatible toutes versions de Docker Desktop.
$sockNew = "/mnt/wsl/docker-desktop/shared-sockets/guest-services/distro-services/ubuntu.sock"
$sockOld = "/run/guest-services/distro-services/ubuntu.sock"
for ($i = 0; $i -lt $DockerWaitSec; $i++) {
    Start-Sleep -Seconds 2
    $null = & docker.exe ps -q 2>&1
    if ($LASTEXITCODE -ne 0) { continue }
    if (-not (Test-Path $uncProbe -ErrorAction SilentlyContinue)) { continue }
    & wsl.exe -d $Distro -- bash -c "test -S '$sockNew' || test -S '$sockOld'" 2>$null
    if ($LASTEXITCODE -ne 0) { continue }
    $dockerReady = $true
    break
}
if (-not $dockerReady) {
    FailExit -Code 7 -EventId 709 -Message "Docker engine + user-distro proxy + bind-mount service non prets apres ${DockerWaitSec}s (UNC probe: $uncProbe ; SOCK probe linux: $sockNew | $sockOld). Mount Ubuntu OK mais qdrant ne peut pas demarrer."
}
Log "Docker + user-distro proxy + bind-mount service ready (apres $($i*2)s)"

# Le meme alias doit exister DANS le namespace de montage du proxy Docker Desktop.
# Mesure 03/11/2026 : le bind /srv-qdrant-e existe dans PID-1 (sentinel 285) mais
# PAS dans le ns du proxy (ou il retombait sur un vieux repertoire rootfs, sentinel
# absente). Or le compose overlay pathfix bind via \\wsl.localhost\Ubuntu\srv\qdrant-e\...
# -> c'est le proxy qui resout ce chemin, PAS PID-1. Sans alias dans son ns, le prochain
# compose up binderait le mauvais store (et la porte sentinel le refuserait).
# Le ns du proxy est une COPIE privee : la propagation de PID-1 ne le traverse pas,
# il faut refaire le bind DEDANS. Idempotent : on ne touche que les ns dont la
# sentinelle ne resout pas via l'alias.
$proxyAliasScript = @'
alias=/srv/qdrant-e
mpt=/mnt/qdrant-e
expected=285
nfix=0
nok=0
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  comm=$(cat $d/comm 2>/dev/null) || continue
  case "$comm" in
    docker-desktop-*) ;;
    *) continue ;;
  esac
  ns=$(readlink $d/ns/mnt 2>/dev/null) || continue
  sz=$(nsenter -t $pid -m -- stat -c %s $alias/qdrant_data/storage/.qdrant_vhdx_sentinel 2>/dev/null)
  if [ "$sz" = "$expected" ]; then
    echo "proxy-alias-ok:pid=$pid ns=$ns"
    nok=$((nok+1))
    continue
  fi
  # 17/11 : le bind peut etre PRESENT mais PERIME (source device disparu apres
  # detach/re-attach du VHDX -> stat via l'alias rend I/O error, donc sz vide).
  # L'ancien "mountpoint -q || bind" ne reparait JAMAIS ce cas : mountpoint reussit
  # sur un montage mort, le bind etait saute, sz2 restait vide (mesure 17/11 13:07 :
  # "avant='' apres='' ok=0 fixed=0" alors que /srv pointait vers /dev/sdd disparu,
  # et le compose up echouait sur "input/output error"). umount -l systematique
  # avant de re-binder -- meme remede que la repair manuelle du 17/11 13:12.
  nsenter -t $pid -m -- bash -c "mkdir -p $alias; umount -l $alias 2>/dev/null; mount --bind $mpt $alias && mount --make-shared $alias" 2>&1
  sz2=$(nsenter -t $pid -m -- stat -c %s $alias/qdrant_data/storage/.qdrant_vhdx_sentinel 2>/dev/null)
  echo "proxy-alias:pid=$pid ns=$ns avant='${sz}' apres='${sz2}'"
  [ "$sz2" = "$expected" ] && nfix=$((nfix+1))
done
echo "proxy-alias-scan-done:ok=$nok fixed=$nfix"
'@
# CR-proof (lecon 31/10) : strip des \r AVANT encodage (checkout autocrlf).
$proxyAliasLf = $proxyAliasScript -replace "`r", ""
$proxyAliasB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($proxyAliasLf))
$proxyAliasOut = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "echo $proxyAliasB64 | base64 -d | bash" 2>&1
foreach ($l in (($proxyAliasOut | Out-String).Trim() -split "`r?`n")) {
    if ($l) {
        Log "  $l"
        if ($l -match "^proxy-alias-scan-done:ok=(\d+) fixed=(\d+)" -and (([int]$matches[1] + [int]$matches[2]) -gt 0)) {
            # Au moins un namespace proxy dont le sentinel vaut 285 : preuve positive du store.
            $script:AliasVerified = $true
        }
    }
}

if (-not (Test-Path $ComposePath)) {
    Log "Compose introuvable: $ComposePath" "WARN"
    exit 0
}

# --- Preuve par le chemin Docker (Maintenance #380) : "illisible" != "absent" ---
# Un conteneur ABSENT ou ARRETE est une preuve POSITIVE : compose up est voulu (code 9).
# Un moteur injoignable, un healthcheck illisible ou un docker exec en echec sont des ETATS
# INCONNUS : le script refuse de redemarrer la production (exit 10), puisque c'est exactement
# le chemin par lequel une garde redemarrait qdrant sur un montage sain.
function Get-ContainerVerdict {
    $insp = & docker.exe inspect qdrant_production --format '{{.State.Running}}' 2>&1
    $inspRc = $LASTEXITCODE
    $inspStr = ($insp | Out-String).Trim()
    if ($inspRc -ne 0) {
        if ($inspStr -match "No such object") { return @{ state = "absent"; raw = $inspStr } }
        return @{ state = "unknown"; raw = $inspStr }
    }
    if ($inspStr -ne "true") { return @{ state = "stopped"; raw = $inspStr } }
    $health = & docker.exe inspect qdrant_production --format '{{.State.Health.Status}}' 2>&1
    $healthRc = $LASTEXITCODE
    $healthStr = ($health | Out-String).Trim()
    Log "qdrant_production health: $healthStr"
    if ($healthRc -ne 0 -or $healthStr -eq "healthy") { return @{ state = "healthy"; raw = $healthStr } }
    if ($healthStr -match "unhealthy") { return @{ state = "unhealthy"; raw = $healthStr } }
    return @{ state = "unknown"; raw = $healthStr }
}

$verdict = Get-ContainerVerdict
if ($verdict.state -eq "healthy") {
    $collInsideOut = & docker.exe exec qdrant_production sh -c "ls /qdrant/storage/collections 2>/dev/null | wc -l" 2>&1
    $collInsideRc = $LASTEXITCODE
    $collInsideStr = ($collInsideOut | Out-String).Trim()
    $collInsideClean = $collInsideStr -replace "[^0-9]", ""
    # Non entier = "NON MESURE", jamais 0 : un docker exec en echec ne vaut pas un compteur.
    if ($collInsideRc -ne 0 -or $collInsideClean -notmatch "^\d+$") {
        if ($AliasVerified) {
            Log "qdrant healthy mais compteur de collections ILLISIBLE (rc=$collInsideRc raw=$collInsideStr) : sentinelle de l'alias VERIFIEE, le store est prouve bon -- AUCUN compose down/up" "WARN"
            exit 0
        }
        Log "qdrant healthy mais compteur de collections ILLISIBLE (rc=$collInsideRc raw=$collInsideStr) et sentinelle de l'alias non verifiee : ETAT INCONNU" "WARN"
        FailExit -Code 10 -EventId 711 -Message "Etat INCONNU : qdrant healthy mais le compteur de collections est illisible. Aucun compose down/up sur une mesure manquante (Maintenance #380)."
    }
    $collInside = [int]$collInsideClean
    Log "qdrant voit $collInside collections (interne)"
    if ($collInside -ge 50) {
        Log "Idempotent: qdrant deja sur les vraies donnees, skip restart" "OK"
        exit 0
    }
    # Preuve POSITIVE : le conteneur voit bien un store presque vide -> recreate voulu.
    Log "qdrant healthy mais ne voit que $collInside collections (< 50) : preuve positive d'un mauvais store, recreate" "WARN"
} elseif ($verdict.state -eq "unknown") {
    Log "Etat du conteneur ILLISIBLE (docker=$($verdict.raw)) : pas de preuve positive de panne" "WARN"
    FailExit -Code 10 -EventId 712 -Message "Etat INCONNU : moteur Docker injoignable ou healthcheck illisible ($($verdict.raw)). Aucun compose down/up sur une mesure manquante (Maintenance #380)."
} elseif ($verdict.state -eq "unhealthy") {
    Log "qdrant_production UNHEALTHY ($($verdict.raw)) : preuve positive de panne, recreate" "WARN"
} else {
    Log "qdrant_production absent ou non running ($($verdict.raw)) : compose up voulu" "WARN"
}

# Force restart pour rafraichir bind-mount cache (au cas ou Docker a demarre avant le mount)
Log "Restart qdrant_production (refresh bind-mount cache)..."
$composeDir = Split-Path $ComposePath -Parent
Push-Location $composeDir
try {
    & docker.exe compose -f $ComposePath down 2>&1 | ForEach-Object { Log "  down: $_" }
    Start-Sleep -Seconds 3

    # --- Selective stale-shim clearing (root-cause fix, hardened 2026-05-24) ---
    # `compose down` does NOT remove /mnt/wsl/docker-desktop-bind-mounts/Ubuntu/<hash>.
    # A shim created while $MountPoint was the empty rootfs leftover stays bound to
    # rootfs (/dev/sdd) even after the VHDX is correctly mounted; a fresh `compose up`
    # then resolves the bind THROUGH that stale shim and re-binds the empty store.
    # ROBUST filter (validated 2026-05-24): match shims whose mountinfo source path
    # contains "qdrant_data" AND whose backing device != the VHDX device. This clears
    # ONLY drifted qdrant shims (on rootfs) and KEEPS healthy ones (on the VHDX) -> safe
    # to run idempotently. The ~8 open-webui/vllm shims (source /home/...) are never matched.
    # NB: mountinfo field 4 of a healthy qdrant shim is "/qdrant_data/storage" (path within
    # the qdrant-e fs), NOT "$MountPoint/qdrant_data/storage" -- so a literal $MountPoint
    # prefix match would FAIL; the qdrant_data substring + device check is the correct test.
    # base64 to dodge PowerShell/WSL/awk quoting interplay.
    $shimScript = @'
vhdx_dev=$(findmnt -n -o MAJ:MIN __MOUNTPOINT__ 2>/dev/null | tr -d " ")
if [ -z "$vhdx_dev" ]; then echo "WARN:cannot-read-vhdx-device,skip-shim-clear"; exit 0; fi
grep docker-desktop-bind-mounts /proc/1/mountinfo | while read -r line; do
  shim_dev=$(echo "$line" | awk "{print \$3}")
  src=$(echo "$line" | awk "{print \$4}")
  mp=$(echo "$line" | awk "{print \$5}")
  case "$src" in
    *qdrant_data*)
      if [ "$shim_dev" != "$vhdx_dev" ]; then
        umount "$mp" 2>/dev/null && echo "cleared:$mp(dev $shim_dev!=vhdx $vhdx_dev)" || echo "fail-umount:$mp"
      else
        echo "keep:$mp(dev $shim_dev==vhdx,healthy)"
      fi
      ;;
  esac
done
'@
    $shimScript = $shimScript.Replace('__MOUNTPOINT__', $MountPoint)
    # CR-proof (lecon 31/10, meme cause que compact_qdrant_vhdx.ps1) : le here-string
    # capture les \r d'un checkout autocrlf et le parseur bash refuse le payload
    # ("$'\r'") -> le nettoyage des shims stale n'etait PLUS execute du tout.
    $shimScriptLf = $shimScript -replace "`r", ""
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($shimScriptLf))
    $shimClear = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- bash -c "echo $b64 | base64 -d | bash" 2>&1
    $shimLines = @(($shimClear | Out-String).Trim() -split "`r?`n" | Where-Object { $_ })
    if ($shimLines.Count -gt 0) {
        $shimLines | ForEach-Object { Log "  shim: $_" }
    } else {
        Log "  shim: aucun shim qdrant detecte (rien a nettoyer)"
    }
    # Re-make-shared so the post-down mount keeps cross-distro /mnt/wsl propagation.
    $null = & wsl.exe -d $Distro -u root -- nsenter -t 1 -m -- mount --make-shared $MountPoint 2>&1

    # Defense-in-depth (added 2026-05-28): retry compose up if the bind-mount service
    # is in a transient state. Phase-6 socket probe catches the common case; this catches
    # the narrow window where the sock exists but the service is mid-init.
    $upOk = $false
    # Overlay pathfix (DD 29.5.x) : binds via l'alias /srv — SANS lui, compose up
    # echoue sur "timed out waiting ... to be automounted" (voir bloc alias Phase 4b).
    $overlayPath = Join-Path (Split-Path $ComposePath -Parent) "docker-compose.production.pathfix.yml"
    $composeArgs = @("compose", "-f", $ComposePath)
    if (Test-Path $overlayPath) { $composeArgs += @("-f", $overlayPath) }
    # Porte depuis la copie deployee (02/11/2026, edition live jamais commitee) :
    # distinguer la cause dans le log final — un echec permanent a la 1re tentative
    # et une race epuisee en 3 tentatives envoient l'operateur a des endroits OPPOSES.
    $upAttempts = 0
    $upCause = 'non determinee'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $upAttempts = $attempt
        $upOutput = & docker.exe @composeArgs up -d 2>&1
        $upOutput | ForEach-Object { Log "  up[$attempt]: $_" }
        if ($LASTEXITCODE -eq 0) { $upOk = $true; break }
        $upJoined = ($upOutput | Out-String)
        if ($upJoined -match "distro-services/ubuntu\.sock|distro mount service|guest-services") {
            $upCause = 'race bind-mount (signature connue) — retries epuises'
            Log "  up[$attempt] FAIL (bind-mount service race) — sleep 15s + retry" "WARN"
            Start-Sleep -Seconds 15
        } else {
            # Different failure — abort retries.
            $upCause = 'echec PERMANENT (cause hors race) — retries abandonnes volontairement'
            break
        }
    }
    if (-not $upOk) {
        Log ("compose up echoue : {0} tentative(s) effectuee(s), cause = {1} — container va rester REMOVED" -f $upAttempts, $upCause) "ERROR"
    }
} finally {
    Pop-Location
}

# Wait healthy
Log "Wait qdrant_production healthy (timeout 120s)..."
$healthy = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    $h = & docker.exe inspect qdrant_production --format '{{.State.Health.Status}}' 2>&1
    if ((($h | Out-String).Trim()) -eq "healthy") { $healthy = $true; break }
}
if ($healthy) {
    Log "qdrant_production healthy" "OK"
    exit 0
} else {
    FailExit -Code 8 -EventId 710 -Message "qdrant_production pas healthy apres 120s post-restart. Compose down/up done mais container ne demarre pas correctement."
}
