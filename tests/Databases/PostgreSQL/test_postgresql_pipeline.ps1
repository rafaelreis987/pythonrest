#!/usr/bin/env pwsh

# Function to log messages with timestamp
function Write-Log {
    param($Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# Stop on first error
$ErrorActionPreference = "Stop"

# Function to deactivate base PythonREST venv on exit
function Cleanup-PythonRESTVenv {
    if ($script:PYTHONREST_VENV_ACTIVATED) {
        Write-Log "Deactivating base PythonREST virtual environment due to script exit..."
        deactivate
        Write-Log "Base PythonREST virtual environment deactivated."
        $script:PYTHONREST_VENV_ACTIVATED = $false
    }
}

# Register cleanup
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Cleanup-PythonRESTVenv }

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
docker-compose down --remove-orphans
docker-compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to start PostgreSQL Docker container."
    docker-compose logs
    exit 1
}
Write-Log "PostgreSQL Docker container started."

# Wait for container to be healthy (example placeholder)
$POSTGRES_CONTAINER_NAME = "postgresql-postgres-1"
Write-Log "Waiting for PostgreSQL container ($POSTGRES_CONTAINER_NAME) to be healthy..."
Start-Sleep -Seconds 10

# Activate base venv
$VENV_ACTIVATE = "$PROJECT_ROOT/venv/bin/activate"
Write-Log "Activating shared PythonREST virtual environment: $VENV_ACTIVATE"
if (-not (Test-Path $VENV_ACTIVATE)) {
    Write-Log "ERROR: PythonREST venv activate script not found at $VENV_ACTIVATE"
    docker-compose down
    exit 1
}
. $VENV_ACTIVATE
$script:PYTHONREST_VENV_ACTIVATED = $true
Write-Log "Shared PythonREST virtual environment activated."

# Run PythonREST generation
Write-Log "Running PythonREST generation using $PROJECT_ROOT/pythonrest.py..."
Set-Location $PROJECT_ROOT

python "$PROJECT_ROOT/pythonrest.py" generate --postgres-connection-string "postgresql://admin:adminuserdb@localhost:5432/database_mapper_postgresql?options=-c%20search_path=database_mapper_postgresql,public"

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: PythonREST generation failed."
    docker-compose down
    exit 1
}

Write-Log "PythonREST generation completed successfully."

# Check generated folder
$GENERATED_API_PATH = "$PROJECT_ROOT/PythonRestAPI"
Write-Log "Checking for generated API at: $GENERATED_API_PATH"
if (-not (Test-Path $GENERATED_API_PATH)) {
    Write-Log "ERROR: 'PythonRestAPI' folder not found at $GENERATED_API_PATH after generation."
    docker-compose down
    exit 1
}

Write-Log "'PythonRestAPI' folder found at $GENERATED_API_PATH."

# Go to generated API folder
Set-Location $GENERATED_API_PATH
Write-Log "Changed directory to $(Get-Location)."

# Create venv for generated API
Write-Log "Creating Python virtual environment for generated API..."
python -m venv venv
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to create Python virtual environment."
    docker-compose down
    exit 1
}

# Activate generated API venv
if ($IsWindows) {
    $GENERATED_VENV_ACTIVATE = "./venv/Scripts/activate.ps1"
} else {
    $GENERATED_VENV_ACTIVATE = "./venv/bin/activate.ps1"
}
Write-Log "Activating virtual environment for generated API..."
. $GENERATED_VENV_ACTIVATE
Write-Log "Virtual environment for generated API activated."

# Install dependencies
Write-Log "Installing dependencies from requirements.txt..."
python -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: pip install failed."
    docker-compose down
    exit 1
}

Write-Log "Dependencies installed successfully."

# Start Flask API in background
$API_LOG = "/tmp/api_output_postgres.log"
Write-Log "Starting Flask API..."
$API_PROCESS = Start-Process python -ArgumentList "app.py" -RedirectStandardOutput $API_LOG -RedirectStandardError $API_LOG -PassThru
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
    deactivate
    Write-Log "Deactivated generated API venv."
    docker-compose down
    exit 1
}

# Sample GET
Write-Log "Checking /swagger endpoint..."
Invoke-WebRequest -Uri "http://localhost:5000/swagger" -UseBasicParsing

# Kill API
Write-Log "Stopping Flask API..."
Stop-Process -Id $API_PROCESS.Id -Force

# Deactivate generated API venv
Write-Log "Deactivating generated API virtual environment..."
deactivate

# Deactivate base venv
Write-Log "Deactivating shared PythonREST virtual environment..."
deactivate
$script:PYTHONREST_VENV_ACTIVATED = $false

# Stop container
Write-Log "Stopping and removing PostgreSQL Docker container..."
docker-compose down

Write-Log "PostgreSQL integration test script completed successfully."
exit 0
