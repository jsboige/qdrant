# Qdrant Setup and Troubleshooting

This document outlines the setup for this Qdrant instance and provides troubleshooting steps for common issues.

## Docker Compose Configuration

The service is managed via `docker-compose.yml`.

Key configurations:
- **Image:** `qdrant/qdrant:latest`
- **Ports:** `6333` (HTTP) and `6334` (gRPC) are exposed.
- **Volumes:**
    - `qdrant-storage:/qdrant/storage`: A named volume for persistent data storage. This is the preferred method to avoid filesystem permission issues with WSL.
    - `qdrant-snapshots:/qdrant/snapshots`: A named volume for storing collection snapshots.
    - `./config/production.yaml:/qdrant/config/production.yaml`: Mounts the local production configuration.

## Troubleshooting

### Issue: Service is unresponsive or stuck during startup

If the service is not responding, it's often due to a corrupted state or a long recovery process for a large collection.

**Symptoms:**
- `curl http://localhost:6333` fails or returns an empty reply.
- Logs (`docker-compose logs`) show the service is stuck in a `Recovering shard` loop for a long time.

**Solution: Purge and Restart**

This solution will **delete all existing data**. Only proceed if you do not need the current data or if you have a snapshot to restore from.

1.  **Stop and remove the container and its volume:**
    ```bash
    docker-compose down -v
    ```
2.  **Restart the service:**
    ```bash
    docker-compose up -d --force-recreate
    ```
    This will recreate the service with a fresh, empty storage volume.

## Backup and Restore Scripts

To simplify the backup and restore process, two PowerShell scripts are provided in this directory: `backup.ps1` and `restore.ps1`.

### Automated Backups (`backup.ps1`)

The `backup.ps1` script automatically discovers all collections and creates a snapshot for each one.

**Usage:**
```powershell
./roo_docs/backup.ps1
```

**Automation:**
To run backups daily, you can create a scheduled task in Windows:
1.  Open Task Scheduler.
2.  Create a new task.
3.  Set a daily trigger.
4.  For the action, select "Start a program" and use the following:
    - Program/script: `pwsh.exe`
    - Add arguments: `-File "d:\qdrant\roo_docs\backup.ps1"` (use the full path to the script).

### Manual Restore (`restore.ps1`)

The `restore.ps1` script helps you restore a collection from its latest snapshot into a **new** collection.

**Important:** Qdrant's REST API does not directly support restoring a snapshot into a new collection with a single command. The script will guide you through the necessary manual steps.

**Usage:**
```powershell
./roo_docs/restore.ps1 -SourceCollectionName "name-of-old-collection" -DestinationCollectionName "name-for-new-restored-collection"
```
The script will find the latest snapshot and provide you with a `curl` command to complete the restore process. Follow the on-screen instructions carefully.
