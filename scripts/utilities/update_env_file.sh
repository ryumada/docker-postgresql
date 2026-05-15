#!/usr/bin/env bash
# Category: Utility
# Description: Script to update the .env file from .env.example while preserving existing values.
# Usage: ./scripts/utilities/update_env_file.sh [template_env_file]
# Dependencies: git, cp, awk

set -euo pipefail

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")

# Determine Repository Root (Harmonized with setup.sh pattern)
if [ "$(whoami)" = "$CURRENT_DIR_USER" ]; then
    PATH_TO_ROOT=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$CURRENT_DIR/../.." && pwd)")
else
    PATH_TO_ROOT=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$CURRENT_DIR/../.." && pwd)")
fi

SERVICE_NAME=$(basename "$PATH_TO_ROOT")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ROOT")

# Configuration
MAX_BACKUPS=3

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

# Function to rotate backups: Keep only the MAX_BACKUPS most recent ones
rotate_backups() {
    local prefix=".env.backup_"
    local count
    count=$(ls -1 "${prefix}"* 2>/dev/null | wc -l)
    
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        log_info "Rotating backups (limit $MAX_BACKUPS)..."
        # List backups by time (newest first), skip the first MAX_BACKUPS, and delete the rest
        ls -1t "${prefix}"* | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm --
    fi
}

main() {
    local template_file=${1:-.env.example}
    
    echo "-------------------------------------------------------------------------------"
    echo " UPDATE ENV FILE FOR $SERVICE_NAME @ $(date +"%A, %d %B %Y %H:%M %Z")"
    echo "-------------------------------------------------------------------------------"

    if ! cd "$PATH_TO_ROOT"; then
        log_error "Failed to change directory to $PATH_TO_ROOT"
        exit 1
    fi

    # 1. Create Backup of current .env
    if [ -f ".env" ]; then
        local timestamp
        timestamp=$(date +"%Y%m%d%H%M%S")
        local backup_name=".env.backup_${timestamp}"
        
        log_info "Existing .env found. Creating backup: ${backup_name}"
        cp .env "$backup_name"
        chown "$REPOSITORY_OWNER": "$backup_name"
        
        rotate_backups
    else
        log_warn ".env file not found. Initializing from template."
    fi

    # 2. Identify the source for current values
    # We use the most recent backup file if it exists
    local latest_backup
    latest_backup=$(ls -1t .env.backup_* 2>/dev/null | head -n 1 || echo "")

    if [ ! -f "$template_file" ]; then
        log_error "Template file not found: $template_file"
        exit 1
    fi

    # 3. Perform the Sync
    # Strategy: Use the template for structure (comments, new keys) and 
    # overlay values from the backup/existing .env.
    log_info "Syncing .env from $template_file..."
    cp "$template_file" .env.new

    if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
        log_info "Importing values from ${latest_backup}..."
        
        while IFS= read -r line || [ -n "$line" ]; do
            # Detect variable assignments (KEY=VALUE)
            # Regex ensures it starts with a valid variable name
            if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                
                # If the key exists in the template, update it with the value from backup
                if grep -q "^${key}=" .env.new; then
                    # Use awk to safely replace the value without delimiter escaping issues
                    # This replaces everything after the first '=' for that key
                    awk -v k="$key" -v v="$value" 'BEGIN{FS="="; OFS="="} $1 == k { $0 = k OFS v; print; next } 1' .env.new > .env.tmp && mv .env.tmp .env.new
                fi
            fi
        done < "$latest_backup"
    fi

    # 4. Finalize
    mv .env.new .env
    chown "$REPOSITORY_OWNER": .env
    log_success "Update finished successfully."
}

main "$@"

