# restore.ps1
# Finds the latest snapshot for a collection and provides instructions for manual restore.

param (
    [string][Parameter(Mandatory=$true)] $SourceCollectionName,
    [string][Parameter(Mandatory=$true)] $DestinationCollectionName
)

# Qdrant API endpoint
$qdrantUrl = "http://localhost:6333"

# 1. Find the latest snapshot for the source collection
$latestSnapshotName = ""
try {
    $snapshotsResponse = Invoke-RestMethod -Uri "$qdrantUrl/collections/$SourceCollectionName/snapshots" -Method Get
    if ($snapshotsResponse.result.Count -eq 0) {
        Write-Host "Error: No snapshots found for collection '$SourceCollectionName'."
        exit 1
    }
    # Get the most recent snapshot
    $latestSnapshot = $snapshotsResponse.result | Sort-Object -Property creation_time -Descending | Select-Object -First 1
    $latestSnapshotName = $latestSnapshot.name
    Write-Host "Found latest snapshot for '$SourceCollectionName': '$latestSnapshotName'"
} catch {
    Write-Host "Error: Failed to get snapshots for collection '$SourceCollectionName'."
    Write-Host $_.Exception.Message
    exit 1
}

# 2. Provide manual restore instructions
Write-Host "------------------------------------------------------------------"
Write-Host "MANUAL RESTORE PROCESS REQUIRED"
Write-Host "------------------------------------------------------------------"
Write-Host "Qdrant's REST API does not support a direct 'restore-to-new-collection-from-server-snapshot' command."
Write-Host "Please follow these steps:"
Write-Host ""
Write-Host "1. Create a new, empty collection named '$DestinationCollectionName' with the same configuration as the original."
Write-Host "   (You can get the original collection's config at $qdrantUrl/collections/$SourceCollectionName)"
Write-Host ""
Write-Host "2. Use a 'curl' command to upload the snapshot file to the new collection."
Write-Host "   The snapshot file is located inside the 'qdrant-snapshots' Docker volume."
Write-Host ""
Write-Host "   Example command (run from your local machine, not inside the container):"
Write-Host "   docker-compose exec qdrant curl -X POST `"$qdrantUrl/collections/$DestinationCollectionName/snapshots/upload?force=true&priority=snapshot`" `" -F `"snapshot=@/qdrant/snapshots/$SourceCollectionName/snapshots/$latestSnapshotName`""
Write-Host ""
Write-Host "   Note: This command executes 'curl' inside the running Qdrant container where the snapshot file is accessible."
Write-Host "------------------------------------------------------------------"