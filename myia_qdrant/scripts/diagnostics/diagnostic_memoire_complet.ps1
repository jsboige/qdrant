# Script de Diagnostic Mémoire Complet
# Date: 2025-10-14

Write-Host "=== DIAGNOSTIC MÉMOIRE SYSTÈME ===" -ForegroundColor Cyan

# 1. Mémoire système Windows
Write-Host "`n1. Mémoire Système Windows:" -ForegroundColor Yellow
Get-CimInstance Win32_OperatingSystem | Select-Object @{
    Name="TotalRAM_GB";Expression={[math]::Round($_.TotalVisibleMemorySize/1MB,2)}
},@{
    Name="FreeRAM_GB";Expression={[math]::Round($_.FreePhysicalMemory/1MB,2)}
},@{
    Name="UsedRAM_GB";Expression={[math]::Round(($_.TotalVisibleMemorySize - $_.FreePhysicalMemory)/1MB,2)}
},@{
    Name="UsedRAM_%";Expression={[math]::Round((($_.TotalVisibleMemorySize - $_.FreePhysicalMemory)/$_.TotalVisibleMemorySize)*100,2)}
} | Format-Table -AutoSize

# 2. Mémoire WSL2
Write-Host "`n2. Mémoire WSL2:" -ForegroundColor Yellow
try {
    wsl -e free -h
} catch {
    Write-Host "  WSL non disponible: $_" -ForegroundColor Red
}

# 3. Limites WSL2 (.wslconfig)
Write-Host "`n3. Limites WSL2 (.wslconfig):" -ForegroundColor Yellow
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
if (Test-Path $wslConfigPath) {
    Get-Content $wslConfigPath
} else {
    Write-Host "  .wslconfig n'existe pas (pas de limites)" -ForegroundColor Gray
}

# 4. Mémoire Container Docker
Write-Host "`n4. Mémoire Container Qdrant:" -ForegroundColor Yellow
try {
    docker stats qdrant_production --no-stream --format "table {{.Container}}`t{{.MemUsage}}`t{{.MemPerc}}"
} catch {
    Write-Host "  Container non disponible: $_" -ForegroundColor Red
}

# 5. Détails container
Write-Host "`n5. Limites Container (docker inspect):" -ForegroundColor Yellow
try {
    $memLimit = docker inspect qdrant_production --format='{{.HostConfig.Memory}}'
    if ($memLimit -eq "0") {
        Write-Host "  Pas de limite mémoire configurée (illimité)" -ForegroundColor Gray
    } else {
        $memLimitGB = [math]::Round($memLimit/1GB,2)
        Write-Host "  Limite mémoire: $memLimitGB GB" -ForegroundColor White
    }
} catch {
    Write-Host "  Erreur inspection: $_" -ForegroundColor Red
}

Write-Host "`n=== FIN DIAGNOSTIC MÉMOIRE ===" -ForegroundColor Cyan