#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Server control module for VMANGOS Manager
# Start, stop, restart, and status of auth and world services
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ============================================================================
# CONFIGURATION (Loaded from config file, not hardcoded)
# ============================================================================

SERVER_CONFIG_LOADED=""
AUTH_SERVICE=""
WORLD_SERVICE=""
INSTALL_ROOT=""
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
AUTH_DB=""
SERVER_CRASH_LOOP_THRESHOLD="${SERVER_CRASH_LOOP_THRESHOLD:-3}"

# ============================================================================
# CONFIG LOADING
# ============================================================================

server_load_config() {
    [[ "$SERVER_CONFIG_LOADED" == "1" ]] && return 0
    
    config_load "$CONFIG_FILE" || {
        log_error "Failed to load configuration"
        return 1
    }
    
    AUTH_SERVICE="${CONFIG_SERVER_AUTH_SERVICE:-auth}"
    WORLD_SERVICE="${CONFIG_SERVER_WORLD_SERVICE:-world}"
    INSTALL_ROOT="${CONFIG_SERVER_INSTALL_ROOT:-/opt/mangos}"
    DB_HOST="${CONFIG_DATABASE_HOST:-127.0.0.1}"
    DB_PORT="${CONFIG_DATABASE_PORT:-3306}"
    DB_USER="${CONFIG_DATABASE_USER:-mangos}"
    DB_PASS="${CONFIG_DATABASE_PASSWORD:-}"
    AUTH_DB="${CONFIG_DATABASE_AUTH_DB:-auth}"
    
    SERVER_CONFIG_LOADED="1"
    log_debug "Server configuration loaded"
}

# ============================================================================
# DATABASE UTILITIES (Config-driven credentials)
# ============================================================================

db_check_connection() {
    server_mysql_query "$AUTH_DB" "SELECT 1" >/dev/null
}

server_mysql_query() {
    local database="$1"
    local query="$2"

    if [[ -n "$DB_PASS" ]]; then
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -N -B -e "$query" "$database" 2>/dev/null
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -N -B -e "$query" "$database" 2>/dev/null
    fi
}

get_online_player_count_result() {
    local count

    count=$(server_mysql_query "$AUTH_DB" "SELECT COUNT(*) FROM ${AUTH_DB}.account WHERE online = 1" || true)
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        printf '%s|auth.account.online\n' "$count"
        return 0
    fi

    local characters_db="${CONFIG_DATABASE_CHARACTERS_DB:-characters}"
    count=$(server_mysql_query "$characters_db" "SELECT COUNT(*) FROM ${characters_db}.characters WHERE online = 1" || true)
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        printf '%s|characters.characters.online\n' "$count"
        return 0
    fi

    printf '0|unavailable\n'
    return 1
}

get_online_player_count() {
    local result
    result=$(get_online_player_count_result || true)
    printf '%s\n' "${result%%|*}"
}

server_validate_positive_integer() {
    local value="${1:-}"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

server_validate_timeout() {
    server_validate_positive_integer "$1"
}

server_wait_for_active() {
    local service="$1"
    local timeout="$2"
    local elapsed=0

    while [[ "$elapsed" -lt "$timeout" ]]; do
        if service_active "$service"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    service_active "$service"
}

server_wait_for_inactive() {
    local service="$1"
    local timeout="$2"
    local elapsed=0

    while [[ "$elapsed" -lt "$timeout" ]]; do
        if ! service_active "$service"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    ! service_active "$service"
}

server_kill_service() {
    local service="$1"
    local signal="$2"
    systemctl kill -s "$signal" "$service" 2>/dev/null || true
}

server_get_systemctl_property() {
    local service="$1"
    local property="$2"
    systemctl show -p "$property" "$service" 2>/dev/null | cut -d= -f2-
}

server_get_restart_count_1h() {
    local service="$1"
    local count

    count=$(journalctl -u "$service" --since "1 hour ago" --no-pager 2>/dev/null | \
        awk '/Scheduled restart job/ {count++} END {print count+0}' || true)

    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "$count"
}

server_is_crash_loop_detected() {
    local service="$1"
    local restart_count

    restart_count=$(server_get_restart_count_1h "$service")
    [[ "$restart_count" =~ ^[0-9]+$ ]] || restart_count=0
    [[ "$restart_count" -ge "$SERVER_CRASH_LOOP_THRESHOLD" ]]
}

server_verify_running_health() {
    local timeout="$1"

    if ! server_wait_for_active "$AUTH_SERVICE" 10; then
        log_error "Auth service failed to reach active state within 10s"
        return 1
    fi

    if ! server_wait_for_active "$WORLD_SERVICE" "$timeout"; then
        log_error "World service failed to reach active state within ${timeout}s"
        return 1
    fi

    # Give systemd a brief moment to settle so a fast crash is visible.
    sleep 2

    if ! service_active "$AUTH_SERVICE"; then
        log_error "Auth service is not active after start"
        return 1
    fi

    if ! service_active "$WORLD_SERVICE"; then
        log_error "World service is not active after start"
        return 1
    fi

    if ! db_check_connection; then
        log_error "Database connectivity check failed after start"
        return 1
    fi

    if server_is_crash_loop_detected "$AUTH_SERVICE"; then
        log_error "Auth service shows crash-loop behavior in recent systemd history"
        return 1
    fi

    if server_is_crash_loop_detected "$WORLD_SERVICE"; then
        log_error "World service shows crash-loop behavior in recent systemd history"
        return 1
    fi

    return 0
}

# ============================================================================
# PRE-FLIGHT CHECKS (Config-driven paths)
# ============================================================================

preflight_check() {
    local error_count=0
    
    log_info "Running pre-flight checks..."
    
    server_load_config || return 1
    
    # Check database connectivity
    if ! db_check_connection; then
        log_error "Database connectivity check failed"
        error_count=$((error_count + 1))
    else
        log_info "✓ Database connectivity OK"
    fi
    
    # Check disk space (using config-driven install root)
    local available
    available=$(df "$INSTALL_ROOT" | awk 'NR==2 {print $4}')
    if [[ "$available" -lt 512000 ]]; then
        log_error "Insufficient disk space: ${available}KB available, need 500MB"
        error_count=$((error_count + 1))
    else
        log_info "✓ Disk space OK"
    fi
    
    # Check config files exist (config-driven paths)
    if [[ ! -f "$INSTALL_ROOT/run/etc/mangosd.conf" ]]; then
        log_error "mangosd.conf not found at $INSTALL_ROOT/run/etc/mangosd.conf"
        error_count=$((error_count + 1))
    fi
    
    if [[ ! -f "$INSTALL_ROOT/run/etc/realmd.conf" ]]; then
        log_error "realmd.conf not found at $INSTALL_ROOT/run/etc/realmd.conf"
        error_count=$((error_count + 1))
    fi
    
    return "$error_count"
}

# ============================================================================
# SERVER START
# ============================================================================

server_start() {
    local wait="${1:-false}"
    local timeout="${2:-60}"
    
    log_section "Starting VMANGOS Server"
    
    server_load_config || error_exit "Failed to load configuration" "$E_CONFIG_ERROR"

    if ! server_validate_timeout "$timeout"; then
        error_exit "Invalid start timeout: $timeout" "$E_INVALID_ARGS"
    fi
    
    if ! preflight_check; then
        error_exit "Pre-flight checks failed" "$E_SERVICE_ERROR"
    fi
    
    # Start auth service first
    log_info "Starting auth service..."
    if service_active "$AUTH_SERVICE"; then
        log_info "Auth service already running"
    else
        if ! service_start "$AUTH_SERVICE"; then
            error_exit "Failed to start auth service" "$E_SERVICE_ERROR"
        fi
    fi
    
    # Start world service
    log_info "Starting world service..."
    if service_active "$WORLD_SERVICE"; then
        log_info "World service already running"
    else
        if ! service_start "$WORLD_SERVICE"; then
            error_exit "Failed to start world service" "$E_SERVICE_ERROR"
        fi
    fi

    if [[ "$wait" == "true" ]]; then
        log_info "Waiting for services to become healthy..."
        if ! server_verify_running_health "$timeout"; then
            error_exit "Post-start health verification failed" "$E_SERVICE_ERROR"
        fi
        log_info "✓ Server started successfully"
        return 0
    fi

    log_info "✓ Start commands issued successfully"
}

# ============================================================================
# SERVER STOP
# ============================================================================

server_stop() {
    local graceful="${1:-true}"
    local force="${2:-false}"
    local timeout="${3:-30}"
    
    log_section "Stopping VMANGOS Server"
    
    server_load_config || error_exit "Failed to load configuration" "$E_CONFIG_ERROR"

    if ! server_validate_timeout "$timeout"; then
        error_exit "Invalid stop timeout: $timeout" "$E_INVALID_ARGS"
    fi
    
    if [[ "$force" == "true" ]]; then
        graceful="false"
    fi
    
    # Stop world service first
    if service_active "$WORLD_SERVICE"; then
        log_info "Stopping world service..."
        
        if [[ "$graceful" == "true" ]]; then
            if ! systemctl stop "$WORLD_SERVICE"; then
                error_exit "Failed to request graceful stop for world service" "$E_SERVICE_ERROR"
            fi

            if ! server_wait_for_inactive "$WORLD_SERVICE" "$timeout"; then
                if [[ "$force" == "true" ]]; then
                    log_warn "World service did not stop within ${timeout}s, forcing..."
                    server_kill_service "$WORLD_SERVICE" SIGTERM
                    sleep 2
                    if service_active "$WORLD_SERVICE"; then
                        server_kill_service "$WORLD_SERVICE" SIGKILL
                        sleep 1
                    fi
                    if service_active "$WORLD_SERVICE"; then
                        error_exit "World service remained active after forced termination" "$E_SERVICE_ERROR"
                    fi
                else
                    error_exit "World service did not stop within ${timeout}s" "$E_SERVICE_ERROR"
                fi
            fi
        else
            systemctl stop "$WORLD_SERVICE" || true
            sleep 1
            if service_active "$WORLD_SERVICE"; then
                log_warn "Force killing world service..."
                server_kill_service "$WORLD_SERVICE" SIGKILL
                sleep 1
            fi
        fi
    else
        log_info "World service not running"
    fi
    
    # Stop auth service
    if service_active "$AUTH_SERVICE"; then
        log_info "Stopping auth service..."
        if [[ "$graceful" == "true" ]]; then
            if ! systemctl stop "$AUTH_SERVICE"; then
                error_exit "Failed to stop auth service" "$E_SERVICE_ERROR"
            fi

            if ! server_wait_for_inactive "$AUTH_SERVICE" "$timeout"; then
                if [[ "$force" == "true" ]]; then
                    log_warn "Auth service did not stop within ${timeout}s, forcing..."
                    server_kill_service "$AUTH_SERVICE" SIGTERM
                    sleep 2
                    if service_active "$AUTH_SERVICE"; then
                        server_kill_service "$AUTH_SERVICE" SIGKILL
                        sleep 1
                    fi
                    if service_active "$AUTH_SERVICE"; then
                        error_exit "Auth service remained active after forced termination" "$E_SERVICE_ERROR"
                    fi
                else
                    error_exit "Auth service did not stop within ${timeout}s" "$E_SERVICE_ERROR"
                fi
            fi
        else
            if ! systemctl stop "$AUTH_SERVICE"; then
                error_exit "Failed to stop auth service" "$E_SERVICE_ERROR"
            fi
            sleep 1
            if service_active "$AUTH_SERVICE"; then
                log_warn "Force killing auth service..."
                server_kill_service "$AUTH_SERVICE" SIGKILL
                sleep 1
            fi
        fi
    else
        log_info "Auth service not running"
    fi
    
    log_info "✓ Server stopped"
}

# ============================================================================
# SERVER RESTART
# ============================================================================

server_restart() {
    local timeout="${1:-60}"

    log_section "Restarting VMANGOS Server"

    if ! server_validate_timeout "$timeout"; then
        error_exit "Invalid restart timeout: $timeout" "$E_INVALID_ARGS"
    fi
    
    server_stop true false "$timeout"
    sleep 2
    server_start true "$timeout"
}

# ============================================================================
# SERVER STATUS (TEXT)
# ============================================================================

status_set_var() {
    local name="$1"
    local value="$2"
    printf -v "$name" '%s' "$value"
}

format_uptime_seconds() {
    local total_seconds="${1:-0}"
    local days hours minutes seconds

    if [[ ! "$total_seconds" =~ ^[0-9]+$ ]] || [[ "$total_seconds" -le 0 ]]; then
        printf '0s\n'
        return 0
    fi

    days=$((total_seconds / 86400))
    hours=$(((total_seconds % 86400) / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if [[ "$days" -gt 0 ]]; then
        printf '%sd %sh %sm\n' "$days" "$hours" "$minutes"
    elif [[ "$hours" -gt 0 ]]; then
        printf '%sh %sm\n' "$hours" "$minutes"
    elif [[ "$minutes" -gt 0 ]]; then
        printf '%sm %ss\n' "$minutes" "$seconds"
    else
        printf '%ss\n' "$seconds"
    fi
}

server_collect_service_status() {
    local prefix="$1"
    local service="$2"
    local state pid uptime_seconds uptime_human memory_kb memory_mb cpu_percent running
    local restart_count crash_loop

    state=$(systemctl is-active "$service" 2>/dev/null || true)
    [[ -n "$state" ]] || state="unknown"

    pid=$(systemctl show -p MainPID "$service" 2>/dev/null | cut -d= -f2 || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || pid=0

    running="false"
    uptime_seconds=0
    uptime_human="N/A"
    memory_mb=0
    cpu_percent="0.0"
    restart_count=$(server_get_restart_count_1h "$service")
    [[ "$restart_count" =~ ^[0-9]+$ ]] || restart_count=0
    crash_loop="false"
    if [[ "$restart_count" -ge "$SERVER_CRASH_LOOP_THRESHOLD" ]]; then
        crash_loop="true"
    fi

    if [[ "$state" == "active" && "$pid" -gt 0 ]]; then
        running="true"
        uptime_seconds=$(ps -p "$pid" -o etimes= 2>/dev/null | awk '{print $1}' || true)
        uptime_seconds="${uptime_seconds//[[:space:]]/}"
        [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || uptime_seconds=0
        uptime_human=$(format_uptime_seconds "$uptime_seconds")

        memory_kb=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{print int($1)}' || true)
        memory_kb="${memory_kb//[[:space:]]/}"
        [[ "$memory_kb" =~ ^[0-9]+$ ]] || memory_kb=0
        memory_mb=$((memory_kb / 1024))

        cpu_percent=$(ps -p "$pid" -o %cpu= 2>/dev/null | awk '{print $1}' || true)
        cpu_percent="${cpu_percent//[[:space:]]/}"
        [[ "$cpu_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || cpu_percent="0.0"
    else
        pid=0
    fi

    status_set_var "STATUS_${prefix}_SERVICE" "$service"
    status_set_var "STATUS_${prefix}_STATE" "$state"
    status_set_var "STATUS_${prefix}_RUNNING" "$running"
    status_set_var "STATUS_${prefix}_PID" "$pid"
    status_set_var "STATUS_${prefix}_UPTIME_SECONDS" "$uptime_seconds"
    status_set_var "STATUS_${prefix}_UPTIME_HUMAN" "$uptime_human"
    status_set_var "STATUS_${prefix}_MEMORY_MB" "$memory_mb"
    status_set_var "STATUS_${prefix}_CPU_PERCENT" "$cpu_percent"
    status_set_var "STATUS_${prefix}_RESTART_COUNT_1H" "$restart_count"
    status_set_var "STATUS_${prefix}_CRASH_LOOP" "$crash_loop"
}

server_set_service_health() {
    local prefix="$1"
    local state_var="STATUS_${prefix}_STATE"
    local running_var="STATUS_${prefix}_RUNNING"
    local crash_loop_var="STATUS_${prefix}_CRASH_LOOP"
    local health="stopped"
    local state="${!state_var}"
    local running="${!running_var}"
    local crash_loop="${!crash_loop_var}"

    if [[ "$crash_loop" == "true" ]]; then
        health="crash-loop"
    elif [[ "$running" == "true" ]]; then
        if [[ "$STATUS_DB_OK" == "true" ]]; then
            health="healthy"
        else
            health="degraded"
        fi
    elif [[ "$state" == "failed" ]]; then
        health="failed"
    fi

    status_set_var "STATUS_${prefix}_HEALTH" "$health"
}

server_collect_status() {
    server_load_config || {
        return 1
    }

    STATUS_TIMESTAMP=$(date -Iseconds)

    server_collect_service_status "AUTH" "$AUTH_SERVICE"
    server_collect_service_status "WORLD" "$WORLD_SERVICE"

    local disk_data player_result

    if db_check_connection; then
        STATUS_DB_OK="true"
        STATUS_DB_MESSAGE="ok"
        player_result=$(get_online_player_count_result || true)
        STATUS_PLAYERS_ONLINE="${player_result%%|*}"
        STATUS_PLAYER_COUNT_SOURCE="${player_result##*|}"
        if [[ "$STATUS_PLAYER_COUNT_SOURCE" == "unavailable" ]]; then
            STATUS_PLAYER_COUNT_OK="false"
        else
            STATUS_PLAYER_COUNT_OK="true"
        fi
    else
        STATUS_DB_OK="false"
        STATUS_DB_MESSAGE="unreachable"
        STATUS_PLAYERS_ONLINE="0"
        STATUS_PLAYER_COUNT_SOURCE="unavailable"
        STATUS_PLAYER_COUNT_OK="false"
    fi

    disk_data=$(df -Pk "$INSTALL_ROOT" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $4 "|" $5}' || true)
    if [[ -n "$disk_data" ]]; then
        STATUS_DISK_AVAILABLE_KB="${disk_data%%|*}"
        STATUS_DISK_USED_PERCENT="${disk_data##*|}"
    else
        STATUS_DISK_AVAILABLE_KB="0"
        STATUS_DISK_USED_PERCENT="0"
    fi

    [[ "$STATUS_DISK_AVAILABLE_KB" =~ ^[0-9]+$ ]] || STATUS_DISK_AVAILABLE_KB="0"
    [[ "$STATUS_DISK_USED_PERCENT" =~ ^[0-9]+$ ]] || STATUS_DISK_USED_PERCENT="0"

    if [[ "$STATUS_DISK_AVAILABLE_KB" -ge 512000 ]]; then
        STATUS_DISK_OK="true"
    else
        STATUS_DISK_OK="false"
    fi

    server_set_service_health "AUTH"
    server_set_service_health "WORLD"
}

server_render_service_text() {
    local label="$1"
    local prefix="$2"
    local state_var="STATUS_${prefix}_STATE"
    local running_var="STATUS_${prefix}_RUNNING"
    local pid_var="STATUS_${prefix}_PID"
    local uptime_var="STATUS_${prefix}_UPTIME_HUMAN"
    local memory_var="STATUS_${prefix}_MEMORY_MB"
    local cpu_var="STATUS_${prefix}_CPU_PERCENT"
    local restart_var="STATUS_${prefix}_RESTART_COUNT_1H"
    local health_var="STATUS_${prefix}_HEALTH"
    local state="${!state_var}"
    local running="${!running_var}"
    local pid="${!pid_var}"
    local uptime="${!uptime_var}"
    local memory_mb="${!memory_var}"
    local cpu_percent="${!cpu_var}"
    local restart_count="${!restart_var}"
    local health="${!health_var}"

    if [[ "$running" == "true" ]]; then
        printf '  %-5s %s (PID: %s, uptime: %s, RSS: %s MB, CPU: %s%%, health: %s, restarts/1h: %s)\n' \
            "$label:" "$state" "$pid" "$uptime" "$memory_mb" "$cpu_percent" "$health" "$restart_count"
    else
        printf '  %-5s %s (PID: n/a, health: %s, restarts/1h: %s)\n' "$label:" "$state" "$health" "$restart_count"
    fi
}

server_render_status_text() {
    local disk_free_mb=$((STATUS_DISK_AVAILABLE_KB / 1024))
    local db_label="FAILED"
    local disk_label="LOW"
    local player_label="unavailable"

    if [[ "$STATUS_DB_OK" == "true" ]]; then
        db_label="OK"
    fi

    if [[ "$STATUS_DISK_OK" == "true" ]]; then
        disk_label="OK"
    fi

    if [[ "$STATUS_PLAYER_COUNT_OK" == "true" ]]; then
        player_label="$STATUS_PLAYERS_ONLINE"
    fi

    echo "VMANGOS Server Status"
    echo "Timestamp: $STATUS_TIMESTAMP"
    echo "Install Root: $INSTALL_ROOT"
    echo ""
    echo "Services:"
    server_render_service_text "Auth" "AUTH"
    server_render_service_text "World" "WORLD"
    echo ""
    echo "Checks:"
    echo "  Database: $db_label ($STATUS_DB_MESSAGE)"
    echo "  Disk:     $disk_label ($disk_free_mb MB free, ${STATUS_DISK_USED_PERCENT}% used, path: $INSTALL_ROOT)"
    echo ""
    echo "Players:"
    echo "  Online: $player_label"
    echo "  Source: $STATUS_PLAYER_COUNT_SOURCE"
}

server_status_text() {
    server_collect_status || {
        log_error "Failed to load configuration"
        return 1
    }

    server_render_status_text
}

# ============================================================================
# SERVER STATUS (JSON)
# ============================================================================

server_status_json() {
    server_collect_status || {
        json_output false "null" "CONFIG_ERROR" "Failed to load configuration" "Check config file exists and is readable"
        return 1
    }

    local install_root_escaped auth_service_escaped auth_state_escaped auth_uptime_escaped
    local world_service_escaped world_state_escaped world_uptime_escaped db_message_escaped
    local player_source_escaped

    install_root_escaped=$(json_escape "$INSTALL_ROOT")
    auth_service_escaped=$(json_escape "$STATUS_AUTH_SERVICE")
    auth_state_escaped=$(json_escape "$STATUS_AUTH_STATE")
    auth_uptime_escaped=$(json_escape "$STATUS_AUTH_UPTIME_HUMAN")
    world_service_escaped=$(json_escape "$STATUS_WORLD_SERVICE")
    world_state_escaped=$(json_escape "$STATUS_WORLD_STATE")
    world_uptime_escaped=$(json_escape "$STATUS_WORLD_UPTIME_HUMAN")
    db_message_escaped=$(json_escape "$STATUS_DB_MESSAGE")
    player_source_escaped=$(json_escape "$STATUS_PLAYER_COUNT_SOURCE")

    local data
    data=$(cat <<EOF
{
  "install_root": "$install_root_escaped",
  "services": {
    "auth": {
      "service": "$auth_service_escaped",
      "state": "$auth_state_escaped",
      "running": $STATUS_AUTH_RUNNING,
      "pid": $STATUS_AUTH_PID,
      "uptime_seconds": $STATUS_AUTH_UPTIME_SECONDS,
      "uptime_human": "$auth_uptime_escaped",
      "memory_mb": $STATUS_AUTH_MEMORY_MB,
      "cpu_percent": $STATUS_AUTH_CPU_PERCENT,
      "health": "$(json_escape "$STATUS_AUTH_HEALTH")",
      "restart_count_1h": $STATUS_AUTH_RESTART_COUNT_1H,
      "crash_loop_detected": $STATUS_AUTH_CRASH_LOOP
    },
    "world": {
      "service": "$world_service_escaped",
      "state": "$world_state_escaped",
      "running": $STATUS_WORLD_RUNNING,
      "pid": $STATUS_WORLD_PID,
      "uptime_seconds": $STATUS_WORLD_UPTIME_SECONDS,
      "uptime_human": "$world_uptime_escaped",
      "memory_mb": $STATUS_WORLD_MEMORY_MB,
      "cpu_percent": $STATUS_WORLD_CPU_PERCENT,
      "health": "$(json_escape "$STATUS_WORLD_HEALTH")",
      "restart_count_1h": $STATUS_WORLD_RESTART_COUNT_1H,
      "crash_loop_detected": $STATUS_WORLD_CRASH_LOOP
    }
  },
  "checks": {
    "database_connectivity": {
      "ok": $STATUS_DB_OK,
      "message": "$db_message_escaped"
    },
    "disk_space": {
      "ok": $STATUS_DISK_OK,
      "path": "$install_root_escaped",
      "available_kb": $STATUS_DISK_AVAILABLE_KB,
      "used_percent": $STATUS_DISK_USED_PERCENT
    }
  },
  "players": {
    "online": $STATUS_PLAYERS_ONLINE,
    "query_ok": $STATUS_PLAYER_COUNT_OK,
    "source": "$player_source_escaped"
  }
}
EOF
)

    json_output true "$data"
}

server_validate_interval() {
    server_validate_positive_integer "${1:-}"
}

server_status_watch() {
    local interval="${1:-2}"
    local interactive="false"
    local stop_requested=0
    local iterations=0

    if ! server_validate_interval "$interval"; then
        log_error "Invalid watch interval: $interval"
        return "$E_INVALID_ARGS"
    fi

    [[ -t 1 ]] && interactive="true"

    trap 'stop_requested=1' INT TERM

    if [[ "$interactive" == "true" ]]; then
        printf '\033[?25l'
    fi

    while [[ "$stop_requested" -eq 0 ]]; do
        if [[ "$interactive" == "true" ]]; then
            printf '\033[H\033[2J'
        fi

        echo "VMANGOS Server Status Watch"
        echo "Interval: ${interval}s"
        echo "Press Ctrl+C to stop"
        echo ""

        if server_collect_status; then
            server_render_status_text
        else
            log_error "Failed to load configuration"
            break
        fi

        if [[ -n "${STATUS_WATCH_MAX_ITERATIONS:-}" ]]; then
            iterations=$((iterations + 1))
            if [[ "$iterations" -ge "$STATUS_WATCH_MAX_ITERATIONS" ]]; then
                break
            fi
        fi

        sleep "$interval" || true
        if [[ "$interactive" != "true" ]]; then
            echo ""
        fi
    done

    trap - INT TERM

    if [[ "$interactive" == "true" ]]; then
        printf '\033[?25h'
    fi

    echo "Stopped status watch."
}

# ============================================================================
# UTILITY
# ============================================================================

log_section() {
    echo ""
    log_info "========================================"
    log_info "$1"
    log_info "========================================"
}
