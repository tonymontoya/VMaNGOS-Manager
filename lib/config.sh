#!/bin/bash
# =============================================================================
# VMANGOS Manager - Configuration Library
# =============================================================================
# Provides: INI file parsing, config file management
# =============================================================================

# Note: common.sh should be sourced before this file

# =============================================================================
# INI File Parser
# =============================================================================

# Parse INI file and export variables
# Format: section_key=value
config_parse_ini() {
    local config_file="$1"
    local prefix="${2:-CONFIG}"
    
    if [[ ! -f "$config_file" ]]; then
        error_exit "Config file not found: $config_file"
    fi
    
    local current_section=""
    local line_num=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # Section header [section]
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Key = value
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Remove trailing comments
            value="${value%%#*}"
            # Trim whitespace
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            
            # Remove surrounding quotes if present
            if [[ "$value" =~ ^\"(.*)\"$ ]]; then
                value="${BASH_REMATCH[1]}"
            elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            
            # Export with prefix and section
            if [[ -n "$current_section" ]]; then
                export "${prefix}_${current_section}_${key}=$value"
            else
                export "${prefix}_${key}=$value"
            fi
        fi
    done < "$config_file"
}

# Get config value
config_get() {
    local key="$1"
    local default="${2:-}"
    
    # Try to get from environment (already parsed)
    local var_name="CONFIG_${key}"
    local value="${!var_name:-}"
    
    if [[ -z "$value" && -n "$default" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

# =============================================================================
# VMANGOS Specific Config
# =============================================================================

# Default config file location
VMANGOS_CONFIG_FILE="${VMANGOS_CONFIG_FILE:-/opt/mangos/manager/manager.conf}"

# Load manager config
config_load() {
    local config_file="${1:-$VMANGOS_CONFIG_FILE}"
    
    # Set defaults
    export CONFIG_install_dir="/opt/mangos"
    export CONFIG_log_dir="/var/log/vmangos-manager"
    export CONFIG_db_host="localhost"
    export CONFIG_db_port="3306"
    export CONFIG_db_admin_user="root"
    export CONFIG_db_manager_user="vmangos_mgr"
    export CONFIG_backup_dir="/opt/mangos/backups"
    export CONFIG_backup_retention_days="7"
    
    # Parse config file if exists
    if [[ -f "$config_file" ]]; then
        log_info "Loading config from: $config_file"
        config_parse_ini "$config_file"
    else
        log_warn "Config file not found, using defaults: $config_file"
    fi
}

# Get database credentials file path
config_get_db_creds_file() {
    printf '%s' "${CONFIG_db_credentials_file:-/root/.vmangos-secrets/db.conf}"
}

# =============================================================================
# Server Config File Management
# =============================================================================

# Read value from mangosd.conf or realmd.conf
server_config_get() {
    local config_file="$1"
    local key="$2"
    
    if [[ ! -f "$config_file" ]]; then
        error_exit "Server config file not found: $config_file"
    fi
    
    # Parse key = value format (handling quoted values)
    grep -E "^${key}\s*=" "$config_file" | sed -E 's/^[^=]+=\s*//; s/^"//; s/"$//' | head -1
}

# Update value in server config file
server_config_set() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    
    if [[ ! -f "$config_file" ]]; then
        error_exit "Server config file not found: $config_file"
    fi
    
    # Backup original
    cp "$config_file" "${config_file}.bak.$(date +%s)"
    
    # Update or add the setting
    if grep -qE "^${key}\s*=" "$config_file"; then
        # Update existing
        sed -i -E "s/^(${key}\s*=\s*).*/\1${value}/" "$config_file"
    else
        # Add new
        echo "${key} = ${value}" >> "$config_file"
    fi
    
    log_info "Updated $key in $config_file"
}

# Get database connection info from mangosd.conf
server_config_get_db_info() {
    local config_file="$1"
    local db_type="$2"  # world, auth, characters, logs
    
    local setting_name
    case "$db_type" in
        world) setting_name="WorldDatabaseInfo" ;;
        auth) setting_name="LoginDatabaseInfo" ;;
        characters) setting_name="CharacterDatabaseInfo" ;;
        logs) setting_name="LogsDatabaseInfo" ;;
        *) error_exit "Unknown database type: $db_type" ;;
    esac
    
    # Format: host;port;user;password;database
    server_config_get "$config_file" "$setting_name"
}

# Parse database connection string
# Input: host;port;user;password;database
# Output: exports DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME
parse_db_connection_string() {
    local conn_string="$1"
    
    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$conn_string"
    
    export DB_HOST DB_PORT DB_USER DB_PASS DB_NAME
}
