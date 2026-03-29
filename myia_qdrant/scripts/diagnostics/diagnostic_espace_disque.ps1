# Script de Diagnostic Espace Disque
# Date: 2025-10-14

Write-Host "`n=== DIAGNOSTIC ESPACE DISQUE ===" -ForegroundColor Cyan

# 1. Espace disque Windows (lecteur D:)
Write-Host "`n1. Espace Disque D: (hôte):" -ForegroundColor Yellow
Get-PSDrive D | Select-Object Name, @{
    Name="Used_GB";Expression={[math]::Round($_.Used/1GB,2)}
},@{
    Name="Free_GB";Expression={[math]::Round($_.Free/1GB,2)}
},@{
    Name="Total_GB";Expression={[math]::Round(($_.Used + $_.Free)/1GB,2)}
},@{
    Name="Used_%";Expression={[math]::Round(($_.Used/($_.Used + $_.Free))*100,2)}
} | Format-Table -AutoSize

# 2. Espace disque dans WSL (volume qdrant_data)
Write-Host "`n2. Espace Disque WSL (~/qdrant_data):" -ForegroundColor Yellow
try {
    wsl -e df -h ~/qdrant_data
} catch {
    Write-Host "  WSL non disponible: $_" -ForegroundColor Red
}

# 3. Taille du répertoire qdrant_data
Write-Host "`n3. Taille ~/qdrant_data:" -ForegroundColor Yellow
try {
    wsl -e du -sh ~/qdrant_data
} catch {
    Write-Host "  WSL non disponible: $_" -ForegroundColor Red
}

# 4. Taille VHDX WSL2
Write-Host "`n4. Taille Disque Virtuel WSL2:" -ForegroundColor Yellow
$wslPath = "$env:LOCALAPPDATA\Packages\*Ubuntu*\LocalState\ext4.vhdx"
$vhdxFiles = Get-ChildItem $wslPath -ErrorAction SilentlyContinue
if ($vhdxFiles) {
    $vhdxFiles | Select-Object Name, @{
        Name="Size_GB";Expression={[math]::Round($_.Length/1GB,2)}
    }, LastWriteTime | Format-Table -AutoSize
} else {
    Write-Host "  Fichier VHDX non trouvé" -ForegroundColor Gray
}

Write-Host "`n=== FIN DIAGNOSTIC ESPACE DISQUE ===" -ForegroundColor Cyan