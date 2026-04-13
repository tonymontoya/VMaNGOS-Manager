#!/usr/bin/env bash
#
# Configuration management for VMANGOS Manager
# INI file parsing and validation
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# CONFIG FILE OPERATIONS
# ============================================================================

# Read a value from INI file
# Usage: ini_read <file> <section> <key> [default]
ini_read() {
    local file="$1"
    local section="$2"
    local key="$3"
    local default="${4:-}"
    local value
    
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return 1
    fi
    
    # Parse INI file - look for key in section
    value=$(awk -F '=' \
        -v section="$section" \
        -v key="$key" \
        '
        /^\[.*\]$/ { current_section = $0; gsub(/^\[|\]$/, "", current_section) }
        current_section == section && $1 ~ "^" key "$" {
            gsub(/^[^=]+= */, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
        ' "$file" 2>/dev/null)
    
    if [[ -n "$value" ]]; then
        # Remove quotes if present
        value="${value%\"}"
        value="${value#\"}"
        echo "$value"
    else
        echo "$default"
        return 1
    fi
}

# Load configuration into associative array
# Usage: config_load <file> [prefix]
config_load() {
    local file="$1"
    local prefix="${2:-CONFIG_}"
    local current_section=""
    local line key value
    
    if [[ ! -f "$file" ]]; then
        log_error "Config file not found: $file"
        return 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # Section header
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Key=value pair
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            
            # Trim whitespace
            key="${key// /}"
            value="${value#\"}"
            value="${value%\"}"
            value="${value# }"
            value="${value% }"
            
            # Export with prefix
            local var_name="${prefix}${current_section}_${key}"
            var_name="${var_name//-/_}"
            var_name="${var_name^^}"
            
            export "$var_name=$value"
            log_debug "Config loaded: $var_name=$value"
        fi
    done < "$file"
    
    return 0
}

# Validate configuration file
# Usage: config_validate <file>
config_validate() {
    local file="$1"
    local errors=0
    
    if [[ ! -f "$file" ]]; then
        log_error "Config file does not exist: $file"
        return 1
    fi
    
    if [[ ! -r "$file" ]]; then
        log_error "Config file not readable: $file"
        return 1
    fi
    
    # Check for required sections
    local required_sections=("database" "server")
    for section in "${required_sections[@]}"; do
        if ! grep -q "^\[$section\]" "$file"; then
            log_warn "Missing config section: [$section]"
            ((errors++))
        fi
    done
    
    # Validate paths exist
    local install_root
    install_root=$(ini_read "$file" "server" "install_root" "")
    if [[ -n "$install_root" && ! -d "$install_root" ]]; then
        log_warn "Install root does not exist: $install_root"
        ((errors++))
    fi
    
    return $errors
}

# Create default configuration file
# Usage: config_create <file>
config_create() {
    local file="$1"
    local dir
    dir=$(dirname "$file")
    
    mkdir -p "$dir"
    
    cat > "$file" << 'EOF'
# VMANGOS Manager Configuration
# Generated automatically - modify as needed

[database]
host = 127.0.0.1
port = 3306
user = mangos
password_file = /opt/mangos/.dbpass
auth_db = auth
characters_db = characters
world_db = world
logs_db = logs

[server]
install_root = /opt/mangos
auth_service = auth
world_service = world
console_enabled = false

[logging]
level = info
file = /var/log/vmangos-manager.log

[backup]
enabled = true
path = /opt/mangos/backups
retention_days = 7

[health]
enabled = true
check_interval_minutes = 5
EOF
    
    chmod 644 "$file"
    log_info "Created default config: $file"
}

# Get database credentials file path
config_get_cred_file() {
    local config_file="${1:-$CONFIG_FILE}"
    local cred_file
    
    cred_file=$(ini_read "$config_file" "database" "password_file" "/opt/mangos/.dbpass")
    echo "$cred_file"
}
