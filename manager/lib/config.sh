#!/usr/bin/env bash
#
# Configuration module for VMANGOS Manager
#

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Globals
CONFIG_FILE="${MANAGER_CONFIG:-/opt/mangos/manager/config/manager.conf}"
export CONFIG_FILE
CONFIG_PASSWORD_FILE=""

# Loaded config values (exported for use by other modules)
export CONFIG_DATABASE_HOST=""
export CONFIG_DATABASE_PORT=""
export CONFIG_DATABASE_USER=""
export CONFIG_DATABASE_PASSWORD=""
export CONFIG_DATABASE_AUTH_DB=""

export CONFIG_SERVER_AUTH_SERVICE=""
export CONFIG_SERVER_WORLD_SERVICE=""
export CONFIG_SERVER_INSTALL_ROOT=""

export CONFIG_BACKUP_ENABLED=""
export CONFIG_BACKUP_DIR=""
export CONFIG_BACKUP_RETENTION_DAYS=""
export CONFIG_DATABASE_CHARACTERS_DB=""
export CONFIG_DATABASE_WORLD_DB=""
export CONFIG_DATABASE_LOGS_DB=""

# ============================================================================
# INI PARSING
# ============================================================================

ini_read() {
    local file="$1"
    local section="$2"
    local key="$3"
    local default="${4:-}"
    
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return 1
    fi
    
    local value
    value=$(awk -F'=' -v sec="$section" -v k="$key" '
        /^\[.*\]$/ {
            gsub(/^\[|\]$/, "", $0)
            in_section = ($0 == sec)
            next
        }
        in_section {
            gsub(/^[ \t]+|[ \t]+$/, "", $1)
            if ($1 == k) {
                gsub(/^[ \t]+|[ \t]+$/, "", $2)
                print $2
                found = 1
                exit
            }
        }
        END {
            if (!found) exit 1
        }
    ' "$file")
    
    if [[ -z "$value" ]]; then
        value="$default"
    fi
    
    echo "$value"
}

# ============================================================================
# CONFIG LOADING
# ============================================================================

config_load() {
    local config_file="${1:-$CONFIG_FILE}"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi
    
    local perms
    perms=$(get_file_permissions "$config_file" 2>/dev/null || echo "644")
    if [[ "$perms" != "600" ]]; then
        log_warn "Config file permissions are $perms, should be 600"
    fi
    
    CONFIG_DATABASE_HOST=$(ini_read "$config_file" "database" "host" "127.0.0.1")
    CONFIG_DATABASE_PORT=$(ini_read "$config_file" "database" "port" "3306")
    CONFIG_DATABASE_USER=$(ini_read "$config_file" "database" "user" "mangos")
    
    CONFIG_PASSWORD_FILE=$(ini_read "$config_file" "database" "password_file" "")
    if [[ -f "${CONFIG_PASSWORD_FILE:-}" ]]; then
        CONFIG_DATABASE_PASSWORD=$(cat "$CONFIG_PASSWORD_FILE" 2>/dev/null || true)
    else
        CONFIG_DATABASE_PASSWORD=$(ini_read "$config_file" "database" "password" "")
    fi
    
    CONFIG_DATABASE_AUTH_DB=$(ini_read "$config_file" "database" "auth_db" "auth")
    
    CONFIG_SERVER_AUTH_SERVICE=$(ini_read "$config_file" "server" "auth_service" "auth")
    CONFIG_SERVER_WORLD_SERVICE=$(ini_read "$config_file" "server" "world_service" "world")
    CONFIG_SERVER_INSTALL_ROOT=$(ini_read "$config_file" "server" "install_root" "/opt/mangos")
    
    CONFIG_BACKUP_ENABLED=$(ini_read "$config_file" "backup" "enabled" "true")
    CONFIG_BACKUP_DIR=$(ini_read "$config_file" "backup" "backup_dir" "/opt/mangos/backups")
    CONFIG_BACKUP_RETENTION_DAYS=$(ini_read "$config_file" "backup" "retention_days" "30")
    CONFIG_DATABASE_CHARACTERS_DB=$(ini_read "$config_file" "database" "characters_db" "characters")
    CONFIG_DATABASE_WORLD_DB=$(ini_read "$config_file" "database" "world_db" "mangos")
    CONFIG_DATABASE_LOGS_DB=$(ini_read "$config_file" "database" "logs_db" "logs")
    
    log_debug "Configuration loaded from $config_file"
    return 0
}

config_resolve_manager_root() {
    local config_file="${1:-$CONFIG_FILE}"
    local config_dir

    if [[ -n "${MANAGER_ROOT:-}" ]]; then
        printf '%s\n' "$MANAGER_ROOT"
        return 0
    fi

    if [[ -f "$config_file" ]]; then
        config_dir=$(cd "$(dirname "$config_file")" && pwd)
        printf '%s\n' "$(cd "$config_dir/.." && pwd)"
        return 0
    fi

    if [[ -n "${CONFIG_SERVER_INSTALL_ROOT:-}" ]]; then
        printf '%s/manager\n' "$CONFIG_SERVER_INSTALL_ROOT"
    else
        printf '/opt/mangos/manager\n'
    fi
}

# ============================================================================
# CONFIG CREATION
# ============================================================================

config_create() {
    local config_path="${1:-$CONFIG_FILE}"
    local password_file="${2:-}"
    local default_db_host default_db_user default_auth_db default_characters_db default_world_db default_logs_db

    default_db_host="${VMANGOS_DB_HOST:-127.0.0.1}"
    default_db_user="${VMANGOS_DB_USER:-mangos}"
    default_auth_db="${VMANGOS_AUTH_DB:-auth}"
    default_characters_db="${VMANGOS_CHAR_DB:-characters}"
    default_world_db="${VMANGOS_WORLD_DB:-world}"
    default_logs_db="${VMANGOS_LOGS_DB:-logs}"
    
    log_info "Creating default config: $config_path"
    
    local config_dir
    config_dir=$(dirname "$config_path")
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" || {
            log_error "Failed to create config directory: $config_dir"
            return 1
        }
    fi
    
    if [[ -z "$password_file" ]]; then
        password_file="$config_dir/.dbpass"
    fi
    
    cat > "$config_path" << EOF
# VMANGOS Manager Configuration
# Auto-generated on $(date -Iseconds)

[database]
host = $default_db_host
port = 3306
user = $default_db_user
password_file = $password_file
password = 
auth_db = $default_auth_db
characters_db = $default_characters_db
world_db = $default_world_db
logs_db = $default_logs_db

[server]
auth_service = auth
world_service = world
install_root = /opt/mangos
console_enabled = false

[backup]
enabled = true
backup_dir = /opt/mangos/backups
retention_days = 7

[logging]
file = /var/log/vmangos-manager.log
level = info
EOF

    chmod 600 "$config_path"
    
    if [[ ! -f "$password_file" ]]; then
        touch "$password_file"
        chmod 600 "$password_file"
        log_info "Created password file: $password_file (mode 600)"
    fi
    
    log_info "Configuration created at $config_path (mode 600)"
}

# ============================================================================
# CONFIG VALIDATION
# ============================================================================

config_validate() {
    local config_file="${1:-$CONFIG_FILE}"
    local output_format="${2:-text}"
    
    local errors=()
    local warnings=()
    
    if [[ ! -f "$config_file" ]]; then
        errors+=("Config file not found: $config_file")
        if [[ "$output_format" == "json" ]]; then
            json_output false "null" "CONFIG_NOT_FOUND" "$config_file" "Run 'vmangos-manager config create'"
        else
            log_error "Config file not found: $config_file"
            log_info "Run: vmangos-manager config create"
        fi
        return 1
    fi
    
    local perms
    perms=$(get_file_permissions "$config_file" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" ]]; then
        warnings+=("Config file permissions are $perms (should be 600)")
    fi
    
    local required_fields=(
        "database:host"
        "database:port"
        "database:user"
        "server:auth_service"
        "server:world_service"
        "server:install_root"
    )
    
    for field in "${required_fields[@]}"; do
        local section key value
        section="${field%%:*}"
        key="${field##*:}"
        value=$(ini_read "$config_file" "$section" "$key")
        
        if [[ -z "$value" ]]; then
            errors+=("Missing required field: [$section] $key")
        fi
    done
    
    if [[ "$output_format" == "json" ]]; then
        local valid=false
        if [[ ${#errors[@]} -eq 0 ]]; then
            valid=true
        fi
        local data
        data=$(printf '{"valid": %s, "errors": [], "warnings": []}' "$valid")
        json_output "$valid" "$data"
    else
        echo ""
        echo "Config File: $config_file"
        echo "Permissions: $perms"
        echo ""
        
        if [[ ${#errors[@]} -eq 0 && ${#warnings[@]} -eq 0 ]]; then
            echo "Configuration is valid"
            return 0
        fi
        
        if [[ ${#errors[@]} -gt 0 ]]; then
            echo "Errors:"
            for err in "${errors[@]}"; do
                echo "  ✗ $err"
            done
            echo ""
        fi
        
        if [[ ${#warnings[@]} -gt 0 ]]; then
            echo "Warnings:"
            for warn in "${warnings[@]}"; do
                echo "  ⚠ $warn"
            done
        fi
        
        if [[ ${#errors[@]} -eq 0 ]]; then
            return 0
        else
            return 1
        fi
    fi
}

# ============================================================================
# CONFIG SHOW
# ============================================================================

config_show() {
    local config_file="${1:-$CONFIG_FILE}"
    local output_format="${2:-text}"
    
    if [[ ! -f "$config_file" ]]; then
        if [[ "$output_format" == "json" ]]; then
            json_output false "null" "CONFIG_NOT_FOUND" "Configuration file not found: $config_file" "Run 'config create' first"
        else
            log_error "Configuration file not found: $config_file"
            log_info "Run: vmangos-manager config create"
        fi
        return 1
    fi
    
    if [[ "$output_format" == "json" ]]; then
        local content escaped_content
        content=$(cat "$config_file")
        escaped_content=$(json_escape "$content")
        json_output true "{\"config_file\": \"$config_file\", \"content\": \"$escaped_content\"}"
    else
        echo "=== Configuration File: $config_file ==="
        echo ""
        cat "$config_file"
    fi
}
