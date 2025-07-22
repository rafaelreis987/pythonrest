#!/usr/bin/env bash

# Exit on any error
set -e

# Função para logar mensagens com timestamp
write_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Função de cleanup para o venv PythonREST
cleanup_pythonrest_venv() {
    if [[ "$PYTHONREST_VENV_ACTIVATED" == "true" ]]; then
        write_log "Desativando o ambiente virtual PythonREST devido à saída do script..."
        deactivate
        write_log "Ambiente virtual PythonREST desativado."
        PYTHONREST_VENV_ACTIVATED=false
    fi
}

# Registrar cleanup no EXIT
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
write_log "Starting PostgreSQL integration test script."

# 2. Subir container PostgreSQL
write_log "Starting PostgreSQL Docker container..."
cd "$SCRIPT_DIR"
write_log "Changed directory to script location for Docker operations: $(pwd)"

docker compose down --remove-orphans
docker compose up -d

write_log "PostgreSQL Docker container started."

# 3. Esperar container ficar healthy
POSTGRES_CONTAINER_NAME="postgresql-postgres-1"
write_log "Waiting for PostgreSQL container ($POSTGRES_CONTAINER_NAME) to be healthy..."
# Opcional: pode usar `docker inspect` ou `sleep` simples
sleep 5

# 4. Ativar venv PythonREST
VENV_ACTIVATE="$PROJECT_ROOT/venv/bin/activate"
write_log "Activating shared PythonREST virtual environment: $VENV_ACTIVATE"
if [[ ! -f "$VENV_ACTIVATE" ]]; then
    write_log "ERROR: PythonREST venv activate script not found at $VENV_ACTIVATE"
    docker compose down
    exit 1
fi

# shellcheck source=/dev/null
source "$VENV_ACTIVATE"
PYTHONREST_VENV_ACTIVATED=true
write_log "Shared PythonREST virtual environment activated."

# 5. Rodar geração PythonREST
write_log "Running PythonREST generation using $PROJECT_ROOT/pythonrest.py..."
cd "$PROJECT_ROOT"
write_log "Changed directory to project root for PythonREST generation: $(pwd)"

python "$PROJECT_ROOT/pythonrest.py" generate --postgres-connection-string "postgresql://admin:adminuserdb@localhost:5432/database_mapper_postgresql?options=-c%20search_path=database_mapper_postgresql,public"

write_log "PythonREST generation completed successfully."

# 6. Checar pasta PythonRestAPI
GENERATED_API_PATH="$PROJECT_ROOT/PythonRestAPI"
write_log "Checking for generated API at: $GENERATED_API_PATH"

if [[ ! -d "$GENERATED_API_PATH" ]]; then
    write_log "ERROR: 'PythonRestAPI' folder not found at $GENERATED_API_PATH after PythonREST generation."
    docker compose down
    exit 1
fi

write_log "PythonREST generation successful. 'PythonRestAPI' folder found at $GENERATED_API_PATH."

# 7. Ir para PythonRestAPI
cd "$GENERATED_API_PATH"
write_log "Changed directory to $(pwd)."

# 8. Criar venv para API gerada
write_log "Creating Python virtual environment for generated API..."
python -m venv venv

write_log "Python virtual environment for generated API created."

# 9. Ativar venv da API gerada
GENERATED_VENV_ACTIVATE="$(pwd)/venv/bin/activate"
write_log "Activating virtual environment for generated API..."
# shellcheck source=/dev/null
source "$GENERATED_VENV_ACTIVATE"
write_log "Virtual environment for generated API activated."

# 10. Instalar dependências
PIP_LOG="$(mktemp)"
write_log "Installing dependencies from requirements.txt for generated API..."
python -m pip install -r requirements.txt &> "$PIP_LOG"

write_log "Dependencies for generated API installed successfully. Output logged to $PIP_LOG"

# 11. Iniciar Flask API em background
write_log "Starting Flask API in the background..."
API_LOG="$(mktemp)"
API_LOG_ERROR="$(mktemp)"
write_log "API output will be logged to: $API_LOG"
write_log "API errors will be logged to: $API_LOG_ERROR"

python app.py >"$API_LOG" 2>"$API_LOG_ERROR" &
API_PID=$!
write_log "Flask API started with PID $API_PID."

# 12. Esperar API subir
write_log "Waiting for API to start (5 seconds)..."
sleep 5

if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000 | grep -Eq "^(200|404|400)$"; then
    write_log "API started and responding as expected."
else
    write_log "ERROR: API failed to start or is not responding."
    cat "$API_LOG"
    cat "$API_LOG_ERROR"
    kill "$API_PID"
    deactivate
    docker compose down
    exit 1
fi

# 13. Teste GET
write_log "Performing sample GET request to http://localhost:5000/swagger..."
if ! curl -s http://localhost:5000/swagger -o /dev/null; then
    write_log "WARNING: Sample GET request failed. This might indicate an issue or no default route."
else
    write_log "Sample GET request successful."
fi

# 14. Matar API
write_log "Killing Flask API (PID $API_PID)..."
kill "$API_PID"
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
write_log "Stopping and removing PostgreSQL Docker container..."
docker compose down
write_log "PostgreSQL Docker container stopped and removed."

# 19. Fim
write_log "PostgreSQL integration test script completed successfully."
exit 0
