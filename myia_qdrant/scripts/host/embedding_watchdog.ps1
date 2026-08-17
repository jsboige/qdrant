<#
.SYNOPSIS
    Watchdog backend embeddings (vLLM po-2026 + proxy IIS embeddings.myia.io).
    ALERT-ONLY : detecte la coupure du chemin semantique fleet et alerte immediatement
    sur les dashboards roosync (workspace-qdrant + global), sans remediation.

.DESCRIPTION
    Verifie periodiquement (schtask 5 min, machine myia-ai-01) :
      1) Backend direct : http://192.168.0.51:8004/health (vLLM qwen3-4b-awq-embedding, po-2026)
      2) Proxy IIS : https://embeddings.myia.io/v1/models (401/404 = vivant, 5xx/000 = down)
      3) Contexte qdrant : http://localhost:6333/healthz (pour qualifier l'alerte :
         "embeddings DOWN, qdrant UP" — le pattern 17/08/2026 ou la flotte declara
         "qdrant HS" alors que seul le chemin semantique etait coupe)

    Machine a etats via JSON (state.json) :
      UP -> DOWN : alerte [ERROR] sur workspace-qdrant.md + global.md + log
      DOWN->DOWN : re-alerte uniquement si lastAlert > ReAlertMinutes (escalade bornee)
      DOWN-> UP : alerte [DONE] (recovery) sur les memes canaux
      UP -> UP : silencieux

    POURQUOI sur ai-01 et pas po-2026 : le backend vit sur po-2026 ; quand po-2026
    meurt, ses propres watchdogs meurent avec lui (incident 17/08 : 3e episode en 24h
    de "qdrant HS" = SPOF embeddings). Ce watchdog, sur une machine differente, ferme
    la breche de detection.

    Concu pour scheduled task toutes les 5 min (pwsh, MYIA/Limited, sans UAC).
    Le log file est append-only, dernieres lignes = etat le plus recent.

.NOTES
    Sortie codes:
      0   = OK
      1   = backend direct DOWN
      2   = proxy IIS DOWN
      3   = backend + proxy DOWN
      124 = self-timeout (un appel HTTP a hang, force-exit)

    Alerte = append markdown au format roosync (`### [ISO] machine|workspace`) sur
    les dashboards. Risque de course avec la condensation MCP (faible : appends
    petits) — accepte, cf. README.md.

    REMEDIATION NON INCLUSE volontairement : le restart Docker po-2026 exige le mdp
    maint-admin (hygiene secret : jamais stocke dans un script). Le role de ce
    watchdog = DETECTION + ALERTE IMMEDIATE ; la remontée route vers user/Embeddings lane.

.MACHINES
    myia-ai-01 (doit joindre 192.168.0.51 et le proxy public)

.EXAMPLE
    .\embedding_watchdog.ps1
    Run ponctuel (detection + alerte si transition).

.EXAMPLE
    .\embedding_watchdog.ps1 -ForceDown -DryRun
    Simule un down, affiche ce qui serait alerte sans rien ecrire.

.EXAMPLE
    schtasks /create /tn "Watchdog-Embedding-API" /tr "pwsh -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\maint-scripts\embedding_watchdog.ps1'" /sc minute /mo 5 /ru "MYIA-AI-01\MYIA"
    # Baisser ExecutionTimeLimit (defaut PT72H) :
    $t=Get-ScheduledTask "Watchdog-Embedding-API"; $t.Settings.ExecutionTimeLimit='PT60S'; Set-ScheduledTask -TaskName "Watchdog-Embedding-API" -Settings $t.Settings
#>

[CmdletBinding()]
param(
    [string]$BackendUrl       = 'http://192.168.0.51:8004/health',
    [string]$ProxyUrl         = 'https://embeddings.myia.io/v1/models',
    [string]$QdrantUrl        = 'http://localhost:6333/healthz',
    [string]$StateDir         = 'C:\ProgramData\maint-scripts\logs',
    [string]$DashboardQdrant  = 'G:\Mon Drive\Synchronisation\RooSync\.shared-state\dashboards\workspace-qdrant.md',
    [string]$DashboardGlobal  = 'G:\Mon Drive\Synchronisation\RooSync\.shared-state\dashboards\global.md',
    [string]$MachineId        = '',
    [string]$WorkspaceId      = 'qdrant-watchdog',
    [int]$HttpTimeoutSeconds  = 10,
    [int]$SelfTimeoutSeconds  = 60,
    [int]$ReAlertMinutes      = 30,
    [switch]$ForceDown,
    [switch]$ForceUp,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($MachineId)) { $MachineId = $env:COMPUTERNAME.ToLowerInvariant() }

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$logFile     = Join-Path $StateDir "embedding-watchdog.log"
$stateFile   = Join-Path $StateDir "embedding-watchdog-state.json"

# --- Self-timeout (modele verify_qdrant_mount.ps1) ---
if ($SelfTimeoutSeconds -gt 0) {
    try {
        Add-Type -TypeDefinition @"
using System; using System.Threading; using System.IO;
public static class EmbeddingWatchdogSelfTimeout {
    public static void Arm(int ms, string logPath, int exitCode) {
        Thread t = new Thread(() => {
            Thread.Sleep(ms);
            try { File.AppendAllText(logPath, "["+DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")+"] [ERROR] SELF-TIMEOUT "+(ms/1000)+"s exceeded, force-exit "+exitCode+"\n"); } catch {}
            Environment.Exit(exitCode);
        });
        t.IsBackground = true; t.Start();
    }
}
"@ -ErrorAction Stop
        [EmbeddingWatchdogSelfTimeout]::Arm($SelfTimeoutSeconds * 1000, $logFile, 124)
    } catch {
        Add-Content -Path $logFile -Value ("[{0}] [WARN] self-timeout arm failed: {1}" -f (Get-Date -f "yyyy-MM-dd HH:mm:ss"), $_.Exception.Message) -Encoding UTF8
    }
}

function Log {
    param([string]$msg, [string]$lvl = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -f "yyyy-MM-dd HH:mm:ss"), $lvl, $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Probe-Http {
    param([string]$Url)
    $code = 000
    $ms = -1
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-WebRequest -Uri $Url -Method GET -TimeoutSec $HttpTimeoutSeconds -SkipHttpErrorCheck -MaximumRedirection 0 -ErrorAction Stop
        $sw.Stop()
        $code = [int]$r.StatusCode
        $ms = $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        $ms = $sw.ElapsedMilliseconds
        # code reste 000 (timeout / connect refuse)
    }
    return @{ code = $code; ms = $ms }
}

function Read-State {
    if (Test-Path $stateFile) {
        try { return (Get-Content $stateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return @{ state = 'up'; since = ''; lastAlert = '' }
}

# ConvertFrom-Json auto-convertit les ISO 8601 en [datetime] ; Parse direct selon culture echoue.
# Normalise TOUJOURS en [datetime] UTC (Kind=Utc), insensible a la culture locale.
# CRITIQUE : $now est [DateTime]::UtcNow — un parse Kind=Local/Unspecified fausse les deltas.
function Get-DateTimeValue {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -isnot [datetime]) {
        $Value = [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    }
    if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
    return $Value
}

function Write-State {
    param($State)
    $State | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
}

function Append-Dashboard {
    param([string]$Path, [string]$Body)
    if ($DryRun) { return }
    if (-not (Test-Path $Path)) { Log "Dashboard introuvable, skip: $Path" "WARN"; return }
    $header = "### [$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))] $MachineId|$WorkspaceId"
    Add-Content -Path $Path -Value ("`n$header`n`n$Body`n") -Encoding UTF8
    Log "Alert dashboard: $Path"
}

# ========== PROBES ==========
Log "Run start (ForceDown=$ForceDown ForceUp=$ForceUp DryRun=$DryRun)"

if ($ForceDown) {
    Log "ForceDown actif: backend+proxy consideres DOWN (test)" "WARN"
    $b = @{ code = 000; ms = -1 }
    $p = @{ code = 000; ms = -1 }
} elseif ($ForceUp) {
    Log "ForceUp actif: backend+proxy consideres UP (test)" "WARN"
    $b = @{ code = 200; ms = 0 }
    $p = @{ code = 200; ms = 0 }
} else {
    $b = Probe-Http $BackendUrl
    $p = Probe-Http $ProxyUrl
}

$q = Probe-Http $QdrantUrl
$qStatus = if ($q.code -eq 200) { "UP" } else { "DOWN ($($q.code))" }

# Backend down = non-2xx. Proxy down = non-(2xx/401/404).
$backendUp   = ($b.code -ge 200 -and $b.code -lt 300)
$proxyUp     = ($p.code -ge 200 -and $p.code -lt 300) -or $p.code -eq 401 -or $p.code -eq 404
$qdrantUp    = ($q.code -eq 200)

if (-not $backendUp -and -not $proxyUp) { $exitCode = 3 }
elseif (-not $backendUp)               { $exitCode = 1 }
elseif (-not $proxyUp)                 { $exitCode = 2 }
else                                   { $exitCode = 0 }

$label = if ($exitCode -eq 0) { "UP" } else { "DOWN" }
Log ("Probes: backend={0}/{1}ms proxy={2}/{3}ms qdrant={4}/{5}ms -> {6} (exit={7})" -f $b.code, $b.ms, $p.code, $p.ms, $q.code, $q.ms, $label, $exitCode)

# ========== STATE MACHINE ==========
$st = Read-State
$now = [DateTime]::UtcNow

if ($exitCode -eq 0) {
    if ($st.state -eq 'down') {
        Log "Transition DOWN -> UP. Post recovery." "INFO"
        $downSince = Get-DateTimeValue $st.since
        $downMin = if ($downSince) { [Math]::Round((($now - $downSince).TotalMinutes)) } else { '?' }
        $body = @"
**[DONE][WATCHDOG] Chemin semantique RESTAURE — backend embeddings de retour**
- Probes: backend :8004 = $($b.code)/$($b.ms)ms · proxy = $($p.code)/$($p.ms)ms · qdrant = $qStatus
- Down depuis: $($st.since) — duree: $downMin min
— $MachineId embedding_watchdog.ps1
"@
        Append-Dashboard $DashboardQdrant $body
        Append-Dashboard $DashboardGlobal $body
    }
    Write-State @{ state = 'up'; since = ''; lastAlert = '' }
    Log "State UP. No alert." "INFO"
    exit 0
}

# DOWN (exit 1-3)
$alertNow = $true
if ($st.state -eq 'down' -and $st.lastAlert) {
    $last = Get-DateTimeValue $st.lastAlert
    $elapsed = if ($last) { ($now - $last).TotalMinutes } else { [double]::MaxValue }
    if ($elapsed -lt $ReAlertMinutes) { $alertNow = $false }
}

if ($alertNow) {
    $sinceStr = if ($st.since) { $st.since } else { $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    $faults = @()
    if (-not $backendUp) { $faults += "backend :8004 = $($b.code) (timeout/$($b.ms)ms)" }
    if (-not $proxyUp)   { $faults += "proxy embeddings.myia.io = $($p.code) (timeout/$($p.ms)ms)" }
    $body = @"
**[ERROR][WATCHDOG] Backend embeddings DOWN — chemin semantique fleet coupe. Qdrant: $qStatus**
- Fautes: $($faults -join ' ; ')
- Qdrant: $qStatus (roo_tasks ~2M pts, backup 03:17 OK — PAS un down qdrant)
- Depuis: $sinceStr
- Action: restart Docker po-2026 (user jsboige, WinRM maint-admin) — pattern 17/08/2026, 3e episode en 24h (SPOF embeddings sur po-2026)
- Re-alerte auto dans $ReAlertMinutes min si persiste
— $MachineId embedding_watchdog.ps1
"@
    Append-Dashboard $DashboardQdrant $body
    Append-Dashboard $DashboardGlobal $body
    Write-State @{ state = 'down'; since = $sinceStr; lastAlert = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    Log ("ALERT posted (exit=$exitCode). State=down since=$sinceStr") "ERROR"
} else {
    Log "DOWN persistant, re-alerte pas due (cooldown $ReAlertMinutes min). Silence." "WARN"
}

exit $exitCode
