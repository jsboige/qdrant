# This script sets up a daily scheduled task to run the Qdrant backup script.

# --- Configuration ---
$TaskName = "Qdrant Hourly Backup"
$TaskDescription = "Automatically backs up all Qdrant collections every 3 hours."
# Path to the backup script. $PSScriptRoot ensures the path is relative to this setup script.
$ScriptPath = Join-Path $PSScriptRoot "backup.ps1"
# --- End of Configuration ---

# 1. Define the action: what command to run.
# We execute PowerShell.exe and pass the backup script's path as an argument.
# -ExecutionPolicy Bypass ensures the script runs regardless of system policy.
# -WindowStyle Hidden prevents a window from popping up.
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# 2. Define the trigger: when to run the task.
# This sets the task to run daily, starting at midnight, and repeats every 3 hours indefinitely.
$Trigger = New-ScheduledTaskTrigger -Daily -At "12:00am" -RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration ([System.TimeSpan]::MaxValue)

# 3. Define the settings for the task.
# -RunOnlyIfNetworkAvailable: False -> The task runs even if there's no network connection (useful for local services).
# -StartWhenAvailable: True -> If the computer was off at the scheduled time, the task runs as soon as it's on.
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false

# 4. Get the principal for the task (the user who will run it).
# By default, it runs as the current user.
$Principal = New-ScheduledTaskPrincipal -UserId (Get-CimInstance Win32_ComputerSystem).UserName -LogonType Interactive

# 5. Register the scheduled task with the system.
# Using -Force will overwrite any existing task with the same name.
try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description $TaskDescription -Force
    Write-Host "Successfully registered scheduled task '$TaskName'."
    Write-Host "It will run every 3 hours, starting at midnight."
    Write-Host "To check the task, open Task Scheduler and look in the root of the 'Task Scheduler Library'."
}
catch {
    Write-Error "Failed to register scheduled task. Error: $_"
    Write-Error "Please try running this script with Administrator privileges."
}