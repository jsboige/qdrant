# backup.ps1
# Creates a snapshot for every collection in Qdrant.

# Qdrant API endpoint
$qdrantUrl = "http://localhost:6333"

# Get all collections
try {
    $collectionsResponse = Invoke-RestMethod -Uri "$qdrantUrl/collections" -Method Get
    $collectionNames = $collectionsResponse.result.collections.name
} catch {
    Write-Host "Error: Failed to get collections from Qdrant. Is the service running?"
    exit 1
}

if (-not $collectionNames) {
    Write-Host "No collections found. Nothing to back up."
    exit 0
}

Write-Host "Found collections: $($collectionNames -join ', ')"

# Create a snapshot for each collection
foreach ($collectionName in $collectionNames) {
    $snapshotUrl = "$qdrantUrl/collections/$collectionName/snapshots"
    try {
        Write-Host "Creating snapshot for collection '$collectionName'..."
        $snapshotResponse = Invoke-RestMethod -Uri $snapshotUrl -Method Post -ContentType "application/json" -Body "{}"
        if ($snapshotResponse.status -eq 'ok') {
            $snapshotName = $snapshotResponse.result.name
            Write-Host "Successfully created snapshot '$snapshotName' for collection '$collectionName'."
        } else {
            Write-Host "Warning: Failed to create snapshot for collection '$collectionName'. Response: $($snapshotResponse | Out-String)"
        }
    } catch {
        Write-Host "Error: An exception occurred while creating a snapshot for '$collectionName'."
        Write-Host $_.Exception.Message
    }
}

Write-Host "Backup process completed."