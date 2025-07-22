#!/usr/bin/env bash

# Exit on first error
set -e

# Função para logar mensagens com timestamp
write_log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Função para limpar venv PythonREST ao sair
cleanup_pythonrest_venv() {
  if [[ $PYTHONREST_VENV_ACTIVATED == true ]]; then
    write_log "Desativando o ambiente virtual PythonREST devido à saída do script..."
    deactivate
    write_log "Ambiente virtual PythonREST desativado."
    PYTHONREST_VENV_ACTIVATED=false
  fi
}

trap cleanup_pythonrest_venv EXIT

# 0. Determinar diretórios
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( realpath "$SCRIPT_DIR/../../../" )"

write_log "Script directory: $SCRIPT_DIR"
write_log "Project root: $PROJECT_ROOT"

# Mudar para o diretório raiz do projeto
cd "$PROJECT_ROOT"
write_log "Changed directory to project root: $(pwd)"

# 1. Início
write_log "Starting SQL Server integration test script."

# 2. Subir container SQL Server
write_log "Starting SQL Server Docker container..."
cd "$SCRIPT_DIR"
write_log "Changed directory to script location for Docker operations: $(pwd)"
docker compose down --remove-orphans
docker compose up -d || {
  write_log "ERROR: Failed to start SQL Server Docker container."
  write_log "Checking docker-compose logs:"
  docker compose logs
  exit 1
}
write_log "SQL Server Docker container started."

# 3. Esperar container ficar healthy
SQLSERVER_CONTAINER_NAME="sql-server-database-mapper"
write_log "Waiting for SQL Server container ($SQLSERVER_CONTAINER_NAME) to be healthy..."

test_sqlserver_ready() {
  logs=$(docker logs "$SQLSERVER_CONTAINER_NAME" 2>/dev/null || true)
  echo "$logs" | grep -q "Recovery is complete. This is an informational message only. No user action is required."
}

TIMEOUT_SECONDS=120
SECONDS_WAITED=0
MAX_RETRIES=3
retry_count=0

while true; do
  if test_sqlserver_ready; then
    write_log "SQL Server container is ready and accepting connections."
    break
  fi

  if [[ $SECONDS_WAITED -ge $TIMEOUT_SECONDS ]]; then
    if [[ $retry_count -lt $MAX_RETRIES ]]; then
      write_log "Timeout reached. Attempting to restart container (Attempt $((retry_count + 1)) of $MAX_RETRIES)..."
      docker compose restart
      SECONDS_WAITED=0
      ((retry_count++))
      continue
    fi

    write_log "ERROR: SQL Server container failed to become ready after $MAX_RETRIES attempts."
    write_log "Container logs:"
    docker compose logs
    write_log "Container details:"
    docker inspect "$SQLSERVER_CONTAINER_NAME"
    docker compose down
    exit 1
  fi

  write_log "Waiting for SQL Server to be ready... ($SECONDS_WAITED/$TIMEOUT_SECONDS seconds)"
  sleep 5
  SECONDS_WAITED=$((SECONDS_WAITED + 5))
  write_log "Still waiting for SQL Server container... ($SECONDS_WAITED/$TIMEOUT_SECONDS seconds)"
done

write_log "SQL Server container is ready and healthy."

# Executar script SQL
write_log "Executing SQL script to create database and tables..."
SQLCMD_LOG="/tmp/sqlcmd_output_sqlserver.log"
docker exec "$SQLSERVER_CONTAINER_NAME" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U SA -P '24ad0a77-c59b-4479-b508-72b83615f8ed' -d master -i /docker-entrypoint-initdb.d/database_mapper_sqlserver.sql > "$SQLCMD_LOG" 2>&1 || {
  write_log "ERROR: Failed to execute SQL script. See $SQLCMD_LOG for details."
  cat "$SQLCMD_LOG"
  docker compose down
  exit 1
}
write_log "SQL script executed successfully. Output logged to $SQLCMD_LOG."
sleep 10

# 4. Ativar venv PythonREST
VENV_ACTIVATE="$PROJECT_ROOT/venv/bin/activate"
write_log "Activating shared PythonREST virtual environment: $VENV_ACTIVATE"
if [[ ! -f "$VENV_ACTIVATE" ]]; then
  write_log "ERROR: PythonREST venv activate script not found at $VENV_ACTIVATE"
  docker compose down
  exit 1
fi
# shellcheck disable=SC1090
source "$VENV_ACTIVATE"
PYTHONREST_VENV_ACTIVATED=true
write_log "Shared PythonREST virtual environment activated."

# 5. Rodar geração PythonREST
write_log "Running PythonREST generation using $PROJECT_ROOT/pythonrest.py..."
cd "$PROJECT_ROOT"
write_log "Changed directory to project root for PythonREST generation: $(pwd)"

python "$PROJECT_ROOT/pythonrest.py" generate --sqlserver-connection-string "mssql://sa:24ad0a77-c59b-4479-b508-72b83615f8ed@localhost:1433/database_mapper_sqlserver" || {
  write_log "ERROR: PythonREST generation failed."
  cd "$SCRIPT_DIR"
  docker compose down
  exit 1
}

write_log "PythonREST generation completed successfully."

# 6. Checar pasta PythonRestAPI
GENERATED_API_PATH="$PROJECT_ROOT/PythonRestAPI"
write_log "Checking for generated API at: $GENERATED_API_PATH"
if [[ ! -d "$GENERATED_API_PATH" ]]; then
  write_log "ERROR: 'PythonRestAPI' folder not found at $GENERATED_API_PATH after PythonREST generation."
  cd "$SCRIPT_DIR"
  docker compose down
  exit 1
fi
write_log "PythonREST generation successful. 'PythonRestAPI' folder found at $GENERATED_API_PATH."

# 7. Ir para PythonRestAPI
cd "$GENERATED_API_PATH"
write_log "Changed directory to $(pwd)."

# 8. Criar venv para API gerada
write_log "Creating Python virtual environment for generated API..."
python -m venv venv || {
  write_log "ERROR: Failed to create Python virtual environment for generated API."
  cd "$SCRIPT_DIR"
  docker compose down
  exit 1
}
write_log "Python virtual environment for generated API created."

# 9. Ativar venv da API gerada
GENERATED_VENV_ACTIVATE="$(pwd)/venv/bin/activate"
write_log "Activating virtual environment for generated API..."
# shellcheck disable=SC1090
source "$GENERATED_VENV_ACTIVATE"
write_log "Virtual environment for generated API activated."

# 10. Instalar dependências
PIP_LOG="/tmp/pip_install_sqlserver_api.log"
write_log "Installing dependencies from requirements.txt for generated API..."
pip install -r requirements.txt | tee "$PIP_LOG"

write_log "Dependencies for generated API installed successfully. Output logged to $PIP_LOG"

# 11. Iniciar Flask API em background
write_log "Starting Flask API in the background..."
API_LOG="/tmp/api_output_sqlserver.log"
API_LOG_ERROR="/tmp/api_error_output_sqlserver.log"
write_log "API output will be logged to: $API_LOG"
write_log "API errors will be logged to: $API_LOG_ERROR"

python app.py > "$API_LOG" 2> "$API_LOG_ERROR" &
API_PID=$!
write_log "Flask API started with PID $API_PID. Output logged to $API_LOG."

# 12. Esperar API subir
write_log "Waiting for API to start (5 seconds)..."
sleep 5

if curl -sSf -o /tmp/curl_check_sqlserver.log http://localhost:5000; then
  write_log "API started and responding."
else
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5000 || true)
  if [[ "$HTTP_CODE" == "404" || "$HTTP_CODE" == "400" ]]; then
    write_log "API started and responded with $HTTP_CODE (no route '/' or bad request). This is expected for generated APIs."
  else
    write_log "ERROR: API failed to start or is not responding. Curl check failed."
    cat /tmp/curl_check_sqlserver.log || true
    write_log "API logs ($API_LOG):"
    cat "$API_LOG" || true
    write_log "API error logs ($API_LOG_ERROR):"
    cat "$API_LOG_ERROR" || true
    kill "$API_PID" || true
    deactivate
    write_log "Virtual environment for generated API deactivated."
    cd "$SCRIPT_DIR"
    docker compose down
    exit 1
  fi
fi
rm -f /tmp/curl_check_sqlserver.log

# 13. Teste GET
write_log "Performing sample GET request to http://localhost:5000/swagger..."
curl -sSf http://localhost:5000/swagger -o /tmp/curl_test_sqlserver.log || {
  write_log "WARNING: Sample GET request failed. This might indicate an issue or no default route."
  cat /tmp/curl_test_sqlserver.log
}
write_log "Sample GET request successful. Response logged to /tmp/curl_test_sqlserver.log."

# 14. Matar API
write_log "Killing Flask API (PID $API_PID)..."
kill "$API_PID" || true
write_log "Flask API process killed."

# 15. Desativar venv da API gerada
write_log "Deactivating virtual environment for generated API..."
deactivate
write_log "Virtual environment for generated API deactivated."

# 16. Voltar para $SCRIPT_DIR
cd "$SCRIPT_DIR"
write_log "Changed directory to $(pwd)."

# 17. Desativar venv PythonREST
write_log "Deactivating shared PythonREST virtual environment (explicitly)..."
deactivate
PYTHONREST_VENV_ACTIVATED=false
write_log "Shared PythonREST virtual environment deactivated."

# 18. Parar e remover container
write_log "Stopping and removing SQL Server Docker container..."
docker compose down
write_log "SQL Server Docker container stopped and removed."

# 19. Fim
write_log "SQL Server integration test script completed successfully."
exit 0
