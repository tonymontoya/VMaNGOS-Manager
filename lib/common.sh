#!/bin/bash
# =============================================================================
# VMANGOS Manager - Common Library
# =============================================================================
# Provides: logging, locks, JSON helpers, error handling, password file reading
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants & Configuration
# =============================================================================

# shellcheck disable=SC2034
readonly VMANGOS_VERSION="0.1.0"
# shellcheck disable=SC2034
readonly VMANGOS_MANAGER_DIR="/opt/mangos/manager"
# shellcheck disable=SC2034
readonly VMANGOS_INSTALL_DIR="/opt/mangos"
readonly VMANGOS_LOG_DIR="/var/log/vmangos-manager"
readonly VMANGOS_LOCK_DIR="/var/run/vmangos-manager"

# =============================================================================
# Logging Functions
# =============================================================================

# Log levels
readonly LOG_LEVEL_ERROR=0
readonly LOG_LEVEL_WARN=1
readonly LOG_LEVEL_INFO=2
readonly LOG_LEVEL_DEBUG=3

# Default log level
VMANGOS_LOG_LEVEL=${VMANGOS_LOG_LEVEL:-$LOG_LEVEL_INFO}

log_init() {
    mkdir -p "$VMANGOS_LOG_DIR" 2>/dev/null || true
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message"
    
    # Also log to file if directory is writable
    if [[ -w "$VMANGOS_LOG_DIR" ]]; then
        echo "[$timestamp] [$level] $message" >> "$VMANGOS_LOG_DIR/manager.log"
    fi
}

log_error() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_ERROR ]]; then
        log_message "ERROR" "$1" >&2
    fi
}

log_warn() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_WARN ]]; then
        log_message "WARN" "$1"
    fi
}

log_info() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_INFO ]]; then
        log_message "INFO" "$1"
    fi
}

log_debug() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_DEBUG ]]; then
        log_message "DEBUG" "$1"
    fi
}

# =============================================================================
# Error Handling
# =============================================================================

error_exit() {
    local message="$1"
    local code="${2:-1}"
    
    log_error "$message"
    
    # Output JSON error if requested
    if [[ "${VMANGOS_JSON_OUTPUT:-false}" == "true" ]]; then
        json_output false "null" "ERROR" "$message" "Check logs or run with --verbose for details"
    fi
    
    exit "$code"
}

# =============================================================================
# Lock Mechanism
# =============================================================================

lock_acquire() {
    local lock_name="${1:-default}"
    local lock_file="$VMANGOS_LOCK_DIR/${lock_name}.lock"
    local max_wait="${2:-30}"  # Max seconds to wait
    local wait_count=0
    
    mkdir -p "$VMANGOS_LOCK_DIR" 2>/dev/null || {
        # Fallback to /tmp if can't create lock dir
        lock_file="/tmp/vmangos-manager-${lock_name}.lock"
    }
    
    # Try to acquire lock
    while ! mkdir "$lock_file" 2>/dev/null; do
        if [[ $wait_count -ge $max_wait ]]; then
            error_exit "Could not acquire lock: $lock_name (waited ${max_wait}s)"
        fi
        
        # Check if lock is stale (older than 1 hour)
        if [[ -d "$lock_file" ]]; then
            local lock_time
            lock_time=$(stat -c %Y "$lock_file" 2>/dev/null || echo "0")
            local current_time
            current_time=$(date +%s)
            if [[ $((current_time - lock_time)) -gt 3600 ]]; then
                log_warn "Removing stale lock: $lock_name"
                rm -rf "$lock_file"
                continue
            fi
        fi
        
        sleep 1
        ((wait_count++))
    done
    
    # Store lock info
    echo "$$" > "$lock_file/pid"
    echo "$lock_file"
}

lock_release() {
    local lock_file="$1"
    
    if [[ -d "$lock_file" ]]; then
        rm -rf "$lock_file"
        log_debug "Released lock: $lock_file"
    fi
}

# =============================================================================
# JSON Helpers
# =============================================================================

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"      # \ -> \\
    str="${str//\"/\\\"}"      # " -> \\"
    str="${str//$'\t'/\\t}"   # tab -> \t
    str="${str//$'\n'/\\n}"   # newline -> \n
    str="${str//$'\r'/\\r}"   # carriage return -> \r
    printf '%s' "$str"
}

json_output() {
    local success="$1"
    local data="${2:-null}"
    local error_code="${3:-null}"
    local error_message="${4:-null}"
    local error_suggestion="${5:-null}"
    
    local timestamp
    timestamp=$(date -Iseconds)
    
    if [[ "$success" == "true" ]]; then
        printf '{"success":true,"timestamp":"%s","data":%s,"error":null}\n' \
            "$timestamp" "$data"
    else
        local escaped_message
        escaped_message=$(json_escape "$error_message")
        local escaped_suggestion
        escaped_suggestion=$(json_escape "$error_suggestion")
        
        printf '{"success":false,"timestamp":"%s","data":null,"error":{"code":"%s","message":"%s","suggestion":"%s"}}\n' \
            "$timestamp" "$error_code" "$escaped_message" "$escaped_suggestion"
    fi
}

# =============================================================================
# Password File Security
# =============================================================================

get_password_from_file() {
    local file="$1"
    
    # SECURITY: Check BEFORE reading
    
    # Check file exists
    if [[ ! -f "$file" ]]; then
        error_exit "Password file not found: $file"
        return 1
    fi
    
    # Check ownership (must be root or current user)
    local file_owner
    file_owner=$(stat -c %u "$file")
    local current_uid
    current_uid=$(id -u)
    if [[ "$file_owner" != "$current_uid" && "$file_owner" != "0" ]]; then
        error_exit "Password file must be owned by root or current user"
        return 1
    fi
    
    # Check permissions (must be 600)
    local file_mode
    file_mode=$(stat -c %a "$file")
    if [[ "$file_mode" != "600" ]]; then
        error_exit "Password file must have mode 600 (has $file_mode)"
        return 1
    fi
    
    # NOW safe to read
    local password
    password=$(cat "$file")
    
    # Remove trailing newline
    password="${password%$'\n'}"
    
    # Basic validation
    if [[ ${#password} -lt 6 ]]; then
        error_exit "Password in file must be at least 6 characters"
        return 1
    fi
    
    printf '%s' "$password"
}

# =============================================================================
# Utility Functions
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This command must be run as root (use sudo)"
    fi
}

validate_username() {
    local username="$1"
    if [[ ! "$username" =~ ^[a-zA-Z0-9]{2,32}$ ]]; then
        error_exit "Invalid username: must be 2-32 alphanumeric characters"
    fi
    printf '%s' "$username"
}

validate_gm_level() {
    local level="$1"
    if [[ ! "$level" =~ ^[0-3]$ ]]; then
        error_exit "Invalid GM level: must be 0-3"
    fi
    printf '%s' "$level"
}

# Initialize logging on source
log_init
