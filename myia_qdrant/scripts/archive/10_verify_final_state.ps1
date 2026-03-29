# Script de vérification finale
Write-Host "=== CONTENU DE scripts/ ===" -ForegroundColor Cyan
Get-ChildItem scripts/ -File | Select-Object Name, Length | Format-Table -AutoSize

$count = (Get-ChildItem scripts/ -File).Count
Write-Host "Total: $count fichiers" -ForegroundColor Yellow