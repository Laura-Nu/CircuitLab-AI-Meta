$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$taskRegistry = Join-Path $taskRoot '.tools/dev/processes.json'
if (-not (Test-Path -LiteralPath $taskRegistry)) { Write-Output 'No hay procesos registrados.'; exit 0 }
$taskRecords = Get-Content -Raw -LiteralPath $taskRegistry | ConvertFrom-Json
foreach ($taskRecord in $taskRecords) {
    $taskProcess = Get-Process -Id $taskRecord.id -ErrorAction SilentlyContinue
    if ($null -ne $taskProcess -and $taskProcess.StartTime.ToUniversalTime().ToString('o') -eq $taskRecord.started) {
        $taskProcess.Kill()
        if (-not $taskProcess.WaitForExit(5000)) { throw ('No se pudo detener el proceso registrado ' + $taskRecord.id) }
    }
}
Remove-Item -LiteralPath $taskRegistry
Write-Output 'Procesos locales detenidos.'
