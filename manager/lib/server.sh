#!/usr/bin/env bash
#
# Server control module for VMANGOS Manager
# Start, stop, restart, and status of auth and world services
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

AUTH_SERVICE="${AUTH_SERVICE:-auth}"
WORLD_SERVICE="${WORLD_SERVICE:-world}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

preflight_check() {
    local errors=0
    
    log_info "Running pre-flight checks..."
    
    # Check database connectivity
    if ! db_check_connection; then
        log_error "Database connectivity check failed"
        ((errors++))
    else
        log_info "✓ Database connectivity OK"
    fi
    
    # Check disk space (need at least 500MB free)
    local available
    available=$(df /opt/mangos | awk 'NR==2 {print $4}')
    if [[ "$available" -lt 512000 ]]; then  # 500MB in KB
        log_error "Insufficient disk space: ${available}KB available, need 500MB"
        ((errors++))
    else
        log_info "✓ Disk space OK"
    fi
    
    # Check config files exist
    if [[ ! -f /opt/mangos/run/etc/mangosd.conf ]]; then
        log_error "mangosd.conf not found"
        ((errors++))
    fi
    
    if [[ ! -f /opt/mangos/run/etc/realmd.conf ]]; then
        log_error "realmd.conf not found"
        ((errors++))
    fi
    
    return $errors
}

# ============================================================================
# SERVER START
# ============================================================================

server_start() {
    local wait="${1:-false}"
    local timeout="${2:-60}"
    
    log_section "Starting VMANGOS Server"
    
    # Pre-flight checks
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
        
        if [[ "$wait" == "true" ]]; then
            log_info "Waiting for auth service to be ready..."
            local count=0
            while ! service_active "$AUTH_SERVICE" && [[ $count -lt $timeout ]]; do
                sleep 1
                ((count++))
            done
            
            if ! service_active "$AUTH_SERVICE"; then
                error_exit "Auth service failed to start within ${timeout}s" "$E_SERVICE_ERROR"
            fi
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
        
        if [[ "$wait" == "true" ]]; then
            log_info "Waiting for world service to initialize (this may take 30-60 seconds)..."
            local count=0
            while [[ $count -lt $timeout ]]; do
                sleep 1
                ((count++))
                
                # Check if service is active
                if service_active "$WORLD_SERVICE"; then
                    # Additional check: verify it's not in restart loop
                    sleep 2
                    if service_active "$WORLD_SERVICE"; then
                        log_info "World service is running"
                        break
                    fi
                fi
            done
            
            if ! service_active "$WORLD_SERVICE"; then
                error_exit "World service failed to start within ${timeout}s" "$E_SERVICE_ERROR"
            fi
        fi
    fi
    
    log_info "✓ Server started successfully"
}

# ============================================================================
# SERVER STOP
# ============================================================================

server_stop() {
    local graceful="${1:-true}"
    local force="${2:-false}"
    
    log_section "Stopping VMANGOS Server"
    
    if [[ "$force" == "true" ]]; then
        graceful="false"
    fi
    
    # Stop world service first
    if service_active "$WORLD_SERVICE"; then
        log_info "Stopping world service..."
        
        if [[ "$graceful" == "true" ]]; then
            # Give players time to save
            log_info "Waiting for world service to stop gracefully..."
            if ! systemctl stop "$WORLD_SERVICE"; then
                log_warn "Graceful stop failed, forcing..."
                systemctl kill -s SIGTERM "$WORLD_SERVICE" 2>/dev/null || true
                sleep 5
            fi
        else
            systemctl stop "$WORLD_SERVICE" || true
        fi
        
        # Verify stopped
        if service_active "$WORLD_SERVICE"; then
            if [[ "$force" == "true" ]]; then
                log_warn "Force killing world service..."
                systemctl kill -s SIGKILL "$WORLD_SERVICE" 2>/dev/null || true
                sleep 2
            else
                log_error "World service did not stop"
                return 1
            fi
        fi
    else
        log_info "World service not running"
    fi
    
    # Stop auth service
    if service_active "$AUTH_SERVICE"; then
        log_info "Stopping auth service..."
        systemctl stop "$AUTH_SERVICE" || true
    else
        log_info "Auth service not running"
    fi
    
    log_info "✓ Server stopped"
}

# ============================================================================
# SERVER RESTART
# ============================================================================

server_restart() {
    log_section "Restarting VMANGOS Server"
    
    server_stop true false
    sleep 2
    server_start true 60
}

# ============================================================================
# SERVER STATUS
# ============================================================================

server_status_text() {
    log_section "VMANGOS Server Status"
    
    local auth_status world_status auth_pid world_pid
    
    if service_active "$AUTH_SERVICE"; then
        auth_status="running"
        auth_pid=$(systemctl show -p MainPID "$AUTH_SERVICE" | cut -d= -f2)
    else
        auth_status="stopped"
        auth_pid="N/A"
    fi
    
    if service_active "$WORLD_SERVICE"; then
        world_status="running"
        world_pid=$(systemctl show -p MainPID "$WORLD_SERVICE" | cut -d= -f2)
    else
        world_status="stopped"
        world_pid="N/A"
    fi
    
    echo ""
    echo "Services:"
    echo "  Auth Server:  $auth_status (PID: $auth_pid)"
    echo "  World Server: $world_status (PID: $world_pid)"
    echo ""
    
    # Show resource usage if running
    if [[ "$world_status" == "running" ]]; then
        local mem_usage cpu_usage
        mem_usage=$(ps -p "$world_pid" -o rss= 2>/dev/null | awk '{print $1/1024 " MB"}')
        cpu_usage=$(ps -p "$world_pid" -o %cpu= 2>/dev/null || echo "N/A")
        echo "Resource Usage (World):"
        echo "  Memory: $mem_usage"
        echo "  CPU:    $cpu_usage%"
        echo ""
    fi
}

server_status_json() {
    local auth_status="stopped"
    local world_status="stopped"
    local auth_pid=0
    local world_pid=0
    local auth_mem=0
    local world_mem=0
    local online_players=0
    
    if service_active "$AUTH_SERVICE"; then
        auth_status="running"
        auth_pid=$(systemctl show -p MainPID "$AUTH_SERVICE" | cut -d= -f2)
    fi
    
    if service_active "$WORLD_SERVICE"; then
        world_status="running"
        world_pid=$(systemctl show -p MainPID "$WORLD_SERVICE" | cut -d= -f2)
        world_mem=$(ps -p "$world_pid" -o rss= 2>/dev/null || echo 0)
        world_mem=$((world_mem / 1024))  # Convert to MB
    fi
    
    # Try to get online player count
    if [[ "$world_status" == "running" ]]; then
        online_players=$(mysql -u root -N -B -e "SELECT COUNT(*) FROM auth.account WHERE online = 1" 2>/dev/null || echo 0)
    fi
    
    local data
    data=$(cat <<EOF
{
  "services": {
    "auth": {
      "status": "$auth_status",
      "running": $( [[ "$auth_status" == "running" ]] && echo true || echo false ),
      "pid": $auth_pid
    },
    "world": {
      "status": "$world_status",
      "running": $( [[ "$world_status" == "running" ]] && echo true || echo false ),
      "pid": $world_pid,
      "memory_mb": $world_mem,
      "players_online": $online_players
    }
  }
}
EOF
)
    
    json_output true "$data"
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
