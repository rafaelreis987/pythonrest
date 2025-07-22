# =============================================
# SQL Server Integration Test Script
# =============================================

#!/usr/bin/env pwsh

# Parar ao primeiro erro
$ErrorActionPreference = "Stop"

# ---------------------------------------------
# Função de log com timestamp
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
        Write-Log "Desativando ambiente virtual PythonREST..."
        deactivate
        $script:PYTHONREST_VENV_ACTIVATED = $false
        Write-Log "Ambiente virtual PythonREST desativado."
    }
}

# ---------------------------------------------
# Registrar cleanup ao sair
# ---------------------------------------------
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Cleanup-PythonRESTVenv }

# ---------------------------------------------
# Diretórios base
# ---------------------------------------------
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Resolve-Path "$SCRIPT_DIR/../../.." | ForEach-Object { $_.Path }

Write-Log "Script dir: $SCRIPT_DIR"
Write-Log "Project root: $PROJECT_ROOT"

Set-Location $PROJECT_ROOT
Write-Log "Mudou para project root: $(Get-Location)"

# ---------------------------------------------
# 1. Início
# ---------------------------------------------
Write-Log "Iniciando teste de integração SQL Server."

# ---------------------------------------------
# 2. Iniciar container SQL Server
# ---------------------------------------------
Set-Location $SCRIPT_DIR
Write-Log "Executando docker compose..."
docker compose down --remove-orphans
docker compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERRO: Falha ao subir container SQL Server."
    docker compose logs
    exit 1
}

Write-Log "Container SQL Server iniciado."

# ---------------------------------------------
# 3. Esperar container ficar saudável
# ---------------------------------------------
$SQLSERVER_CONTAINER_NAME = "sql-server-database-mapper"
Write-Log "Esperando container '$SQLSERVER_CONTAINER_NAME' ficar pronto..."

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
        Write-Log "SQL Server pronto."
        break
    }
    if ($ELAPSED -ge $TIMEOUT) {
        if ($RETRY -lt $MAX_RETRIES) {
            Write-Log "Timeout. Reiniciando container (tentativa $($RETRY + 1)/$MAX_RETRIES)..."
            docker compose restart
            $ELAPSED = 0
            $RETRY++
            continue
        }
        Write-Log "ERRO: SQL Server não ficou pronto após tentativas."
        docker compose logs
        docker inspect $SQLSERVER_CONTAINER_NAME
        docker compose down
        exit 1
    }
    Write-Log "Aguardando... ($ELAPSED/$TIMEOUT)"
    Start-Sleep -Seconds 5
    $ELAPSED += 5
}

# ---------------------------------------------
# 4. Executar script SQL
# ---------------------------------------------
Write-Log "Executando script SQL inicial..."
$SQLCMD_LOG = "$env:TEMP\sqlcmd_sqlserver.log"

docker exec $SQLSERVER_CONTAINER_NAME /opt/mssql-tools18/bin/sqlcmd `
    -C -S localhost -U SA -P '24ad0a77-c59b-4479-b508-72b83615f8ed' -d master `
    -i /docker-entrypoint-initdb.d/database_mapper_sqlserver.sql `
    > $SQLCMD_LOG 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERRO: Falha ao executar script SQL."
    Get-Content $SQLCMD_LOG
    docker compose down
    exit 1
}

Write-Log "Script SQL executado com sucesso."
Start-Sleep -Seconds 10

# ---------------------------------------------
# 5. Ativar venv base PythonREST
# ---------------------------------------------
$VENV_ACTIVATE = "$PROJECT_ROOT/venv/bin/activate"

if (-not (Test-Path $VENV_ACTIVATE)) {
    Write-Log "ERRO: venv PythonREST não encontrado em $VENV_ACTIVATE"
    docker compose down
    exit 1
}

Write-Log "Ativando venv PythonREST..."
. $VENV_ACTIVATE
$script:PYTHONREST_VENV_ACTIVATED = $true
Write-Log "venv PythonREST ativado."

# ---------------------------------------------
# 6. Executar geração PythonREST
# ---------------------------------------------
Write-Log "Executando geração PythonREST..."
Set-Location $PROJECT_ROOT

python "$PROJECT_ROOT/pythonrest.py" generate --sqlserver-connection-string `
    "mssql://sa:24ad0a77-c59b-4479-b508-72b83615f8ed@localhost:1433/database_mapper_sqlserver"

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERRO: Geração PythonREST falhou."
    docker compose down
    exit 1
}

# ---------------------------------------------
# 7. Verificar API gerada
# ---------------------------------------------
$API_PATH = "$PROJECT_ROOT/PythonRestAPI"

if (-not (Test-Path $API_PATH)) {
    Write-Log "ERRO: Pasta PythonRestAPI não encontrada."
    docker compose down
    exit 1
}

Set-Location $API_PATH
Write-Log "Mudou para pasta API gerada: $(Get-Location)"

# ---------------------------------------------
# 8. Criar e ativar venv da API gerada
# ---------------------------------------------
Write-Log "Criando venv da API..."
python -m venv venv

$GENERATED_VENV_ACTIVATE = "$API_PATH/venv/bin/activate"
Write-Log "Ativando venv da API..."
. $GENERATED_VENV_ACTIVATE
Write-Log "venv da API ativado."

# ---------------------------------------------
# 9. Instalar dependências
# ---------------------------------------------
Write-Log "Instalando dependências..."
python -m pip install -r requirements.txt

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERRO: Falha no pip install."
    docker compose down
    exit 1
}

# ---------------------------------------------
# 10. Rodar API
# ---------------------------------------------
$API_LOG = "/tmp/api_sqlserver.log"

$API_LOG_OUT = "/tmp/api_sqlserver_out.log"
$API_LOG_ERR = "/tmp/api_sqlserver_err.log"

Write-Log "Iniciando API Flask..."
$API_PROCESS = Start-Process python -ArgumentList "app.py" `
    -RedirectStandardOutput $API_LOG_OUT `
    -RedirectStandardError $API_LOG_ERR `
    -PassThru


Start-Sleep -Seconds 5

try {
    $response = Invoke-WebRequest -Uri "http://localhost:5000" -UseBasicParsing
    Write-Log "API respondeu com status $($response.StatusCode)."
} catch {
    Write-Log "ERRO: API não respondeu. Verificando log..."
    Get-Content $API_LOG
    Stop-Process -Id $API_PROCESS.Id -Force
    deactivate
    Cleanup-PythonRESTVenv
    docker compose down
    exit 1
}

# ---------------------------------------------
# 11. Testar GET
# ---------------------------------------------
Write-Log "Testando endpoint /swagger..."
Invoke-WebRequest -Uri "http://localhost:5000/swagger" -UseBasicParsing

# ---------------------------------------------
# 12. Finalizar API
# ---------------------------------------------
Write-Log "Parando API (PID $($API_PROCESS.Id))..."
Stop-Process -Id $API_PROCESS.Id -Force

# ---------------------------------------------
# 13. Cleanup final
# ---------------------------------------------
Write-Log "Desativando venv da API..."
deactivate

Write-Log "Desativando venv PythonREST..."
Cleanup-PythonRESTVenv

Write-Log "Parando containers..."
docker compose down

Write-Log "Script de teste SQL Server finalizado com sucesso!"
exit 0
