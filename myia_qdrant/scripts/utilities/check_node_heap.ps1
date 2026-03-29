# Vérification du processus Node.js roo-state-manager avec heap size

Write-Host "=== VÉRIFICATION PROCESSUS NODE.JS MCP ===" -ForegroundColor Cyan
Write-Host ""

# Récupérer tous les processus node.exe
$nodeProcesses = Get-CimInstance Win32_Process -Filter "name = 'node.exe'"

# Filtrer ceux qui concernent roo-state-manager
$mcpProcesses = $nodeProcesses | Where-Object { $_.CommandLine -like '*roo-state-manager*' }

if ($mcpProcesses) {
    foreach ($proc in $mcpProcesses) {
        Write-Host "Processus trouvé:" -ForegroundColor Green
        Write-Host "  PID: $($proc.ProcessId)"
        Write-Host "  Mémoire: $([math]::Round($proc.WorkingSetSize / 1MB, 2)) MB"
        Write-Host "  CommandLine:" -ForegroundColor Yellow
        Write-Host "    $($proc.CommandLine)" -ForegroundColor White
        Write-Host ""
        
        # Vérifier la présence du paramètre heap
        if ($proc.CommandLine -like '*--max-old-space-size=4096*') {
            Write-Host "  ✅ HEAP SIZE CORRECT (4096 MB)" -ForegroundColor Green
        } elseif ($proc.CommandLine -like '*--max-old-space-size*') {
            Write-Host "  ⚠️ HEAP SIZE PRÉSENT MAIS VALEUR DIFFÉRENTE" -ForegroundColor Yellow
        } else {
            Write-Host "  ❌ HEAP SIZE NON DÉFINI" -ForegroundColor Red
        }
    }
} else {
    Write-Host "❌ Aucun processus roo-state-manager trouvé" -ForegroundColor Red
    Write-Host ""
    Write-Host "Tous les processus node.exe:" -ForegroundColor Yellow
    $nodeProcesses | Select-Object ProcessId, @{Name='Memory_MB';Expression={[math]::Round($_.WorkingSetSize / 1MB, 2)}}, CommandLine | Format-Table -AutoSize
}