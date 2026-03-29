# This script monitors the health of the Qdrant service and attempts to recover it if it becomes unhealthy.
# It is designed to be run on a schedule (e.g., every 5-10 minutes).

# --- Configuration ---
$QdrantUri = "http://localhost:6333"
$MaxRestartAttempts = 2 # Number of simple restart attempts before escalating to log analysis
$AttemptCounterFile = Join-Path $PSScriptRoot "restart_attempt_counter.tmp"
$LogFile = Join-Path $PSScriptRoot "qdrant_monitor.log"
$RestoreLockFile = Join-Path $PSScriptRoot "restore.lock"
$RestoreScriptPath = Join-Path $PSScriptRoot "restore.ps1"
# Critical error patterns to look for in logs if restarts fail
$CorruptionPatterns = @(
    "Error: Corrupted_state",
    "State cannot be recovered",
    "panicked at",
    "fatal error"
)
# --- End of Configuration ---

# Function to write messages to both console and log file
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    $LogEntry | Out-File -FilePath $LogFile -Append
    Write-Host $LogEntry
}

# 1. Prerequisite: Check if Docker is running
Write-Log "Step 1: Checking if Docker is running..."
& docker ps -q -f name=qdrant >$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Docker daemon does not seem to be running or accessible. Aborting." -Level "ERROR"
    exit 1
}
Write-Log "Docker is running."

# 2. Health Check (via /readyz endpoint)
Write-Log "Step 2: Performing health check via Qdrant API..."
try {
    $response = Invoke-RestMethod -Uri "$QdrantUri/readyz" -Method Get -TimeoutSec 10 -ErrorAction Stop
    if ($response -eq "all shards are ready") {
        Write-Log "Qdrant service is healthy. All shards are ready."
        # If the service is healthy, reset the restart counter
        if (Test-Path $AttemptCounterFile) {
            Remove-Item $AttemptCounterFile
        }
        exit 0
    }
    Write-Log "Qdrant responded, but is not fully ready. Response: $response" -Level "WARN"
    # Proceed to next steps as it's not perfectly healthy
}
catch {
    Write-Log "Health check failed. Qdrant API is not responding. Error: $($_.Exception.Message)" -Level "WARN"
    # This is the trigger to start recovery attempts
}

# 3. Recovery Attempt: Simple Restart
$attempt = 1
if (Test-Path $AttemptCounterFile) {
    $attempt = [int](Get-Content $AttemptCounterFile) + 1
}

if ($attempt -gt $MaxRestartAttempts) {
    Write-Log "Maximum restart attempts ($MaxRestartAttempts) reached. Escalating to Step 4: Advanced Diagnostics (Log Analysis)." -Level "ERROR"
    
    # 4. Advanced Diagnostics: Analyze Docker logs for corruption
    Write-Log "Analyzing last 50 lines of Qdrant logs for corruption patterns..."
    $logs = docker-compose -f "d:/qdrant/docker-compose.yml" logs --tail="50" qdrant
    
    $corruptionDetected = $false
    foreach ($pattern in $CorruptionPatterns) {
        if ($logs -match $pattern) {
            Write-Log "Corruption pattern found in logs: `"$pattern`". Triggering automated restore." -Level "CRITICAL"
            $corruptionDetected = $true
            break
        }
    }

    # 5. Trigger Restore (if corruption is confirmed)
    if ($corruptionDetected) {
        if (Test-Path $RestoreLockFile) {
            Write-Log "Restore lock file found ('$RestoreLockFile'). Another restore might be in progress. Aborting." -Level "ERROR"
            exit 1
        }
        
        Write-Log "Creating restore lock file..."
        New-Item -Path $RestoreLockFile -ItemType File | Out-Null

        Write-Log "Executing restore script: $RestoreScriptPath"
        try {
            # Execute the restore script
            powershell.exe -ExecutionPolicy Bypass -File $RestoreScriptPath
            Write-Log "Restore script executed. The process will continue in the background."
        }
        catch {
             Write-Log "An error occurred while trying to execute the restore script. $_" -Level "CRITICAL"
             # Remove lock file on failure to allow next attempt
             Remove-Item $RestoreLockFile -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Log "No specific corruption patterns found in logs. Please investigate manually." -Level "ERROR"
    }

    # Clean up the restart counter after diagnostics
    Remove-Item $AttemptCounterFile
    exit 1
}

Write-Log "Step 3: Attempting a simple restart (Attempt $attempt of $MaxRestartAttempts)..."
try {
    # Store the new attempt count
    $attempt | Out-File -FilePath $AttemptCounterFile

    docker-compose -f "d:/qdrant/docker-compose.yml" restart qdrant
    Write-Log "Restart command sent. Waiting 30 seconds for the service to come back online..."
    Start-Sleep -Seconds 30
    Write-Log "Restart attempt finished. The next scheduled run of this script will re-evaluate the health."
}
catch {
    Write-Log "Failed to execute 'docker-compose restart'. Error: $_" -Level "ERROR"
    exit 1
}