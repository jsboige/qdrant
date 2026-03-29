# This script sets up a scheduled task to run the Qdrant health monitoring script periodically.

# --- Configuration ---
$TaskName = "Qdrant Health Monitor"
$TaskDescription = "Automatically checks Qdrant health every 5 minutes and attempts recovery if needed."
$ScriptPath = Join-Path $PSScriptRoot "monitor_qdrant_health.ps1"
# --- End of Configuration ---

# 1. Define the action
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# 2. Define the trigger
# This sets the task to run at startup and repeat every 5 minutes indefinitely.
$Trigger = New-ScheduledTaskTrigger -AtStartup -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([System.TimeSpan]::MaxValue)

# 3. Define the settings
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false

# 4. Get the principal (the user who will run it)
$Principal = New-ScheduledTaskPrincipal -UserId (Get-CimInstance Win32_ComputerSystem).UserName -LogonType Interactive

# 5. Register the scheduled task
try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description $TaskDescription -Force
    Write-Host "Successfully registered scheduled task '$TaskName'."
    Write-Host "It will run every 5 minutes."
    Write-Host "To check the task, open Task Scheduler and look in the root of the 'Task Scheduler Library'."
}
catch {
    Write-Error "Failed to register scheduled task. Error: $_"
    Write-Error "Please try running this script with Administrator privileges."
}