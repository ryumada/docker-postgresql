#!/bin/bash
set -e

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_REPO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || echo "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_REPO")

# Configuration
ENV_FILE="${PATH_TO_REPO}/.env"
SECRETS_DIR="${PATH_TO_REPO}/secrets"
CONFIG_DIR="${PATH_TO_REPO}/config"
MAINTENANCE_USER_FILE="${SECRETS_DIR}/maintenance_user.txt"
MAINTENANCE_PASSWORD_FILE="${SECRETS_DIR}/maintenance_password.txt"
PG_CONF_FILE="${CONFIG_DIR}/postgresql.conf"

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }
# ------------------------------------

# Passphrase Generation Function
generate_passphrase() {
    local consonants="bcdfghjklmnpqrstvwxyz"
    local vowels="aeiou"
    local word=""
    for i in {1..4}; do
        word+="${consonants:RANDOM%21:1}"
        word+="${vowels:RANDOM%5:1}"
    done
    echo "$word"
}

log_info "Starting PostgreSQL Initial Setup for $SERVICE_NAME..."

mkdir -p "$SECRETS_DIR"
mkdir -p "$CONFIG_DIR"

# 1. Load or initialize environment variables
if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
    log_info "Created empty $ENV_FILE"
fi

source "$ENV_FILE"

# Prompt for missing crucial variables
if [ -z "$MAINTENANCE_USER" ]; then
    MAINTENANCE_USER="postgres"
    echo "MAINTENANCE_USER=$MAINTENANCE_USER" >> "$ENV_FILE"
fi

# Postgres Tuning Defaults (Production Grade for typical 4GB-8GB modern VM)
POSTGRES_MAX_CONNECTIONS=${POSTGRES_MAX_CONNECTIONS:-100}
POSTGRES_SHARED_BUFFERS=${POSTGRES_SHARED_BUFFERS:-1GB}
POSTGRES_EFFECTIVE_CACHE_SIZE=${POSTGRES_EFFECTIVE_CACHE_SIZE:-3GB}
POSTGRES_MAINTENANCE_WORK_MEM=${POSTGRES_MAINTENANCE_WORK_MEM:-256MB}
POSTGRES_CHECKPOINT_COMPLETION_TARGET=${POSTGRES_CHECKPOINT_COMPLETION_TARGET:-0.9}
POSTGRES_WAL_BUFFERS=${POSTGRES_WAL_BUFFERS:-16MB}
POSTGRES_DEFAULT_STATISTICS_TARGET=${POSTGRES_DEFAULT_STATISTICS_TARGET:-100}
POSTGRES_RANDOM_PAGE_COST=${POSTGRES_RANDOM_PAGE_COST:-1.1}
POSTGRES_EFFECTIVE_IO_CONCURRENCY=${POSTGRES_EFFECTIVE_IO_CONCURRENCY:-200}
POSTGRES_WORK_MEM=${POSTGRES_WORK_MEM:-16MB}
POSTGRES_MIN_WAL_SIZE=${POSTGRES_MIN_WAL_SIZE:-1GB}
POSTGRES_MAX_WAL_SIZE=${POSTGRES_MAX_WAL_SIZE:-4GB}
POSTGRES_MAX_WORKER_PROCESSES=${POSTGRES_MAX_WORKER_PROCESSES:-4}
POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER=${POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER:-2}

# Reload to ensure we have everything
source "$ENV_FILE"

# 2. Write Production Configuration
log_info "Generating optimized postgresql.conf at $PG_CONF_FILE..."
cat <<EOF > "$PG_CONF_FILE"
# -----------------------------
# Auto-generated Production PostgreSQL configuration
# -----------------------------
listen_addresses = '*'
max_connections = $POSTGRES_MAX_CONNECTIONS
shared_buffers = $POSTGRES_SHARED_BUFFERS
effective_cache_size = $POSTGRES_EFFECTIVE_CACHE_SIZE
maintenance_work_mem = $POSTGRES_MAINTENANCE_WORK_MEM
checkpoint_completion_target = $POSTGRES_CHECKPOINT_COMPLETION_TARGET
wal_buffers = $POSTGRES_WAL_BUFFERS
default_statistics_target = $POSTGRES_DEFAULT_STATISTICS_TARGET
random_page_cost = $POSTGRES_RANDOM_PAGE_COST
effective_io_concurrency = $POSTGRES_EFFECTIVE_IO_CONCURRENCY
work_mem = $POSTGRES_WORK_MEM
min_wal_size = $POSTGRES_MIN_WAL_SIZE
max_wal_size = $POSTGRES_MAX_WAL_SIZE
max_worker_processes = $POSTGRES_MAX_WORKER_PROCESSES
max_parallel_workers_per_gather = $POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER
max_parallel_workers = $POSTGRES_MAX_WORKER_PROCESSES
max_parallel_maintenance_workers = $POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER

# Standard Formatting and Safety defaults
log_timezone = 'UTC'
datestyle = 'iso, mdy'
timezone = 'UTC'
dynamic_shared_memory_type = posix
EOF
log_success "PostgreSQL configuration successfully generated."

# 3. Handle Secrets
log_info "Managing database secrets..."
if [ -n "$MAINTENANCE_USER" ]; then
    echo "$MAINTENANCE_USER" > "$MAINTENANCE_USER_FILE"
else
    log_error "MAINTENANCE_USER not found. Please verify .env file."
    exit 1
fi

if [ ! -f "$MAINTENANCE_PASSWORD_FILE" ] || [ ! -s "$MAINTENANCE_PASSWORD_FILE" ]; then
    NEW_PASSWORD="$(generate_passphrase)-$(generate_passphrase)-$(generate_passphrase)"
    echo "$NEW_PASSWORD" > "$MAINTENANCE_PASSWORD_FILE"
    log_success "Generated new secure passphrase for maintenance user."
else
    log_info "Maintenance password already exists. Skipping generation."
fi
chmod 600 "$MAINTENANCE_USER_FILE" "$MAINTENANCE_PASSWORD_FILE"

# 5. Handle External Docker Networks
log_info "Verifying external Docker networks..."
# Fallback to older singular variable if it exists instead of new array
if [ -z "$EXTERNAL_NETWORK_NAMES" ] && [ -n "$EXTERNAL_NETWORK_NAME" ]; then
    EXTERNAL_NETWORK_NAMES="$EXTERNAL_NETWORK_NAME"
fi

if [ -n "$EXTERNAL_NETWORK_NAMES" ]; then
    # Split the comma-separated string into an array
    IFS=',' read -ra NETWORKS <<< "$EXTERNAL_NETWORK_NAMES"
    
    # Generate the dynamic network block for docker-compose.yml
    DOCKER_NOVERLAY_FILE="${PATH_TO_REPO}/docker-compose.override.yml"
    
    cat <<EOF > "$DOCKER_NOVERLAY_FILE"
services:
  db:
    networks:
EOF

    for net in "${NETWORKS[@]}"; do
        # Create network if it doesn't exist
        if ! docker network ls | awk '{print $2}' | grep -qw "^${net}$"; then
            log_warn "Network '${net}' does not exist. Creating it now..."
            docker network create "${net}"
            log_success "External network '${net}' successfully created."
        else
            log_info "Network '${net}' already exists."
        fi
        
        # Add to docker-compose.override.yml services
        echo "      - ${net}" >> "$DOCKER_NOVERLAY_FILE"
    done
    
    # Finish the docker-compose.override.yml network block
    echo "  adminer:" >> "$DOCKER_NOVERLAY_FILE"
    echo "    networks:" >> "$DOCKER_NOVERLAY_FILE"
    for net in "${NETWORKS[@]}"; do
        echo "      - ${net}" >> "$DOCKER_NOVERLAY_FILE"
    done
    
    echo "networks:" >> "$DOCKER_NOVERLAY_FILE"
    for net in "${NETWORKS[@]}"; do
        echo "  ${net}:" >> "$DOCKER_NOVERLAY_FILE"
        echo "    external: true" >> "$DOCKER_NOVERLAY_FILE"
    done
    
    log_info "Generated network bindings in $DOCKER_NOVERLAY_FILE"
else
    log_warn "EXTERNAL_NETWORK_NAMES is not defined in .env. Network check skipped."
fi

log_success "Setup complete! Secrets and configs are ready."
log_info "You may now run: docker compose up -d"
