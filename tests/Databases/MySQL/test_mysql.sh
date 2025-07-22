#!/usr/bin/env bash

# Exit on first error
set -e

# Função para logar mensagens com timestamp
write_log() {
    echo "[ $(date '+%Y-%m-%d %H:%M:%S') ] $1"
}

# Diretórios
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( realpath "$SCRIPT_DIR/../../.." )"

write_log "Script directory: $SCRIPT_DIR"
write_log "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"
write_log "Changed directory to project root: $(pwd)"

# Trap para cleanup do venv PythonREST
cleanup() {
    if [[ "$PYTHONREST_VENV_ACTIVATED" == "true" ]]; then
        write_log "Deactivating PythonREST virtual environment due to script exit..."
        deactivate || true
        write_log "PythonREST virtual environment deactivated."
        PYTHONREST_VENV_ACTIVATED="false"
    fi
    docker compose down || true
}
trap cleanup EXIT

# 1. Início
write_log "Starting MySQL integration test script."

# 2. Subir container MySQL
write_log "Starting MySQL Docker container..."
cd "$SCRIPT_DIR"
write_log "Changed directory to script location for Docker operations: $(pwd)"
docker compose down --remove-orphans
docker compose up -d

write_log "MySQL Docker container started."

# 3. Esperar container ficar healthy
MYSQL_CONTAINER_NAME="mysql-mysql-1"
write_log "Waiting for MySQL container ($MYSQL_CONTAINER_NAME) to be healthy..."

test_mysql_ready() {
    docker exec "$MYSQL_CONTAINER_NAME" mysqladmin ping -h localhost -u admin -padminuserdb --silent 2>/dev/null | grep -q "mysqld is alive"
}

TIMEOUT_SECONDS=120
SECONDS_WAITED=0
MAX_RETRIES=3
retry_count=0

while true; do
    if test_mysql_ready; then
        write_log "MySQL container is ready and accepting connections."
        break
    fi

    if [[ $SECONDS_WAITED -ge $TIMEOUT_SECONDS ]]; then
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            retry_count=$((retry_count + 1))
            write_log "Timeout reached. Restarting container (Attempt $retry_count of $MAX_RETRIES)..."
            docker compose restart
            SECONDS_WAITED=0
            continue
        else
            write_log "ERROR: MySQL container failed to become ready after $MAX_RETRIES attempts."
            docker compose logs
            docker inspect "$MYSQL_CONTAINER_NAME"
            exit 1
        fi
    fi

    write_log "Waiting for MySQL to be ready... ($SECONDS_WAITED/$TIMEOUT_SECONDS seconds)"
    sleep 5
    SECONDS_WAITED=$((SECONDS_WAITED + 5))
done

# 4. Ativar venv PythonREST
VENV_ACTIVATE="$PROJECT_ROOT/venv/bin/activate"
write_log "Activating shared PythonREST virtual environment: $VENV_ACTIVATE"
if [[ ! -f "$VENV_ACTIVATE" ]]; then
    write_log "ERROR: PythonREST venv activate script not found at $VENV_ACTIVATE"
    exit 1
fi
# shellcheck source=/dev/null
source "$VENV_ACTIVATE"
PYTHONREST_VENV_ACTIVATED="true"
write_log "Shared PythonREST virtual environment activated."

# 5. Rodar geração PythonREST
write_log "Running PythonREST generation..."
cd "$PROJECT_ROOT"
python "$PROJECT_ROOT/pythonrest.py" generate --mysql-connection-string "mysql://admin:adminuserdb@localhost:3306/database_mapper_mysql"

write_log "PythonREST generation completed successfully."

# 6. Checar pasta PythonRestAPI
GENERATED_API_PATH="$PROJECT_ROOT/PythonRestAPI"
write_log "Checking for generated API at: $GENERATED_API_PATH"
if [[ ! -d "$GENERATED_API_PATH" ]]; then
    write_log "ERROR: 'PythonRestAPI' folder not found at $GENERATED_API_PATH after PythonREST generation."
    exit 1
fi
write_log "'PythonRestAPI' folder found."

# 7. Ir para PythonRestAPI
cd "$GENERATED_API_PATH"
write_log "Changed directory to $(pwd)."

# 8. Criar venv para API gerada
write_log "Creating Python virtual environment for generated API..."
python -m venv venv

write_log "Python virtual environment for generated API created."

# 9. Ativar venv da API gerada
# shellcheck source=/dev/null
source "./venv/bin/activate"
write_log "Virtual environment for generated API activated."

# 10. Instalar dependências
PIP_LOG="/tmp/pip_install_mysql_api.log"
write_log "Installing dependencies from requirements.txt for generated API..."
pip install -r requirements.txt | tee "$PIP_LOG"

write_log "Dependencies installed. Output logged to $PIP_LOG"

# 11. Iniciar Flask API em background
API_LOG="/tmp/api_output_mysql.log"
API_LOG_ERROR="/tmp/api_error_output_mysql.log"
write_log "Starting Flask API in the background..."
python app.py > "$API_LOG" 2> "$API_LOG_ERROR" &
API_PID=$!
write_log "Flask API started with PID $API_PID."

# 12. Esperar API subir
write_log "Waiting for API to start (5 seconds)..."
sleep 5

if curl -s -o /tmp/curl_check_mysql.log -w "%{http_code}" http://localhost:5000 | grep -E "200|400|404" >/dev/null; then
    write_log "API started and responding."
else
    write_log "ERROR: API failed to start or is not responding."
    cat "$API_LOG"
    cat "$API_LOG_ERROR"
    kill $API_PID || true
    deactivate
    exit 1
fi
rm -f /tmp/curl_check_mysql.log

# 13. Teste GET
write_log "Performing sample GET request to http://localhost:5000/swagger..."
curl -s -o /tmp/curl_test_mysql.log http://localhost:5000/swagger || true
write_log "Sample GET request output:"
cat /tmp/curl_test_mysql.log

# 14. Matar API
write_log "Killing Flask API (PID $API_PID)..."
kill $API_PID || true
write_log "Flask API process killed."

# 15. Desativar venv da API gerada
write_log "Deactivating virtual environment for generated API..."
deactivate
write_log "Virtual environment for generated API deactivated."

# 16. Voltar para $SCRIPT_DIR
cd "$SCRIPT_DIR"
write_log "Changed directory to $(pwd)."

# 17. Desativar venv PythonREST (feito no trap)

# 18. Parar e remover container
write_log "Stopping and removing MySQL Docker container..."
docker compose down
write_log "MySQL Docker container stopped and removed."

# 19. Fim
write_log "MySQL integration test script completed successfully."
exit 0
