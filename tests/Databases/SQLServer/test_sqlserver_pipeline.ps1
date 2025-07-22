# =============================================
# SQL Server Integration Test Script
# =============================================

# Sair ao primeiro erro
$ErrorActionPreference = "Stop"

# ---------------------------------------------
# Função para logar mensagens com timestamp
# ---------------------------------------------
function Write-Log {
    param($Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# ---------------------------------------------
# Função de cleanup do venv principal
# ---------------------------------------------
function Cleanup-PythonRESTVenv {
    if ($script:PYTHONREST_VENV_ACTIVATED) {
        Write-Log "Desativando o ambiente virtual PythonREST..."
        deactivate
        $script:PYTHONREST_VENV_ACTIVATED = $false
        Write-Log "Ambiente virtual PythonREST desativado."
    }
}

# ---------------------------------------------
# Registrar cleanup para rodar no exit
# ---------------------------------------------
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Cleanup-PythonRESTVenv }

# ---------------------------------------------
# Paths
# ---------------------------------------------
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Resolve-Path (Join-Path $SCRIPT_DIR "..\..\..\") | ForEach-Object { $_.Path }

Write-Log "Script dir: $SCRIPT_DIR"
Write-Log "Project root: $PROJECT_ROOT"

Set-Location $PROJECT_ROOT
Write-Log "Changed to project root: $(Get-Location)"

# ---------------------------------------------
# 1. Start
# ---------------------------------------------
Write-Log "Starting SQL Server integration test."

# ---------------------------------------------
# 2. Start SQL Server container
# ---------------------------------------------
Set-Location $SCRIPT_DIR
Write-Log "Running docker compose..."
docker compose down --remove-orphans
docker compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to start SQL Server container."
    docker compose logs
    exit 1
}

Write-Log "Container up."

# ---------------------------------------------
# 3. Wait for SQL Server to be healthy
# ---------------------------------------------
$SQLSERVER_CONTAINER_NAME = "sql-server-database-mapper"
Write-Log "Waiting for container '$SQLSERVER_CONTAINER_NAME' to be healthy..."

function Test-SQLServerReady {
    try {
        $logs = docker logs $SQLSERVER_CONTAINER_NAME
        return $logs -match "Recovery is complete"
    } catch { return $false }
}

$TIMEOUT = 120
$ELAPSED = 0
$MAX_RETRIES = 3
$RETRY = 0

while ($true) {
    if (Test-SQLServerReady) {
        Write-Log "SQL Server is ready."
        break
    }
    if ($ELAPSED -ge $TIMEOUT) {
        if ($RETRY -lt $MAX_RETRIES) {
            Write-Log "Timeout. Restarting container (attempt $($RETRY + 1)/$MAX_RETRIES)..."
            docker compose restart
            $ELAPSED = 0
            $RETRY++
            continue
        }
        Write-Log "ERROR: SQL Server not ready after retries."
        docker compose logs
        docker inspect $SQLSERVER_CONTAINER_NAME
        docker compose down
        exit 1
    }
    Write-Log "Waiting... ($ELAPSED/$TIMEOUT)"
    Start-Sleep -Seconds 5
    $ELAPSED += 5
}

# ---------------------------------------------
# 4. Run SQL script
# ---------------------------------------------
Write-Log "Running init SQL script..."
$SQLCMD_LOG = "$env:TEMP\sqlcmd_sqlserver.log"
docker exec $SQLSERVER_CONTAINER_NAME /opt/mssql-tools18/bin/sqlcmd `
    -C -S localhost -U SA -P '24ad0a77-c59b-4479-b508-72b83615f8ed' -d master `
    -i /docker-entrypoint-initdb.d/database_mapper_sqlserver.sql `
    > $SQLCMD_LOG 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: SQL script failed."
    Get-Content $SQLCMD_LOG
    docker compose down
    exit 1
}

Write-Log "SQL script executed."

Start-Sleep -Seconds 10

# ---------------------------------------------
# 5. Activate PythonREST venv
# ---------------------------------------------
$VENV_ACTIVATE = Join-Path $PROJECT_ROOT "venv\Scripts\Activate.ps1"

if (-not (Test-Path $VENV_ACTIVATE)) {
    Write-Log "ERROR: PythonREST venv not found at $VENV_ACTIVATE"
    docker compose down
    exit 1
}

. $VENV_ACTIVATE
$script:PYTHONREST_VENV_ACTIVATED = $true
Write-Log "PythonREST venv activated."

# ---------------------------------------------
# 6. Run PythonREST generation
# ---------------------------------------------
Write-Log "Running PythonREST generate..."
Set-Location $PROJECT_ROOT

python "$PROJECT_ROOT\pythonrest.py" generate --sqlserver-connection-string `
    "mssql://sa:24ad0a77-c59b-4479-b508-72b83615f8ed@localhost:1433/database_mapper_sqlserver"

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Generation failed."
    docker compose down
    exit 1
}

# ---------------------------------------------
# 7. Check generated API
# ---------------------------------------------
$API_PATH = Join-Path $PROJECT_ROOT "PythonRestAPI"

if (-not (Test-Path $API_PATH)) {
    Write-Log "ERROR: PythonRestAPI not found."
    docker compose down
    exit 1
}

Set-Location $API_PATH
Write-Log "Switched to generated API dir: $(Get-Location)"

# ---------------------------------------------
# 8. Create & activate API venv
# ---------------------------------------------
Write-Log "Creating API venv..."
python -m venv venv
. (Join-Path $API_PATH "venv\Scripts\Activate.ps1")
Write-Log "API venv activated."

# ---------------------------------------------
# 9. Install deps
# ---------------------------------------------
Write-Log "Installing dependencies..."
python -m pip install -r requirements.txt

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: pip install failed."
    exit 1
}

# ---------------------------------------------
# 10. Run API
# ---------------------------------------------
$API_LOG = "$env:TEMP\api_sqlserver.log"
$API_ERR = "$env:TEMP\api_sqlserver_err.log"

Write-Log "Starting API..."
$API_PROCESS = Start-Process python -ArgumentList "app.py" `
    -RedirectStandardOutput $API_LOG `
    -RedirectStandardError $API_ERR `
    -PassThru

Start-Sleep -Seconds 5

try {
    $r = Invoke-WebRequest -Uri "http://localhost:5000" -UseBasicParsing -OutFile "$env:TEMP\curl_check_sqlserver.log"
    Write-Log "API is up (status $($r.StatusCode))"
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -ne 400 -and $status -ne 404) {
        Write-Log "ERROR: API not responding. Logs:"
        Get-Content $API_LOG
        Get-Content $API_ERR
        Stop-Process -Id $API_PROCESS.Id -Force
        deactivate
        docker compose down
        exit 1
    }
    Write-Log "API up (status $status)"
}

Remove-Item "$env:TEMP\curl_check_sqlserver.log" -ErrorAction SilentlyContinue

# ---------------------------------------------
# 11. Test GET
# ---------------------------------------------
Write-Log "Testing GET /swagger..."
Invoke-WebRequest -Uri "http://localhost:5000/swagger" -UseBasicParsing -OutFile "$env:TEMP\curl_test_sqlserver.log"

# ---------------------------------------------
# 12. Kill API
# ---------------------------------------------
Write-Log "Killing API (PID $($API_PROCESS.Id))..."
Stop-Process -Id $API_PROCESS.Id -Force

# ---------------------------------------------
# 13. Cleanup
# ---------------------------------------------
Write-Log "Deactivating API venv..."
deactivate

Write-Log "Deactivating PythonREST venv..."
Cleanup-PythonRESTVenv

Write-Log "Stopping containers..."
docker compose down

Write-Log "Done!"
exit 0
