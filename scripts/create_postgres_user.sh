#!/bin/bash
set -e

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_REPO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$CURRENT_DIR/.." && pwd)")
SERVICE_NAME=$(basename "$PATH_TO_REPO")

# Configuration
SECRETS_DIR="${PATH_TO_REPO}/secrets"

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

usage() {
    echo "Usage: $0 <username> [password]"
    echo "Generates secret files and creates a new PostgreSQL user."
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

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

NEW_USER="$1"
# Generate a secure three-word passphrase if not provided
NEW_PASSWORD="${2:-$(generate_passphrase)-$(generate_passphrase)-$(generate_passphrase)}"

# Ensure secrets directory exists
mkdir -p "$SECRETS_DIR"

USER_FILE="${SECRETS_DIR}/${NEW_USER}_user.txt"
PASS_FILE="${SECRETS_DIR}/${NEW_USER}_password.txt"

log_info "Creating secret files for user: $NEW_USER"

echo "$NEW_USER" > "$USER_FILE"
echo "$NEW_PASSWORD" > "$PASS_FILE"

# Restrict permissions
chmod 600 "$USER_FILE" "$PASS_FILE"

# Load Environment Variables
if [ -f "${PATH_TO_REPO}/.env" ]; then
  source "${PATH_TO_REPO}/.env"
fi

NETWORK_NAMES=${EXTERNAL_NETWORK_NAMES:-my_external_network}
# Extract the first network from the comma-separated list
IFS=',' read -ra NET_LIST <<< "$NETWORK_NAMES"
NETWORK_NAME="${NET_LIST[0]}"

DB_HOST=${POSTGRES_HOST:-db}
PG_VERSION=${POSTGRES_IMAGE_VERSION:-15}

log_success "Secrets successfully stored securely at $SECRETS_DIR."
log_info "Username file: ${NEW_USER}_user.txt"
log_info "Password file: ${NEW_USER}_password.txt"

# If container is running, execute creation on the fly
log_info "Checking if POSTGRESQL container in '$SERVICE_NAME' is running..."
if cd "$PATH_TO_REPO" && docker compose ps --services --filter "status=running" | grep -q "^db$"; then
    log_info "PostgreSQL container is running. Executing user creation directly via temporary container..."

    # Normally read from maintenance secret or fallback
    MAINT_USER="postgres"
    if [ -f "${SECRETS_DIR}/maintenance_user.txt" ]; then
         MAINT_USER=$(cat "${SECRETS_DIR}/maintenance_user.txt")
    fi

    log_info "Running CREATE USER command..."
    # Using docker run instead of host psql to avoid requiring local postgres-client
    docker run -i --rm --network "${NETWORK_NAME}" "postgres:${PG_VERSION}" psql -h "${DB_HOST}" -U "$MAINT_USER" -c "CREATE USER ${NEW_USER} WITH CREATEDB LOGIN PASSWORD '${NEW_PASSWORD}';"
    docker run -i --rm --network "${NETWORK_NAME}" "postgres:${PG_VERSION}" psql -h "${DB_HOST}" -U "$MAINT_USER" -c "CREATE DATABASE ${NEW_USER} OWNER ${NEW_USER};"
    log_success "User ${NEW_USER} and database successfully created."
else
    log_warn "DB Container is not running."
    log_info "Wait until the container is running and then re-execute this script to create the user inside the DB."
fi
