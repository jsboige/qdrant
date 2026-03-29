# This script uninstalls the automated Qdrant backup scheduled task.

# --- Configuration ---
$TaskName = "Qdrant Hourly Backup"
# --- End of Configuration ---

Write-Host "Attempting to uninstall scheduled task: '$TaskName'..."

try {
    # Check if the task exists before trying to unregister it
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Successfully unregistered scheduled task '$TaskName'."
    } else {
        Write-Host "Scheduled task '$TaskName' not found. Nothing to do."
    }
}
catch {
    Write-Error "An error occurred while trying to unregister the task. Error: $_"
    Write-Error "Please try running this script with Administrator privileges."
}