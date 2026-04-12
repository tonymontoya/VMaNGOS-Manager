#!/bin/bash
# =============================================================================
# VMANGOS Manager - Configuration Library
# =============================================================================
# Provides: INI file parsing, config file management
# 
# Error Handling Convention:
#   - Functions return 0 on success, non-zero on failure
#   - Functions should NOT call error_exit (let caller decide)
# =============================================================================

# =============================================================================
# INI File Parser
# =============================================================================

# Parse INI file and export variables
# Args: $1=config_file, $2=prefix (default: CONFIG)
# Returns: 0 on success, 1 on failure
# Note: Variables are exported as ${prefix}_${section}_${key} or ${prefix}_${key}
config_parse_ini() {
    local config_file="$1"
    local prefix="${2:-CONFIG}"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    local current_section=""
    local line_num=0
    local has_error=0
    
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
                export "${prefix}_${current_section}_${key}=$value" || has_error=1
            else
                export "${prefix}_${key}=$value" || has_error=1
            fi
        fi
    done < "$config_file"
    
    return $has_error
}

# Get config value from environment
# Args: $1=key, $2=default_value (optional)
# Outputs: value or default
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

# Load manager config with defaults
# Args: $1=config_file (optional, uses VMANGOS_CONFIG_FILE if not specified)
# Returns: 0 on success, 1 if config file not found (uses defaults)
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
        config_parse_ini "$config_file" || {
            log_warn "Error parsing config file, using defaults"
            return 1
        }
    else
        log_warn "Config file not found, using defaults: $config_file"
        return 1
    fi
    
    return 0
}

# Get database credentials file path
# Outputs: path to credentials file
config_get_db_creds_file() {
    printf '%s' "${CONFIG_db_credentials_file:-/root/.vmangos-secrets/db.conf}"
}

# =============================================================================
# Server Config File Management
# =============================================================================

# Read value from server config file (mangosd.conf or realmd.conf)
# Args: $1=config_file, $2=key
# Returns: 0 on success, 1 on failure
# Outputs: value
server_config_get() {
    local config_file="$1"
    local key="$2"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Server config file not found: $config_file"
        return 1
    fi
    
    # Parse key = value format (handling quoted values)
    grep -E "^${key}\s*=" "$config_file" 2>/dev/null | \
        sed -E 's/^[^=]+=\s*//; s/^"//; s/"$//' | head -1
    
    return 0
}

# Update value in server config file
# Args: $1=config_file, $2=key, $3=value
# Returns: 0 on success, 1 on failure
server_config_set() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Server config file not found: $config_file"
        return 1
    fi
    
    # Validate key (alphanumeric and underscores only)
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid config key: $key"
        return 1
    fi
    
    # Backup original
    if ! cp "$config_file" "${config_file}.bak.$(date +%s)"; then
        log_error "Failed to backup config file"
        return 1
    fi
    
    # Update or add the setting
    if grep -qE "^${key}\s*=" "$config_file" 2>/dev/null; then
        # Update existing
        if ! sed -i -E "s/^(${key}\s*=\s*).*/\1${value}/" "$config_file"; then
            log_error "Failed to update config key: $key"
            return 1
        fi
    else
        # Add new
        if ! echo "${key} = ${value}" >> "$config_file"; then
            log_error "Failed to add config key: $key"
            return 1
        fi
    fi
    
    log_info "Updated $key in $config_file"
    return 0
}

# Get database connection info from mangosd.conf
# Args: $1=config_file, $2=db_type (world|auth|characters|logs)
# Returns: 0 on success, 1 on failure
# Outputs: connection string (format: host;port;user;password;database)
server_config_get_db_info() {
    local config_file="$1"
    local db_type="$2"
    
    local setting_name
    case "$db_type" in
        world) setting_name="WorldDatabaseInfo" ;;
        auth) setting_name="LoginDatabaseInfo" ;;
        characters) setting_name="CharacterDatabaseInfo" ;;
        logs) setting_name="LogsDatabaseInfo" ;;
        *) 
            log_error "Unknown database type: $db_type"
            return 1
            ;;
    esac
    
    # Format: host;port;user;password;database
    server_config_get "$config_file" "$setting_name"
}

# Parse database connection string
# Args: $1=connection_string (format: host;port;user;password;database)
# Exports: DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME
# Returns: 0 on success, 1 on failure
parse_db_connection_string() {
    local conn_string="$1"
    
    # Validate format
    local field_count
    field_count=$(echo "$conn_string" | tr ';' '\n' | wc -l)
    if [[ $field_count -lt 5 ]]; then
        log_error "Invalid connection string format (expected 5 fields, got $field_count)"
        return 1
    fi
    
    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$conn_string"
    
    # Basic validation
    if [[ -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_USER" || -z "$DB_NAME" ]]; then
        log_error "Invalid connection string: missing required fields"
        return 1
    fi
    
    export DB_HOST DB_PORT DB_USER DB_PASS DB_NAME
    return 0
}
