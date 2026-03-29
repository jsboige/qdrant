# This script restores the most recent Qdrant snapshot.
# It handles stopping the service, purging data, restarting, and applying the snapshot.

# --- Configuration ---
$QdrantUri = "http://localhost:6333"
$SnapshotsPath = "./qdrant_snapshots" # Assumes this script is run from the project root (d:/qdrant)
$RestoreLockFile = Join-Path $PSScriptRoot "restore.lock"
# --- End of Configuration ---

Write-Host "Starting Qdrant restore process..."

# 1. Check for snapshots
$allSnapshots = Get-ChildItem -Path $SnapshotsPath | Where-Object { !$_.PSIsContainer }
if (-not $allSnapshots) {
    Write-Error "No snapshots found in '$SnapshotsPath'. Aborting restore."
    exit 1
}
Write-Host "Found $($allSnapshots.Count) snapshot(s) to restore."
# 2. Stop the service and purge existing data to ensure a clean restore
Write-Host "Stopping Qdrant service and purging existing data (this will remove current data)..."
try {
    docker-compose down -v
    Write-Host "Service stopped and volumes removed successfully."
}
catch {
    Write-Error "Failed to stop or purge the service. Error: $_"
    exit 1
}

# 3. Restart the Qdrant service
Write-Host "Restarting Qdrant service..."
try {
    docker-compose up -d
    Write-Host "Service started successfully."
}
catch {
    Write-Error "Failed to start the service. Error: $_"
    exit 1
}

# 4. Wait for the service to be ready
$maxAttempts = 10
$waitTime = 5 # seconds
Write-Host "Waiting for Qdrant service to become available (up to $($maxAttempts * $waitTime) seconds)..."
For ($i=1; $i -le $maxAttempts; $i++) {
    try {
        $response = Invoke-RestMethod -Uri "$QdrantUri/readyz" -Method Get -ErrorAction Stop
        if ($response -eq "all shards are ready") {
            Write-Host "Qdrant service is ready."
            break
        }
    }
    catch {}
    Start-Sleep -Seconds $waitTime
    if ($i -eq $maxAttempts) {
        Write-Error "Qdrant service did not become ready in time. Please check the container logs."
        exit 1
    }
}

# 5. Restore from the snapshot
Write-Host "Restoring from snapshot: $($latestSnapshot.Name)..."

# Qdrant restores a snapshot of a specific collection. We need to parse collection name from snapshot file name.
# Example: `my-collection-1678886400.snapshot`
$collectionName = ($latestSnapshot.Name -split '-[0-9]+.*.snapshot')[0]

if (-not $collectionName) {
    Write-Error "Could not parse collection name from snapshot filename: $($latestSnapshot.Name)"
    exit 1
}

Write-Host "Inferred collection name: $collectionName"

# 5. Restore all available snapshots
Write-Host "Starting restore for all found snapshots..."

$allSnapshots = Get-ChildItem -Path $SnapshotsPath | Where-Object { !$_.PSIsContainer }

foreach ($snapshot in $allSnapshots) {
    $snapshotFileName = $snapshot.Name
    # Infer collection name from snapshot filename (e.g., `my-collection-1678886400.snapshot`)
    $collectionName = ($snapshotFileName -split '-[0-9]{10,}.*.snapshot')[0]

    if (-not $collectionName) {
        Write-Warning "Could not parse collection name from snapshot filename: $snapshotFileName. Skipping."
        continue
    }

    Write-Host "---"
    Write-Host "Restoring collection '$collectionName' from snapshot '$snapshotFileName'..."

    $restoreUri = "$QdrantUri/collections/$collectionName/snapshots/recover"
    $body = @{
        location = "file:///qdrant/snapshots/$snapshotFileName"
        priority = "hot_replica"
    } | ConvertTo-Json

    try {
        $restoreResponse = Invoke-RestMethod -Uri $restoreUri -Method Post -Body $body -ContentType "application/json"
        if ($restoreResponse.result -eq $true) {
            Write-Host "Successfully initiated restore for collection '$collectionName'."
        } else {
            Write-Error "Failed to initiate restore for '$collectionName'. Response: $($restoreResponse | ConvertTo-Json -Depth 3)"
        }
    }
    catch {
        Write-Error "An error occurred while calling the restore API for '$collectionName'. Error: $_"
        $errorResponse = $_.Exception.Response.GetResponseStream() | ForEach-Object { (New-Object System.IO.StreamReader($_)).ReadToEnd() }
        Write-Error "Response content: $errorResponse"
    }
}

Write-Host "---"
Write-Host "Restore process completed for all snapshots."
Write-Host "Check Qdrant logs for progress. It may take some time for data to be indexed."

finally {
    # Always remove the lock file at the end of the script, whether it succeeded or failed.
    # The monitoring script is responsible for the timing and frequency of restore attempts.
    if (Test-Path $RestoreLockFile) {
        Write-Host "Removing restore lock file..."
        Remove-Item $RestoreLockFile -ErrorAction SilentlyContinue
    }
}
