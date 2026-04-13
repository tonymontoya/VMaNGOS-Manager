#!/usr/bin/env bash
#
# Common utilities for VMANGOS Manager
# Shared functions used across all modules
#

set -euo pipefail

# ============================================================================
# GLOBALS (No privileged operations at import time)
# ============================================================================

export CONFIG_FILE="${MANAGER_CONFIG:-/opt/mangos/manager/config/manager.conf}"
LOG_FILE="${MANAGER_LOG:-/var/log/vmangos-manager.log}"
LOCK_DIR="/var/run/vmangos-manager"
VERBOSE="${VERBOSE:-0}"

# Exit codes
export E_SUCCESS=0
E_ERROR=1
export E_INVALID_ARGS=2
E_NOT_ROOT=3
E_LOCK_FAILED=4
export E_CONFIG_ERROR=5
export E_SERVICE_ERROR=6

# ============================================================================
# INITIALIZATION (Called explicitly, not at import)
# ============================================================================

init_manager() {
    # Only create directories when explicitly initialized
    if [[ "${SKIP_ROOT_INIT:-0}" -eq 0 ]]; then
        mkdir -p "$LOCK_DIR" 2>/dev/null || true
        if [[ -d "$(dirname "$LOG_FILE")" ]]; then
            : # Log directory exists
        else
            mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        fi
    fi
}

# ============================================================================
# LOGGING
# ============================================================================

log_debug() {
    [[ "$VERBOSE" -eq 1 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

cleanup_stack=()

register_cleanup() {
    cleanup_stack+=("$1")
}

run_cleanup() {
    local i
    for ((i = ${#cleanup_stack[@]} - 1; i >= 0; i--)); do
        eval "${cleanup_stack[$i]}" 2>/dev/null || true
    done
}

error_exit() {
    local message="$1"
    local code="${2:-$E_ERROR}"
    log_error "$message"
    run_cleanup
    exit "$code"
}

cleanup_on_exit() {
    run_cleanup
}

trap cleanup_on_exit EXIT

# ============================================================================
# VALIDATION
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This command must be run as root" "$E_NOT_ROOT"
    fi
}

# ============================================================================
# LOCKING
# ============================================================================

acquire_lock() {
    local lock_name="${1:-global}"
    local lock_file="$LOCK_DIR/$lock_name.lock"
    local pid
    
    # Create lock directory if needed (lazy init)
    if [[ ! -d "$LOCK_DIR" ]]; then
        mkdir -p "$LOCK_DIR" 2>/dev/null || {
            error_exit "Cannot create lock directory: $LOCK_DIR" "$E_LOCK_FAILED"
        }
    fi
    
    if [[ -f "$lock_file" ]]; then
        pid=$(cat "$lock_file" 2>/dev/null) || true
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error_exit "Another instance is running (PID: $pid)" "$E_LOCK_FAILED"
        fi
        rm -f "$lock_file"
    fi
    
    echo $$ > "$lock_file"
    register_cleanup "rm -f $lock_file"
    log_debug "Acquired lock: $lock_name"
}

release_lock() {
    local lock_name="${1:-global}"
    local lock_file="$LOCK_DIR/$lock_name.lock"
    rm -f "$lock_file"
    log_debug "Released lock: $lock_name"
}

# ============================================================================
# TEMP FILES
# ============================================================================

mktemp_secure() {
    local template="${1:-vmangos-XXXXXX}"
    local temp_file
    temp_file=$(mktemp -t "$template")
    chmod 600 "$temp_file"
    register_cleanup "rm -f $temp_file"
    echo "$temp_file"
}

get_file_permissions() {
    local file_path="$1"
    stat -c "%a" "$file_path" 2>/dev/null || stat -f "%OLp" "$file_path"
}

get_file_size_bytes() {
    local file_path="$1"
    stat -c "%s" "$file_path" 2>/dev/null || stat -f "%z" "$file_path"
}

sha256_file() {
    local file_path="$1"
    sha256sum "$file_path" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$file_path" | cut -d' ' -f1
}

# ============================================================================
# JSON UTILITIES
# ============================================================================

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\t'/\\t}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
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

# ============================================================================
# SERVICE UTILITIES
# ============================================================================

service_active() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

service_start() {
    local service="$1"
    log_info "Starting $service..."
    if systemctl start "$service"; then
        log_info "$service started"
        return 0
    else
        log_error "Failed to start $service"
        return 1
    fi
}

service_stop() {
    local service="$1"
    log_info "Stopping $service..."
    if systemctl stop "$service"; then
        log_info "$service stopped"
        return 0
    else
        log_error "Failed to stop $service"
        return 1
    fi
}
