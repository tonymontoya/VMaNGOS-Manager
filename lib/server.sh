#!/bin/bash
# =============================================================================
# VMANGOS Manager - Server Control Library
# =============================================================================
# Provides: start, stop, restart, status for auth and world services
# =============================================================================

# Note: common.sh and config.sh should be sourced before this file

# =============================================================================
# Service Constants
# =============================================================================

readonly SERVICE_AUTH="auth"
readonly SERVICE_WORLD="world"
# shellcheck disable=SC2034
readonly SERVICES="$SERVICE_AUTH $SERVICE_WORLD"

# =============================================================================
# Service Control Functions
# =============================================================================

server_start() {
    local service="$1"
    local lock_file
    
    log_info "Starting $service service..."
    
    # Acquire lock
    lock_file=$(lock_acquire "server_${service}" 10)
    
    # Check if already running
    if server_is_running "$service"; then
        log_warn "$service is already running"
        lock_release "$lock_file"
        return 0
    fi
    
    # Start the service
    if systemctl start "${service}.service"; then
        log_info "$service started successfully"
        
        # Wait a moment and verify
        sleep 2
        if server_is_running "$service"; then
            lock_release "$lock_file"
            return 0
        else
            lock_release "$lock_file"
            error_exit "$service failed to start (process not found)"
        fi
    else
        lock_release "$lock_file"
        error_exit "Failed to start $service service"
    fi
}

server_stop() {
    local service="$1"
    local lock_file
    
    log_info "Stopping $service service..."
    
    # Acquire lock
    lock_file=$(lock_acquire "server_${service}" 10)
    
    # Check if running
    if ! server_is_running "$service"; then
        log_warn "$service is not running"
        lock_release "$lock_file"
        return 0
    fi
    
    # Stop the service
    if systemctl stop "${service}.service"; then
        log_info "$service stopped successfully"
        lock_release "$lock_file"
        return 0
    else
        lock_release "$lock_file"
        error_exit "Failed to stop $service service"
    fi
}

server_restart() {
    local service="$1"
    
    log_info "Restarting $service service..."
    
    # Stop then start
    server_stop "$service"
    sleep 2
    server_start "$service"
}

server_status() {
    local service="$1"
    local format="${2:-text}"  # text or json
    
    local is_active
    local is_enabled
    local uptime
    local memory
    
    # Get systemd status
    if systemctl is-active --quiet "${service}.service" 2>/dev/null; then
        is_active="active"
    else
        is_active="inactive"
    fi
    
    if systemctl is-enabled --quiet "${service}.service" 2>/dev/null; then
        is_enabled="enabled"
    else
        is_enabled="disabled"
    fi
    
    # Get process info if running
    if [[ "$is_active" == "active" ]]; then
        uptime=$(systemctl show "${service}.service" --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
        memory=$(systemctl show "${service}.service" --property=MemoryCurrent --value 2>/dev/null || echo "0")
        [[ "$memory" == "[not set]" ]] && memory="0"
    else
        uptime="n/a"
        memory="0"
    fi
    
    # Output in requested format
    if [[ "$format" == "json" ]]; then
        local data
        data=$(cat <<EOF
{
  "service": "${service}",
  "active": $(if [[ "$is_active" == "active" ]]; then echo "true"; else echo "false"; fi),
  "enabled": $(if [[ "$is_enabled" == "enabled" ]]; then echo "true"; else echo "false"; fi),
  "uptime": "${uptime}",
  "memory_bytes": ${memory}
}
EOF
)
        json_output true "$data"
    else
        echo "Service: $service"
        echo "Status: $is_active"
        echo "Autostart: $is_enabled"
        echo "Uptime: $uptime"
        if [[ "$memory" != "0" && "$memory" != "n/a" ]]; then
            echo "Memory: $((memory / 1024 / 1024)) MB"
        fi
    fi
}

# =============================================================================
# Service Query Functions
# =============================================================================

server_is_running() {
    local service="$1"
    systemctl is-active --quiet "${service}.service" 2>/dev/null
}

server_get_pid() {
    local service="$1"
    systemctl show "${service}.service" --property=MainPID --value 2>/dev/null
}

# =============================================================================
# Bulk Operations
# =============================================================================

server_start_all() {
    log_info "Starting all VMANGOS services..."
    
    # Start auth first (world depends on it)
    server_start "$SERVICE_AUTH"
    sleep 2
    server_start "$SERVICE_WORLD"
    
    log_info "All services started"
}

server_stop_all() {
    log_info "Stopping all VMANGOS services..."
    
    # Stop world first, then auth
    server_stop "$SERVICE_WORLD"
    sleep 2
    server_stop "$SERVICE_AUTH"
    
    log_info "All services stopped"
}

server_restart_all() {
    log_info "Restarting all VMANGOS services..."
    server_stop_all
    sleep 3
    server_start_all
}

server_status_all() {
    local format="${1:-text}"
    
    if [[ "$format" == "json" ]]; then
        local auth_status
        auth_status=$(server_status "$SERVICE_AUTH" json)
        local world_status
        world_status=$(server_status "$SERVICE_WORLD" json)
        
        # Extract data objects and combine
        local auth_data
        auth_data=$(echo "$auth_status" | grep -o '"data":{[^}]*}')
        local world_data
        world_data=$(echo "$world_status" | grep -o '"data":{[^}]*}')
        
        local combined_data
        combined_data=$(cat <<EOF
{
  "services": {
    "auth": ${auth_data:7},
    "world": ${world_data:7}
  }
}
EOF
)
        json_output true "$combined_data"
    else
        echo "=== VMANGOS Service Status ==="
        echo ""
        server_status "$SERVICE_AUTH"
        echo ""
        server_status "$SERVICE_WORLD"
    fi
}

# =============================================================================
# Service Health Check
# =============================================================================

server_health_check() {
    local service="$1"
    local max_wait="${2:-30}"
    
    log_info "Health check for $service (max ${max_wait}s)..."
    
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if server_is_running "$service"; then
            log_info "$service is healthy"
            return 0
        fi
        sleep 1
        ((waited++))
    done
    
    log_error "$service failed health check after ${max_wait}s"
    return 1
}

# =============================================================================
# Log Access
# =============================================================================

server_logs() {
    local service="$1"
    local lines="${2:-50}"
    local follow="${3:-false}"
    
    local cmd="journalctl -u ${service}.service -n ${lines}"
    if [[ "$follow" == "true" ]]; then
        cmd="${cmd} -f"
    fi
    
    $cmd
}
