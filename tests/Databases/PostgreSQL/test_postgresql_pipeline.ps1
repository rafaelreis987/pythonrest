#!/usr/bin/env pwsh

# Function to log messages with timestamp
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
Write-Log "Changed directory to project root: $(Get-Location)"

# Start
Write-Log "Starting PostgreSQL integration test script."

# Start PostgreSQL container
Write-Log "Starting PostgreSQL Docker container..."
Set-Location $SCRIPT_DIR
docker compose down --remove-orphans
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to start PostgreSQL Docker container."
    docker compose logs
    exit 1
}
Write-Log "PostgreSQL Docker container started."

# Wait for container to be healthy (placeholder)
$POSTGRES_CONTAINER_NAME = "postgresql-postgres-1"
Write-Log "Waiting for PostgreSQL container ($POSTGRES_CONTAINER_NAME) to be ready..."
Start-Sleep -Seconds 10

# Use base venv Python directly
$PYTHON = "$PROJECT_ROOT/venv/bin/python"

if (-not (Test-Path $PYTHON)) {
    Write-Log "ERROR: PythonREST venv not found at $PYTHON"
    docker compose down
    exit 1
}
Write-Log "Using base Python: $PYTHON"

# Run PythonREST generation
Write-Log "Running PythonREST generation using $PROJECT_ROOT/pythonrest.py..."
Set-Location $PROJECT_ROOT

& $PYTHON "$PROJECT_ROOT/pythonrest.py" generate --postgres-connection-string "postgresql://admin:adminuserdb@localhost:5432/database_mapper_postgresql?options=-c%20search_path=database_mapper_postgresql,public"

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: PythonREST generation failed."
    docker compose down
    exit 1
}

Write-Log "PythonREST generation completed successfully."

# Check generated folder
$GENERATED_API_PATH = "$PROJECT_ROOT/PythonRestAPI"
Write-Log "Checking for generated API at: $GENERATED_API_PATH"
if (-not (Test-Path $GENERATED_API_PATH)) {
    Write-Log "ERROR: 'PythonRestAPI' folder not found at $GENERATED_API_PATH after generation."
    docker compose down
    exit 1
}

Write-Log "'PythonRestAPI' folder found."

# Create venv for generated API
Set-Location $GENERATED_API_PATH
Write-Log "Creating Python virtual environment for generated API..."
& $PYTHON -m venv venv
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to create Python virtual environment."
    docker compose down
    exit 1
}

# Use generated API venv Python directly
$API_PYTHON = "$GENERATED_API_PATH/venv/bin/python"
if (-not (Test-Path $API_PYTHON)) {
    Write-Log "ERROR: Generated API Python not found!"
    docker compose down
    exit 1
}

Write-Log "Installing dependencies from requirements.txt..."
& $API_PYTHON -m pip install --upgrade pip
& $API_PYTHON -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: pip install failed."
    docker compose down
    exit 1
}

Write-Log "Dependencies installed successfully."

# Start Flask API in background
$API_LOG = "/tmp/api_output_postgres.log"

# Garante que o log existe
New-Item -ItemType File -Path $API_LOG -Force | Out-Null

Write-Log "Starting Flask API..."
$API_PROCESS = Start-Process $API_PYTHON -ArgumentList "app.py" `
    -RedirectStandardOutput $API_LOG `
    -RedirectStandardError $API_LOG `
    -PassThru

Write-Log "Flask API started with PID $($API_PROCESS.Id)."

Start-Sleep -Seconds 5

if (Test-Path $API_LOG) {
    Get-Content $API_LOG
} else {
    Write-Host "Log file $API_LOG not found."
}
Write-Log "Flask API started with PID $($API_PROCESS.Id)."


# Wait for API
Write-Log "Waiting for API to start..."
Start-Sleep -Seconds 5

try {
    $response = Invoke-WebRequest -Uri "http://localhost:5000" -UseBasicParsing
    Write-Log "API responded with status code $($response.StatusCode)."
} catch {
    Write-Log "ERROR: API did not respond. Checking log:"
    Get-Content $API_LOG
    Stop-Process -Id $API_PROCESS.Id -Force
    docker compose down
    exit 1
}

# Test /swagger
Write-Log "Checking /swagger endpoint..."
Invoke-WebRequest -Uri "http://localhost:5000/swagger" -UseBasicParsing

# Stop API
Write-Log "Stopping Flask API..."
Stop-Process -Id $API_PROCESS.Id -Force

# Stop container
Write-Log "Stopping and removing PostgreSQL Docker container..."
docker compose down

Write-Log "PostgreSQL integration test script completed successfully."
exit 0
