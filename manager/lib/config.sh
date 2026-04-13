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

CONFIG_DETECT_ROOTS=()
CONFIG_DETECT_SERVICE_HINTS=()

CONFIG_DETECT_CURRENT_ROOT=""
CONFIG_DETECT_CURRENT_CONFIG_PATH=""
CONFIG_DETECT_CURRENT_PASSWORD_FILE=""
CONFIG_DETECT_CURRENT_BACKUP_DIR=""
CONFIG_DETECT_CURRENT_AUTH_SERVICE=""
CONFIG_DETECT_CURRENT_WORLD_SERVICE=""
CONFIG_DETECT_CURRENT_DB_HOST=""
CONFIG_DETECT_CURRENT_DB_PORT=""
CONFIG_DETECT_CURRENT_DB_USER=""
CONFIG_DETECT_CURRENT_AUTH_DB=""
CONFIG_DETECT_CURRENT_CHARACTERS_DB=""
CONFIG_DETECT_CURRENT_WORLD_DB=""
CONFIG_DETECT_CURRENT_LOGS_DB=""
CONFIG_DETECT_CURRENT_SCORE=0
CONFIG_DETECT_CURRENT_LEVEL="low"
CONFIG_DETECT_CURRENT_SIGNALS=()
CONFIG_DETECT_CURRENT_ASSUMPTIONS=()
CONFIG_DETECT_CURRENT_ISSUES=()

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

config_trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

config_array_contains() {
    local needle="$1"
    shift || true

    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

config_join_by() {
    local delimiter="$1"
    shift || true

    local joined="" item
    for item in "$@"; do
        [[ -n "$joined" ]] && joined+="$delimiter"
        joined+="$item"
    done

    printf '%s' "$joined"
}

config_json_array() {
    if [[ $# -eq 0 ]]; then
        printf '[]'
        return 0
    fi

    local item escaped joined=""
    for item in "$@"; do
        escaped=$(json_escape "$item")
        joined+="\"$escaped\","
    done

    printf '[%s]' "${joined%,}"
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
# CONFIG DETECTION
# ============================================================================

config_detect_reset_state() {
    CONFIG_DETECT_ROOTS=()
    CONFIG_DETECT_SERVICE_HINTS=()
}

config_detect_reset_candidate() {
    CONFIG_DETECT_CURRENT_ROOT=""
    CONFIG_DETECT_CURRENT_CONFIG_PATH=""
    CONFIG_DETECT_CURRENT_PASSWORD_FILE=""
    CONFIG_DETECT_CURRENT_BACKUP_DIR=""
    CONFIG_DETECT_CURRENT_AUTH_SERVICE=""
    CONFIG_DETECT_CURRENT_WORLD_SERVICE=""
    CONFIG_DETECT_CURRENT_DB_HOST=""
    CONFIG_DETECT_CURRENT_DB_PORT=""
    CONFIG_DETECT_CURRENT_DB_USER=""
    CONFIG_DETECT_CURRENT_AUTH_DB=""
    CONFIG_DETECT_CURRENT_CHARACTERS_DB=""
    CONFIG_DETECT_CURRENT_WORLD_DB=""
    CONFIG_DETECT_CURRENT_LOGS_DB=""
    CONFIG_DETECT_CURRENT_SCORE=0
    CONFIG_DETECT_CURRENT_LEVEL="low"
    CONFIG_DETECT_CURRENT_SIGNALS=()
    CONFIG_DETECT_CURRENT_ASSUMPTIONS=()
    CONFIG_DETECT_CURRENT_ISSUES=()
}

config_detect_register_root() {
    local root="$1"

    [[ -n "$root" ]] || return 0
    [[ -d "$root" ]] || return 0

    if [[ ${#CONFIG_DETECT_ROOTS[@]} -eq 0 ]] || ! config_array_contains "$root" "${CONFIG_DETECT_ROOTS[@]}"; then
        CONFIG_DETECT_ROOTS+=("$root")
    fi
}

config_detect_register_service_hint() {
    local root="$1"
    local role="$2"
    local service="$3"
    local record="$root|$role|$service"

    if [[ ${#CONFIG_DETECT_SERVICE_HINTS[@]} -eq 0 ]] || ! config_array_contains "$record" "${CONFIG_DETECT_SERVICE_HINTS[@]}"; then
        CONFIG_DETECT_SERVICE_HINTS+=("$record")
    fi
}

config_detect_systemd_available() {
    command -v systemctl >/dev/null 2>&1
}

config_detect_extract_exec_path() {
    local details="$1"

    printf '%s\n' "$details" | grep -Eo '/[^ ;"}]+/run/bin/(realmd|mangosd)' | head -1 || true
}

config_detect_collect_systemd_hints() {
    local unit details exec_path install_root role service_name

    config_detect_systemd_available || return 0

    while IFS= read -r unit; do
        unit=$(config_trim "${unit%% *}")
        [[ -n "$unit" ]] || continue

        details=$(systemctl show -p Id -p ExecStart "$unit" 2>/dev/null || true)
        exec_path=$(config_detect_extract_exec_path "$details")
        [[ -n "$exec_path" ]] || continue

        install_root=$(dirname "$(dirname "$(dirname "$exec_path")")")
        case "$(basename "$exec_path")" in
            realmd) role="auth" ;;
            mangosd) role="world" ;;
            *) continue ;;
        esac

        service_name="${unit%.service}"
        config_detect_register_root "$install_root"
        config_detect_register_service_hint "$install_root" "$role" "$service_name"
    done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}')
}

config_detect_search_roots() {
    local search_roots="${VMANGOS_DETECT_SEARCH_ROOTS:-}"
    local root

    if [[ -n "$search_roots" ]]; then
        IFS=':' read -r -a CONFIG_DETECT_SEARCH_ROOT_LIST <<< "$search_roots"
        for root in "${CONFIG_DETECT_SEARCH_ROOT_LIST[@]}"; do
            [[ -n "$root" ]] && printf '%s\n' "$root"
        done
        return 0
    fi

    printf '%s\n' /opt /srv /usr/local /home
}

config_detect_collect_filesystem_roots() {
    local search_root conf_path install_root

    while IFS= read -r search_root; do
        [[ -d "$search_root" ]] || continue

        while IFS= read -r conf_path; do
            [[ -n "$conf_path" ]] || continue

            install_root="${conf_path%/run/etc/mangosd.conf}"
            if [[ "$install_root" == "$conf_path" ]]; then
                install_root="${conf_path%/run/etc/realmd.conf}"
            fi
            [[ "$install_root" != "$conf_path" ]] || continue

            config_detect_register_root "$install_root"
        done < <(find "$search_root" -maxdepth "${VMANGOS_DETECT_FIND_DEPTH:-7}" -type f \( -path '*/run/etc/mangosd.conf' -o -path '*/run/etc/realmd.conf' \) 2>/dev/null)
    done < <(config_detect_search_roots)
}

config_detect_read_setting() {
    local file="$1"
    local key="$2"

    [[ -f "$file" ]] || return 0

    awk -v target="$key" '
        /^[[:space:]]*[#;]/ { next }
        {
            line=$0
            pos=index(line, "=")
            if (pos == 0) next

            left=substr(line, 1, pos - 1)
            right=substr(line, pos + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", left)
            if (left != target) next

            gsub(/^[ \t"]+|[ \t"]+$/, "", right)
            print right
            exit
        }
    ' "$file" 2>/dev/null
}

config_detect_parse_db_tuple() {
    local tuple="$1"
    local host port user password database

    IFS=';' read -r host port user password database _ <<< "$tuple"

    host=$(config_trim "$host")
    port=$(config_trim "$port")
    user=$(config_trim "$user")
    password=$(config_trim "$password")
    database=$(config_trim "$database")

    printf '%s|%s|%s|%s|%s\n' "$host" "$port" "$user" "$password" "$database"
}

config_detect_lookup_service() {
    local install_root="$1"
    local role="$2"
    local record record_root record_role record_service

    CONFIG_DETECT_LOOKUP_RESULT=""
    CONFIG_DETECT_LOOKUP_COUNT=0

    [[ ${#CONFIG_DETECT_SERVICE_HINTS[@]} -gt 0 ]] || return 0

    for record in "${CONFIG_DETECT_SERVICE_HINTS[@]}"; do
        IFS='|' read -r record_root record_role record_service <<< "$record"
        if [[ "$record_root" == "$install_root" && "$record_role" == "$role" ]]; then
            CONFIG_DETECT_LOOKUP_COUNT=$((CONFIG_DETECT_LOOKUP_COUNT + 1))
            if [[ -z "$CONFIG_DETECT_LOOKUP_RESULT" ]]; then
                CONFIG_DETECT_LOOKUP_RESULT="$record_service"
            fi
        fi
    done
}

config_detect_add_signal() {
    CONFIG_DETECT_CURRENT_SIGNALS+=("$1")
}

config_detect_add_assumption() {
    CONFIG_DETECT_CURRENT_ASSUMPTIONS+=("$1")
}

config_detect_add_issue() {
    CONFIG_DETECT_CURRENT_ISSUES+=("$1")
}

config_detect_add_unique_value() {
    local value="$1"
    shift

    [[ -n "$value" ]] || return 0
    if ! config_array_contains "$value" "$@"; then
        printf '%s\n' "$value"
    fi
}

config_detect_analyze_candidate() {
    local install_root="$1"
    local realmd_conf="$install_root/run/etc/realmd.conf"
    local mangosd_conf="$install_root/run/etc/mangosd.conf"
    local realmd_tuple mangos_login_tuple world_tuple characters_tuple logs_tuple
    local auth_host auth_port auth_user auth_db
    local login_host login_port login_user login_db
    local world_host world_port world_user world_db
    local characters_host characters_port characters_user characters_db
    local logs_host logs_port logs_user logs_db
    local endpoint_hosts=() endpoint_ports=() endpoint_users=()
    local manager_root="$install_root/manager"
    local config_dir="$manager_root/config"

    config_detect_reset_candidate

    CONFIG_DETECT_CURRENT_ROOT="$install_root"
    CONFIG_DETECT_CURRENT_CONFIG_PATH="$config_dir/manager.conf"
    CONFIG_DETECT_CURRENT_PASSWORD_FILE="$config_dir/.dbpass"
    CONFIG_DETECT_CURRENT_BACKUP_DIR="$install_root/backups"

    if [[ -f "$realmd_conf" ]]; then
        CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE + 20))
        config_detect_add_signal "Found realmd.conf at $realmd_conf"
        realmd_tuple=$(config_detect_read_setting "$realmd_conf" "LoginDatabaseInfo")
        if [[ -n "$realmd_tuple" ]]; then
            IFS='|' read -r auth_host auth_port auth_user _ auth_db <<< "$(config_detect_parse_db_tuple "$realmd_tuple")"
            CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE + 10))
            config_detect_add_signal "Parsed auth DB settings from realmd.conf"
        fi
    else
        config_detect_add_assumption "realmd.conf was not found under $install_root/run/etc"
    fi

    if [[ -f "$mangosd_conf" ]]; then
        CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE + 20))
        config_detect_add_signal "Found mangosd.conf at $mangosd_conf"

        mangos_login_tuple=$(config_detect_read_setting "$mangosd_conf" "LoginDatabase.Info")
        if [[ -n "$mangos_login_tuple" ]]; then
            IFS='|' read -r login_host login_port login_user _ login_db <<< "$(config_detect_parse_db_tuple "$mangos_login_tuple")"
            config_detect_add_signal "Parsed login DB settings from mangosd.conf"
        fi

        world_tuple=$(config_detect_read_setting "$mangosd_conf" "WorldDatabase.Info")
        if [[ -n "$world_tuple" ]]; then
            IFS='|' read -r world_host world_port world_user _ world_db <<< "$(config_detect_parse_db_tuple "$world_tuple")"
            config_detect_add_signal "Parsed world DB settings from mangosd.conf"
        fi

        characters_tuple=$(config_detect_read_setting "$mangosd_conf" "CharacterDatabase.Info")
        if [[ -n "$characters_tuple" ]]; then
            IFS='|' read -r characters_host characters_port characters_user _ characters_db <<< "$(config_detect_parse_db_tuple "$characters_tuple")"
            config_detect_add_signal "Parsed character DB settings from mangosd.conf"
        fi

        logs_tuple=$(config_detect_read_setting "$mangosd_conf" "LogsDatabase.Info")
        if [[ -n "$logs_tuple" ]]; then
            IFS='|' read -r logs_host logs_port logs_user _ logs_db <<< "$(config_detect_parse_db_tuple "$logs_tuple")"
            config_detect_add_signal "Parsed logs DB settings from mangosd.conf"
        fi
    else
        config_detect_add_assumption "mangosd.conf was not found under $install_root/run/etc"
    fi

    config_detect_lookup_service "$install_root" "auth"
    if [[ "$CONFIG_DETECT_LOOKUP_COUNT" -gt 0 ]]; then
        CONFIG_DETECT_CURRENT_AUTH_SERVICE="$CONFIG_DETECT_LOOKUP_RESULT"
        CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE + 15))
        config_detect_add_signal "Matched auth service '$CONFIG_DETECT_CURRENT_AUTH_SERVICE' from systemd"
        if [[ "$CONFIG_DETECT_LOOKUP_COUNT" -gt 1 ]]; then
            config_detect_add_issue "Multiple auth services matched $install_root; using '$CONFIG_DETECT_CURRENT_AUTH_SERVICE'"
        fi
    else
        CONFIG_DETECT_CURRENT_AUTH_SERVICE="auth"
        config_detect_add_assumption "No auth service was detected from systemd; defaulting to 'auth'"
    fi

    config_detect_lookup_service "$install_root" "world"
    if [[ "$CONFIG_DETECT_LOOKUP_COUNT" -gt 0 ]]; then
        CONFIG_DETECT_CURRENT_WORLD_SERVICE="$CONFIG_DETECT_LOOKUP_RESULT"
        CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE + 15))
        config_detect_add_signal "Matched world service '$CONFIG_DETECT_CURRENT_WORLD_SERVICE' from systemd"
        if [[ "$CONFIG_DETECT_LOOKUP_COUNT" -gt 1 ]]; then
            config_detect_add_issue "Multiple world services matched $install_root; using '$CONFIG_DETECT_CURRENT_WORLD_SERVICE'"
        fi
    else
        CONFIG_DETECT_CURRENT_WORLD_SERVICE="world"
        config_detect_add_assumption "No world service was detected from systemd; defaulting to 'world'"
    fi

    if [[ -d "$manager_root" ]]; then
        CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE + 5))
        config_detect_add_signal "Found manager directory at $manager_root"
    fi

    if [[ -d "$install_root/source" ]]; then
        CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE + 5))
        config_detect_add_signal "Found source directory at $install_root/source"
    fi

    endpoint_hosts=()
    endpoint_ports=()
    endpoint_users=()

    for value in "$auth_host" "$login_host" "$world_host" "$characters_host" "$logs_host"; do
        if [[ -n "$value" ]] && ([[ ${#endpoint_hosts[@]} -eq 0 ]] || ! config_array_contains "$value" "${endpoint_hosts[@]}"); then
            endpoint_hosts+=("$value")
        fi
    done

    for value in "$auth_port" "$login_port" "$world_port" "$characters_port" "$logs_port"; do
        if [[ -n "$value" ]] && ([[ ${#endpoint_ports[@]} -eq 0 ]] || ! config_array_contains "$value" "${endpoint_ports[@]}"); then
            endpoint_ports+=("$value")
        fi
    done

    for value in "$auth_user" "$login_user" "$world_user" "$characters_user" "$logs_user"; do
        if [[ -n "$value" ]] && ([[ ${#endpoint_users[@]} -eq 0 ]] || ! config_array_contains "$value" "${endpoint_users[@]}"); then
            endpoint_users+=("$value")
        fi
    done

    CONFIG_DETECT_CURRENT_DB_HOST="${auth_host:-${login_host:-${world_host:-${characters_host:-${logs_host:-}}}}}"
    CONFIG_DETECT_CURRENT_DB_PORT="${auth_port:-${login_port:-${world_port:-${characters_port:-${logs_port:-}}}}}"
    CONFIG_DETECT_CURRENT_DB_USER="${auth_user:-${login_user:-${world_user:-${characters_user:-${logs_user:-}}}}}"
    CONFIG_DETECT_CURRENT_AUTH_DB="${auth_db:-${login_db:-}}"
    CONFIG_DETECT_CURRENT_CHARACTERS_DB="$characters_db"
    CONFIG_DETECT_CURRENT_WORLD_DB="$world_db"
    CONFIG_DETECT_CURRENT_LOGS_DB="$logs_db"

    if [[ ${#endpoint_hosts[@]} -gt 1 || ${#endpoint_ports[@]} -gt 1 || ${#endpoint_users[@]} -gt 1 ]]; then
        config_detect_add_issue "Database endpoints differ across VMANGOS config entries; Manager supports one shared host, port, and user"
        CONFIG_DETECT_CURRENT_SCORE=$((CONFIG_DETECT_CURRENT_SCORE - 15))
    fi

    if [[ -z "$CONFIG_DETECT_CURRENT_DB_HOST" ]]; then
        CONFIG_DETECT_CURRENT_DB_HOST="127.0.0.1"
        config_detect_add_assumption "Database host could not be detected; defaulting to 127.0.0.1"
    fi

    if [[ -z "$CONFIG_DETECT_CURRENT_DB_PORT" ]]; then
        CONFIG_DETECT_CURRENT_DB_PORT="3306"
        config_detect_add_assumption "Database port could not be detected; defaulting to 3306"
    fi

    if [[ -z "$CONFIG_DETECT_CURRENT_DB_USER" ]]; then
        CONFIG_DETECT_CURRENT_DB_USER="mangos"
        config_detect_add_assumption "Database user could not be detected; defaulting to mangos"
    fi

    if [[ -z "$CONFIG_DETECT_CURRENT_AUTH_DB" ]]; then
        CONFIG_DETECT_CURRENT_AUTH_DB="auth"
        config_detect_add_assumption "Auth DB name could not be detected; defaulting to auth"
    fi

    if [[ -z "$CONFIG_DETECT_CURRENT_CHARACTERS_DB" ]]; then
        CONFIG_DETECT_CURRENT_CHARACTERS_DB="characters"
        config_detect_add_assumption "Characters DB name could not be detected; defaulting to characters"
    fi

    if [[ -z "$CONFIG_DETECT_CURRENT_WORLD_DB" ]]; then
        CONFIG_DETECT_CURRENT_WORLD_DB="world"
        config_detect_add_assumption "World DB name could not be detected; defaulting to world"
    fi

    if [[ -z "$CONFIG_DETECT_CURRENT_LOGS_DB" ]]; then
        CONFIG_DETECT_CURRENT_LOGS_DB="logs"
        config_detect_add_assumption "Logs DB name could not be detected; defaulting to logs"
    fi

    config_detect_add_assumption "DB password is intentionally omitted from the generated config; populate $CONFIG_DETECT_CURRENT_PASSWORD_FILE before use"

    if [[ "$CONFIG_DETECT_CURRENT_SCORE" -ge 70 ]]; then
        CONFIG_DETECT_CURRENT_LEVEL="high"
    elif [[ "$CONFIG_DETECT_CURRENT_SCORE" -ge 45 ]]; then
        CONFIG_DETECT_CURRENT_LEVEL="medium"
    else
        CONFIG_DETECT_CURRENT_LEVEL="low"
    fi
}

config_detect_proposed_config() {
    cat << EOF
# Proposed VMANGOS Manager configuration for review

[database]
host = $CONFIG_DETECT_CURRENT_DB_HOST
port = $CONFIG_DETECT_CURRENT_DB_PORT
user = $CONFIG_DETECT_CURRENT_DB_USER
password_file = $CONFIG_DETECT_CURRENT_PASSWORD_FILE
password =
auth_db = $CONFIG_DETECT_CURRENT_AUTH_DB
characters_db = $CONFIG_DETECT_CURRENT_CHARACTERS_DB
world_db = $CONFIG_DETECT_CURRENT_WORLD_DB
logs_db = $CONFIG_DETECT_CURRENT_LOGS_DB

[server]
auth_service = $CONFIG_DETECT_CURRENT_AUTH_SERVICE
world_service = $CONFIG_DETECT_CURRENT_WORLD_SERVICE
install_root = $CONFIG_DETECT_CURRENT_ROOT
console_enabled = false

[backup]
enabled = true
backup_dir = $CONFIG_DETECT_CURRENT_BACKUP_DIR
retention_days = 7

[logging]
file = /var/log/vmangos-manager.log
level = info
EOF
}

config_detect_emit_candidate_text() {
    local index="$1"
    local selected_root="$2"
    local proposed_config
    local item

    proposed_config=$(config_detect_proposed_config)

    echo ""
    if [[ "$CONFIG_DETECT_CURRENT_ROOT" == "$selected_root" && -n "$selected_root" ]]; then
        echo "Candidate $index [selected]"
    else
        echo "Candidate $index"
    fi
    echo "  Install root: $CONFIG_DETECT_CURRENT_ROOT"
    echo "  Confidence: $CONFIG_DETECT_CURRENT_LEVEL ($CONFIG_DETECT_CURRENT_SCORE)"
    echo "  Services: auth=$CONFIG_DETECT_CURRENT_AUTH_SERVICE, world=$CONFIG_DETECT_CURRENT_WORLD_SERVICE"
    echo "  Database endpoint: $CONFIG_DETECT_CURRENT_DB_HOST:$CONFIG_DETECT_CURRENT_DB_PORT user=$CONFIG_DETECT_CURRENT_DB_USER"
    echo "  Databases: auth=$CONFIG_DETECT_CURRENT_AUTH_DB, characters=$CONFIG_DETECT_CURRENT_CHARACTERS_DB, world=$CONFIG_DETECT_CURRENT_WORLD_DB, logs=$CONFIG_DETECT_CURRENT_LOGS_DB"
    echo "  Proposed config path: $CONFIG_DETECT_CURRENT_CONFIG_PATH"

    if [[ ${#CONFIG_DETECT_CURRENT_SIGNALS[@]} -gt 0 ]]; then
        echo "  Signals:"
        for item in "${CONFIG_DETECT_CURRENT_SIGNALS[@]}"; do
            echo "    - $item"
        done
    fi

    if [[ ${#CONFIG_DETECT_CURRENT_ASSUMPTIONS[@]} -gt 0 ]]; then
        echo "  Assumptions:"
        for item in "${CONFIG_DETECT_CURRENT_ASSUMPTIONS[@]}"; do
            echo "    - $item"
        done
    fi

    if [[ ${#CONFIG_DETECT_CURRENT_ISSUES[@]} -gt 0 ]]; then
        echo "  Issues:"
        for item in "${CONFIG_DETECT_CURRENT_ISSUES[@]}"; do
            echo "    - $item"
        done
    fi

    echo "  Proposed manager.conf:"
    while IFS= read -r item; do
        echo "    $item"
    done <<< "$proposed_config"
}

config_detect_emit_text() {
    local selected_root="$1"
    local ambiguous="$2"
    local index=0

    echo ""
    echo "=== Config Detection ==="
    echo "Candidates found: ${#CONFIG_DETECT_ROOTS[@]}"
    echo "Ambiguous selection: $ambiguous"
    if [[ -n "$selected_root" ]]; then
        echo "Selected install root: $selected_root"
    else
        echo "Selected install root: none"
    fi

    for root in "${CONFIG_DETECT_ROOTS[@]}"; do
        index=$((index + 1))
        config_detect_analyze_candidate "$root"
        config_detect_emit_candidate_text "$index" "$selected_root"
    done
}

config_detect_emit_json() {
    local selected_root="$1"
    local ambiguous="$2"
    local multiple_candidates=false
    local candidates_json=""
    local proposed_config escaped_root proposed_config_escaped
    local signals_json assumptions_json issues_json

    if [[ ${#CONFIG_DETECT_ROOTS[@]} -gt 1 ]]; then
        multiple_candidates=true
    fi

    local root
    for root in "${CONFIG_DETECT_ROOTS[@]}"; do
        config_detect_analyze_candidate "$root"
        proposed_config=$(config_detect_proposed_config)
        proposed_config_escaped=$(json_escape "$proposed_config")
        escaped_root=$(json_escape "$CONFIG_DETECT_CURRENT_ROOT")
        if [[ ${#CONFIG_DETECT_CURRENT_SIGNALS[@]} -gt 0 ]]; then
            signals_json=$(config_json_array "${CONFIG_DETECT_CURRENT_SIGNALS[@]}")
        else
            signals_json='[]'
        fi
        if [[ ${#CONFIG_DETECT_CURRENT_ASSUMPTIONS[@]} -gt 0 ]]; then
            assumptions_json=$(config_json_array "${CONFIG_DETECT_CURRENT_ASSUMPTIONS[@]}")
        else
            assumptions_json='[]'
        fi
        if [[ ${#CONFIG_DETECT_CURRENT_ISSUES[@]} -gt 0 ]]; then
            issues_json=$(config_json_array "${CONFIG_DETECT_CURRENT_ISSUES[@]}")
        else
            issues_json='[]'
        fi

        candidates_json+=$(cat << EOF
{
"install_root":"$escaped_root",
"confidence":{"level":"$CONFIG_DETECT_CURRENT_LEVEL","score":$CONFIG_DETECT_CURRENT_SCORE},
"services":{"auth":"$(json_escape "$CONFIG_DETECT_CURRENT_AUTH_SERVICE")","world":"$(json_escape "$CONFIG_DETECT_CURRENT_WORLD_SERVICE")"},
"database":{"host":"$(json_escape "$CONFIG_DETECT_CURRENT_DB_HOST")","port":"$(json_escape "$CONFIG_DETECT_CURRENT_DB_PORT")","user":"$(json_escape "$CONFIG_DETECT_CURRENT_DB_USER")","auth_db":"$(json_escape "$CONFIG_DETECT_CURRENT_AUTH_DB")","characters_db":"$(json_escape "$CONFIG_DETECT_CURRENT_CHARACTERS_DB")","world_db":"$(json_escape "$CONFIG_DETECT_CURRENT_WORLD_DB")","logs_db":"$(json_escape "$CONFIG_DETECT_CURRENT_LOGS_DB")"},
"proposed_config_path":"$(json_escape "$CONFIG_DETECT_CURRENT_CONFIG_PATH")",
"password_file":"$(json_escape "$CONFIG_DETECT_CURRENT_PASSWORD_FILE")",
"backup_dir":"$(json_escape "$CONFIG_DETECT_CURRENT_BACKUP_DIR")",
"signals":$signals_json,
"assumptions":$assumptions_json,
"issues":$issues_json,
"proposed_config":"$proposed_config_escaped"
},
EOF
)
    done

    if [[ -n "$selected_root" ]]; then
        selected_root="\"$(json_escape "$selected_root")\""
    else
        selected_root="null"
    fi

    json_output true "{
\"candidate_count\":${#CONFIG_DETECT_ROOTS[@]},
\"multiple_candidates\":$multiple_candidates,
\"ambiguous\":$ambiguous,
\"selected_install_root\":$selected_root,
\"candidates\":[${candidates_json%,}]
}"
}

config_detect() {
    local output_format="${1:-text}"
    local root selected_root="" ambiguous=false
    local best_score=-999
    local best_count=0

    config_detect_reset_state
    config_detect_collect_systemd_hints
    config_detect_collect_filesystem_roots

    if [[ ${#CONFIG_DETECT_ROOTS[@]} -eq 0 ]]; then
        if [[ "$output_format" == "json" ]]; then
            json_output false "null" "DETECT_NOT_FOUND" "No VMANGOS install candidates were detected" "Run on a VMANGOS host or set VMANGOS_DETECT_SEARCH_ROOTS for targeted discovery"
        else
            log_error "No VMANGOS install candidates were detected"
            log_info "Run on a VMANGOS host or set VMANGOS_DETECT_SEARCH_ROOTS for targeted discovery"
        fi
        return 1
    fi

    for root in "${CONFIG_DETECT_ROOTS[@]}"; do
        config_detect_analyze_candidate "$root"
        if [[ "$CONFIG_DETECT_CURRENT_SCORE" -gt "$best_score" ]]; then
            best_score="$CONFIG_DETECT_CURRENT_SCORE"
            selected_root="$root"
            best_count=1
        elif [[ "$CONFIG_DETECT_CURRENT_SCORE" -eq "$best_score" ]]; then
            best_count=$((best_count + 1))
        fi
    done

    if [[ "$best_count" -gt 1 ]]; then
        ambiguous=true
        selected_root=""
    fi

    if [[ "$output_format" == "json" ]]; then
        config_detect_emit_json "$selected_root" "$ambiguous"
    else
        config_detect_emit_text "$selected_root" "$ambiguous"
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
