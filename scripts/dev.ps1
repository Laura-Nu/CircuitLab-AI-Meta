param(
    [ValidateSet('file', 'resend', 'smtp', 'disabled')]
    [string]$RecoveryDelivery = 'file',
    [ValidateSet('disabled', 'meta', 'simulation')]
    [string]$StoryMode = 'simulation'
)
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$taskBackend = Join-Path $taskRoot 'services/backend'
$taskPython = Join-Path $taskBackend '.venv/Scripts/python.exe'
$taskWeb = Join-Path $taskRoot 'build/site'
$taskState = Join-Path $taskRoot '.tools/dev'
if (-not (Test-Path -LiteralPath $taskPython)) { throw 'Ejecuta uv sync --frozen en services/backend primero.' }
if (-not (Test-Path -LiteralPath (Join-Path $taskWeb 'app/index.html'))) { throw 'Compila Flutter con --base-href /app/ y ejecuta python scripts/build_site.py primero.' }
if (Test-Path -LiteralPath (Join-Path $taskState 'processes.json')) { throw 'Ya existe un registro de procesos. Ejecuta scripts/stop-dev.ps1 antes de reiniciar.' }
New-Item -ItemType Directory -Force -Path $taskState | Out-Null
$env:APP_ENV = 'development'
$env:AI_MODE = 'simulation'
$env:DATABASE_URL = 'sqlite:///' + (Join-Path $taskState 'circuitlab.db').Replace('\', '/')
$env:STORAGE_ROOT = Join-Path $taskState 'evidence'
$env:APP_ORIGIN = 'http://localhost:8080'
$env:RECOVERY_DELIVERY = $RecoveryDelivery
$env:RECOVERY_DIRECTORY = Join-Path $taskState 'recovery'
$env:STORYBOARD_MODE = $StoryMode
Push-Location $taskBackend
try {
    & $taskPython -m alembic upgrade head
    if ($LASTEXITCODE -ne 0) { throw 'Migración fallida' }
    & $taskPython (Join-Path $PSScriptRoot 'seed_demo.py')
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear la cuenta demo' }
    $taskProcesses = @()
    $taskProcesses += Start-Process -FilePath $taskPython -ArgumentList '-m','uvicorn','app.main:app','--host','127.0.0.1','--port','8000' -WorkingDirectory $taskBackend -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskState 'api.log') -RedirectStandardError (Join-Path $taskState 'api-error.log')
    $taskProcesses += Start-Process -FilePath $taskPython -ArgumentList '-m','app.worker' -WorkingDirectory $taskBackend -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskState 'worker.log') -RedirectStandardError (Join-Path $taskState 'worker-error.log')
    $taskProcesses += Start-Process -FilePath $taskPython -ArgumentList '-m','http.server','8080','--bind','127.0.0.1' -WorkingDirectory $taskWeb -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskState 'web.log') -RedirectStandardError (Join-Path $taskState 'web-error.log')
    $taskProcesses | ForEach-Object { @{ id = $_.Id; started = $_.StartTime.ToUniversalTime().ToString('o') } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskState 'processes.json')
} finally { Pop-Location }
Write-Output 'Landing: http://localhost:8080  |  Laboratorio: http://localhost:8080/app/  |  API: http://localhost:8000/docs'
Write-Output 'Modo: SIMULACION. Usuario: demo@circuitlab.local. Clave demo local: CircuitLab-demo-2026'
