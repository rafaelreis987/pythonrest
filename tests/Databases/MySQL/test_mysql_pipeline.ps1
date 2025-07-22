#!/usr/bin/env pwsh

# Cross-platform version of MySQL test script for Linux runners using PowerShell Core

# Function for logging
function Write-Log {
    param($Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# Stop on first error
$ErrorActionPreference = "Stop"

# Determine directories
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Resolve-Path "$SCRIPT_DIR/../../.." | ForEach-Object { $_.Path }
Write-Log "Script directory: $SCRIPT_DIR"
Write-Log "Project root: $PROJECT_ROOT"

# Change to project root
Set-Location $PROJECT_ROOT
Write-Log "Changed directory to: $(Get-Location)"

# Start test
Write-Log "Starting MySQL integration test..."

# Bring up Docker container
Set-Location $SCRIPT_DIR
Write-Log "Bringing up MySQL Docker container..."
docker compose down --remove-orphans
docker compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Docker Compose failed."
    docker compose logs
    exit 1
}

# Wait for MySQL to be healthy
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
            Write-Log "Timeout. Restarting container (attempt $($RetryCount + 1)/$MAX_RETRIES)..."
            docker compose restart
            $SECONDS_WAITED = 0
            $RetryCount++
            continue
        }
        Write-Log "ERROR: MySQL did not become healthy."
        docker compose logs
        docker inspect $MYSQL_CONTAINER_NAME
        docker compose down
        exit 1
    }

    Write-Log "Waiting... $SECONDS_WAITED/$TIMEOUT_SECONDS s"
    Start-Sleep -Seconds 5
    $SECONDS_WAITED += 5
}

# Define base venv Python
$PYTHON = "$PROJECT_ROOT/venv/bin/python"

# Check if Python exists
if (-not (Test-Path $PYTHON)) {
    Write-Log "ERROR: Python venv not found at $PYTHON"
    docker compose down
    exit 1
}

Write-Log "Using Python: $PYTHON"

# Run generator
Write-Log "Running PythonREST generate..."
& $PYTHON "$PROJECT_ROOT/pythonrest.py" generate --mysql-connection-string mysql://admin:adminuserdb@localhost:3306/database_mapper_mysql

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: PythonREST generate failed."
    docker compose down
    exit 1
}

# Check generated folder
$GENERATED_API_PATH = "$PROJECT_ROOT/PythonRestAPI"
if (-not (Test-Path $GENERATED_API_PATH)) {
    Write-Log "ERROR: PythonRestAPI folder not found."
    docker compose down
    exit 1
}

Write-Log "PythonRestAPI generated at: $GENERATED_API_PATH"

# Create venv for generated API
Set-Location $GENERATED_API_PATH
Write-Log "Creating venv for generated API..."
& $PYTHON -m venv venv

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to create API venv."
    docker compose down
    exit 1
}

# Define generated API venv Python
$API_VENV_PYTHON = "$GENERATED_API_PATH/venv/bin/python"

if (-not (Test-Path $API_VENV_PYTHON)) {
    Write-Log "ERROR: Generated API Python not found!"
    docker compose down
    exit 1
}

Write-Log "Installing requirements in generated API venv..."
& $API_VENV_PYTHON -m pip install --upgrade pip
& $API_VENV_PYTHON -m pip install -r requirements.txt

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: pip install failed."
    docker compose down
    exit 1
}

# Start API in background
if ($IsWindows) {
    $API_LOG = "$env:TEMP/api_output_mysql.log"
} else {
    $API_LOG = "/tmp/api_output_mysql.log"
}

Write-Log "Starting generated API..."
$API_LOG_OUT = "/tmp/api_mysql_out.log"
$API_LOG_ERR = "/tmp/api_mysql_err.log"

Write-Log "Starting generated API..."
$API_PROCESS = Start-Process $API_VENV_PYTHON -ArgumentList "app.py" `
    -RedirectStandardOutput $API_LOG_OUT `
    -RedirectStandardError $API_LOG_ERR `
    -PassThru



Start-Sleep -Seconds 5

try {
    $Response = Invoke-WebRequest -Uri "http://localhost:5000" -UseBasicParsing
    Write-Log "API responded with status: $($Response.StatusCode)"
} catch {
    Write-Log "API did not respond. Checking log..."
    Get-Content $API_LOG
    Stop-Process -Id $API_PROCESS.Id -Force
    docker compose down
    exit 1
}

# Test /swagger
Write-Log "Checking /swagger..."
Invoke-WebRequest -Uri "http://localhost:5000/swagger" -UseBasicParsing

# Stop API
Write-Log "Stopping generated API..."
Stop-Process -Id $API_PROCESS.Id -Force

# Stop containers
Write-Log "Stopping Docker containers..."
docker compose down

Write-Log "MySQL integration test completed successfully."
exit 0
