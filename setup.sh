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
PG_CONF_TEMPLATE="${CONFIG_DIR}/postgresql.conf.template"
UPDATE_ENV_SCRIPT="${PATH_TO_REPO}/scripts/utilities/update_env_file.sh"

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
if [ -f "$UPDATE_ENV_SCRIPT" ]; then
    bash "$UPDATE_ENV_SCRIPT"
else
    log_warn "Environment update script not found at $UPDATE_ENV_SCRIPT. Skipping sync."
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE"
        log_info "Created empty $ENV_FILE"
    fi
fi

# 2. Load and export all variables from .env for envsubst and subsequent steps
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    log_error ".env file missing after initialization. Aborting."
    exit 1
fi


# 3. Write Production Configuration
log_info "Generating postgresql.conf via envsubst..."
if [ -f "$PG_CONF_TEMPLATE" ]; then
    # Dynamically identify all POSTGRES_ variables to substitute
    # This ensures only our intended variables are replaced, preserving other $ strings in the config
    VARS_TO_SUBSTITUTE=$(env | grep '^POSTGRES_' | cut -d= -f1 | sed 's/^/$/' | tr '\n' ',' | sed 's/,$//')
    
    envsubst "$VARS_TO_SUBSTITUTE" < "$PG_CONF_TEMPLATE" > "$PG_CONF_FILE"
    log_success "PostgreSQL configuration successfully generated from template."
else
    log_error "Configuration template not found at $PG_CONF_TEMPLATE"
    exit 1
fi

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
