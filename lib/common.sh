#!/bin/bash
# =============================================================================
# VMANGOS Manager - Common Library
# =============================================================================
# Provides: logging, locks, JSON helpers, error handling, password file reading
# 
# Error Handling Convention:
#   - Functions return 0 on success, non-zero on failure
#   - Functions should NOT call error_exit (let caller decide)
#   - Log errors but don't exit from library functions
# =============================================================================

set -uo pipefail

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

# Initialize logging directories
# Returns: 0 on success, 1 on failure
log_init() {
    if ! mkdir -p "$VMANGOS_LOG_DIR" 2>/dev/null; then
        # Don't fail - logging is optional
        return 1
    fi
    return 0
}

# Internal: Write log message
# Args: $1=level, $2=message
_log_write() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message"
    
    # Also log to file if directory is writable
    if [[ -w "$VMANGOS_LOG_DIR" ]]; then
        echo "[$timestamp] [$level] $message" >> "$VMANGOS_LOG_DIR/manager.log" 2>/dev/null || true
    fi
}

# Log error message (to stderr)
# Args: $1=message
log_error() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_ERROR ]]; then
        _log_write "ERROR" "$1" >&2
    fi
}

# Log warning message
# Args: $1=message
log_warn() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_WARN ]]; then
        _log_write "WARN" "$1"
    fi
}

# Log info message
# Args: $1=message
log_info() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_INFO ]]; then
        _log_write "INFO" "$1"
    fi
}

# Log debug message
# Args: $1=message
log_debug() {
    if [[ $VMANGOS_LOG_LEVEL -ge $LOG_LEVEL_DEBUG ]]; then
        _log_write "DEBUG" "$1"
    fi
}

# =============================================================================
# Error Handling
# =============================================================================

# Exit with error message and optional JSON output
# Args: $1=message, $2=exit_code (default: 1)
# Note: This is for use by main script, NOT library functions
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

# Acquire a lock file
# Args: $1=lock_name, $2=max_wait_seconds (default: 30)
# Returns: 0 on success, 1 on failure
# Outputs: lock_file_path on success
lock_acquire() {
    local lock_name="${1:-default}"
    local lock_file="$VMANGOS_LOCK_DIR/${lock_name}.lock"
    local max_wait="${2:-30}"
    local wait_count=0
    local my_pid=$$
    
    # Create lock directory or use fallback
    if ! mkdir -p "$VMANGOS_LOCK_DIR" 2>/dev/null; then
        lock_file="/tmp/vmangos-manager-${lock_name}.lock"
    fi
    
    # Try to acquire lock
    while true; do
        # Attempt to create lock directory (atomic operation)
        if mkdir "$lock_file" 2>/dev/null; then
            # Got the lock - write our PID
            echo "$my_pid" > "$lock_file/pid"
            echo "$lock_file"
            return 0
        fi
        
        # Check if we've waited too long
        if [[ $wait_count -ge $max_wait ]]; then
            log_error "Could not acquire lock: $lock_name (waited ${max_wait}s)"
            return 1
        fi
        
        # Check if lock is stale (verify PID)
        if [[ -d "$lock_file" ]]; then
            local lock_pid
            lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "")
            
            if [[ -n "$lock_pid" ]]; then
                # Check if process still exists
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    # Process is dead - check lock age
                    local lock_time
                    lock_time=$(stat -c %Y "$lock_file" 2>/dev/null || echo "0")
                    local current_time
                    current_time=$(date +%s)
                    
                    if [[ $((current_time - lock_time)) -gt 60 ]]; then
                        log_warn "Removing stale lock: $lock_name (PID $lock_pid not running)"
                        rm -rf "$lock_file"
                        continue
                    fi
                fi
            else
                # No PID file - might be old format, check age
                local lock_time
                lock_time=$(stat -c %Y "$lock_file" 2>/dev/null || echo "0")
                local current_time
                current_time=$(date +%s)
                
                if [[ $((current_time - lock_time)) -gt 3600 ]]; then
                    log_warn "Removing stale lock: $lock_name (no PID, old)"
                    rm -rf "$lock_file"
                    continue
                fi
            fi
        fi
        
        sleep 1
        ((wait_count++))
    done
}

# Release a lock file
# Args: $1=lock_file_path
# Returns: 0 on success
lock_release() {
    local lock_file="$1"
    
    if [[ -d "$lock_file" ]]; then
        rm -rf "$lock_file"
        log_debug "Released lock: $lock_file"
    fi
    return 0
}

# =============================================================================
# JSON Helpers
# =============================================================================

# Escape a string for JSON output
# Args: $1=string
# Outputs: escaped string
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"      # \ -> \\
    str="${str//\"/\\\"}"      # " -> \\"
    str="${str//$'\t'/\\t}"   # tab -> \t
    str="${str//$'\n'/\\n}"   # newline -> \n
    str="${str//$'\r'/\\r}"   # carriage return -> \r
    printf '%s' "$str"
}

# Output JSON response
# Args: $1=success(true/false), $2=data, $3=error_code, $4=error_message, $5=error_suggestion
# Outputs: JSON string
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
        local escaped_message escaped_suggestion
        escaped_message=$(json_escape "$error_message")
        escaped_suggestion=$(json_escape "$error_suggestion")
        
        printf '{"success":false,"timestamp":"%s","data":null,"error":{"code":"%s","message":"%s","suggestion":"%s"}}\n' \
            "$timestamp" "$error_code" "$escaped_message" "$escaped_suggestion"
    fi
}

# =============================================================================
# Password File Security
# =============================================================================

# Read password from file with security checks
# Args: $1=file_path
# Returns: 0 on success, 1 on failure
# Outputs: password on success, error message on failure (to stderr)
get_password_from_file() {
    local file="$1"
    
    # Check file exists
    if [[ ! -f "$file" ]]; then
        log_error "Password file not found: $file"
        return 1
    fi
    
    # Check ownership (must be root or current user)
    local file_owner current_uid
    file_owner=$(stat -c %u "$file")
    current_uid=$(id -u)
    if [[ "$file_owner" != "$current_uid" && "$file_owner" != "0" ]]; then
        log_error "Password file must be owned by root or current user"
        return 1
    fi
    
    # Check permissions (must be 600)
    local file_mode
    file_mode=$(stat -c %a "$file")
    if [[ "$file_mode" != "600" ]]; then
        log_error "Password file must have mode 600 (has $file_mode)"
        return 1
    fi
    
    # Read password
    local password
    password=$(cat "$file")
    
    # Remove trailing newline
    password="${password%$'\n'}"
    
    # Basic validation
    if [[ ${#password} -lt 6 ]]; then
        log_error "Password in file must be at least 6 characters"
        return 1
    fi
    
    printf '%s' "$password"
    return 0
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate username format
# Args: $1=username
# Returns: 0 if valid, 1 if invalid
# Outputs: username on success, error message on failure (to stderr)
validate_username() {
    local username="$1"
    
    if [[ ! "$username" =~ ^[a-zA-Z0-9]{2,32}$ ]]; then
        log_error "Invalid username: must be 2-32 alphanumeric characters"
        return 1
    fi
    
    printf '%s' "$username"
    return 0
}

# Validate GM level
# Args: $1=level
# Returns: 0 if valid, 1 if invalid
# Outputs: level on success, error message on failure (to stderr)
validate_gm_level() {
    local level="$1"
    
    if [[ ! "$level" =~ ^[0-3]$ ]]; then
        log_error "Invalid GM level: must be 0-3"
        return 1
    fi
    
    printf '%s' "$level"
    return 0
}

# =============================================================================
# Utility Functions
# =============================================================================

# Check if running as root
# Returns: 0 if root, 1 if not
# Outputs: nothing
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command must be run as root (use sudo)"
        return 1
    fi
    return 0
}

# Initialize on source
log_init
