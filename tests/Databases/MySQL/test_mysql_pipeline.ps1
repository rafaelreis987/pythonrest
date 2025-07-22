#!/usr/bin/env pwsh

# Cross-platform version of MySQL test script
# For Linux runners using PowerShell Core (pwsh)

# Function for logging
function Write-Log {
    param($Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# Stop on first error
$ErrorActionPreference = "Stop"

# Cleanup handler for base venv
function Cleanup-PythonRESTVenv {
    if ($script:PYTHONREST_VENV_ACTIVATED) {
        Write-Log "Deactivating base PythonREST venv..."
        deactivate
        $script:PYTHONREST_VENV_ACTIVATED = $false
    }
}

# Register cleanup on exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Cleanup-PythonRESTVenv }

# Determine directories
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Resolve-Path "$SCRIPT_DIR/../../.." | ForEach-Object { $_.Path }
Write-Log "Script directory: $SCRIPT_DIR"
Write-Log "Project root: $PROJECT_ROOT"

# Change to project root
Set-Location $PROJECT_ROOT
Write-Log "Changed directory to: $(Get-Location)"

# Start
Write-Log "Starting MySQL integration test..."

# Start Docker container
Set-Location $SCRIPT_DIR
Write-Log "Bringing up MySQL Docker container..."
docker-compose down --remove-orphans
docker-compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Docker Compose failed."
    docker-compose logs
    exit 1
}

# Wait for container to be healthy
$MYSQL_CONTAINER_NAME = "mysql-mysql-1"
Write-Log "Waiting for container $MYSQL_CONTAINER_NAME to be healthy..."

function Test-MySQLReady {
    try {
        $result = docker exec $MYSQL_CONTAINER_NAME mysqladmin ping -h localhost -u admin -padminuserdb --silent
        return $result -eq "mysqld is alive"
    } catch {
        return $false
    }
}

$TIMEOUT_SECONDS = 120
$SECONDS_WAITED = 0
$MAX_RETRIES = 3
$RetryCount = 0

while ($true) {
    if (Test-MySQLReady) {
        Write-Log "MySQL is ready."
        break
    }

    if ($SECONDS_WAITED -ge $TIMEOUT_SECONDS) {
        if ($RetryCount -lt $MAX_RETRIES) {
            Write-Log "Timeout. Restarting container (attempt $($RetryCount+1)/$MAX_RETRIES)..."
            docker-compose restart
            $SECONDS_WAITED = 0
            $RetryCount++
            continue
        }
        Write-Log "ERROR: MySQL did not become healthy."
        docker-compose logs
        docker inspect $MYSQL_CONTAINER_NAME
        docker-compose down
        exit 1
    }

    Write-Log "Waiting... $SECONDS_WAITED/$TIMEOUT_SECONDS s"
    Start-Sleep -Seconds 5
    $SECONDS_WAITED += 5
}

# Activate base venv
$VENV_ACTIVATE = "$PROJECT_ROOT/venv/bin/activate"
Write-Log "Activating base venv: $VENV_ACTIVATE"

if (-not (Test-Path $VENV_ACTIVATE)) {
    Write-Log "ERROR: venv activate not found!"
    docker-compose down
    exit 1
}

. $VENV_ACTIVATE
$script:PYTHONREST_VENV_ACTIVATED = $true
Write-Log "Base venv activated."

# Run generator
Write-Log "Running PythonREST generate..."
Set-Location $PROJECT_ROOT
python "$PROJECT_ROOT/pythonrest.py" generate --mysql-connection-string mysql://admin:adminuserdb@localhost:3306/database_mapper_mysql

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: PythonREST generate failed."
    docker-compose down
    exit 1
}

# Check generated folder
$GENERATED_API_PATH = "$PROJECT_ROOT/PythonRestAPI"
if (-not (Test-Path $GENERATED_API_PATH)) {
    Write-Log "ERROR: PythonRestAPI folder not found."
    docker-compose down
    exit 1
}

Write-Log "PythonRestAPI generated at: $GENERATED_API_PATH"

# Create venv for generated API
Set-Location $GENERATED_API_PATH
Write-Log "Creating venv for generated API..."
python -m venv venv
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to create API venv."
    docker-compose down
    exit 1
}

# Activate API venv
$API_VENV_ACTIVATE = "./venv/bin/activate"
Write-Log "Activating generated API venv..."
. $API_VENV_ACTIVATE

# Install requirements
Write-Log "Installing requirements..."
python -m pip install -r requirements.txt

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: pip install failed."
    docker-compose down
    exit 1
}

# Start API in background
$API_LOG = "/tmp/api_output_mysql.log"
Write-Log "Starting API..."
$API_PROCESS = Start-Process python -ArgumentList "app.py" -RedirectStandardOutput $API_LOG -RedirectStandardError $API_LOG -PassThru

Start-Sleep -Seconds 5

try {
    $Response = Invoke-WebRequest -Uri "http://localhost:5000" -UseBasicParsing
    Write-Log "API responded with status: $($Response.StatusCode)"
} catch {
    Write-Log "API did not respond. Checking log..."
    Get-Content $API_LOG
    Stop-Process -Id $API_PROCESS.Id -Force
    docker-compose down
    exit 1
}

# Do a test GET
Write-Log "Checking /swagger..."
Invoke-WebRequest -Uri "http://localhost:5000/swagger" -UseBasicParsing

# Kill API
Write-Log "Stopping API..."
Stop-Process -Id $API_PROCESS.Id -Force

# Deactivate venvs
Write-Log "Deactivating generated API venv..."
deactivate

Write-Log "Deactivating base venv..."
deactivate

$script:PYTHONREST_VENV_ACTIVATED = $false

# Stop containers
Write-Log "Stopping Docker containers..."
docker-compose down

Write-Log "MySQL integration test completed successfully."
exit 0
