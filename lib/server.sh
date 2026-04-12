#!/bin/bash
# =============================================================================
# VMANGOS Manager - Server Control Library
# =============================================================================
# Provides: start, stop, restart, status for auth and world services
# 
# Error Handling Convention:
#   - Functions return 0 on success, non-zero on failure
#   - Functions should NOT call error_exit (let caller decide)
# =============================================================================

# Service Constants
readonly SERVICE_AUTH="auth"
readonly SERVICE_WORLD="world"
# shellcheck disable=SC2034
readonly SERVICES="$SERVICE_AUTH $SERVICE_WORLD"

# Timeout settings
readonly SYSTEMCTL_TIMEOUT="${SYSTEMCTL_TIMEOUT:-60}"

# =============================================================================
# Service Control Functions
# =============================================================================

# Start a service
# Args: $1=service_name (auth|world)
# Returns: 0 on success, 1 on failure
server_start() {
    local service="$1"
    local lock_file=""
    
    log_info "Starting $service service..."
    
    # Validate service name
    if [[ "$service" != "$SERVICE_AUTH" && "$service" != "$SERVICE_WORLD" ]]; then
        log_error "Unknown service: $service"
        return 1
    fi
    
    # Acquire lock
    if ! lock_file=$(lock_acquire "server_${service}" 10); then
        log_error "Could not acquire lock for $service"
        return 1
    fi
    
    # Check if already running
    if server_is_running "$service"; then
        log_warn "$service is already running"
        lock_release "$lock_file"
        return 0
    fi
    
    # Start the service with timeout
    local start_result=0
    if timeout "$SYSTEMCTL_TIMEOUT" systemctl start "${service}.service"; then
        log_info "$service service start command succeeded"
        
        # Wait and verify
        sleep 2
        if server_is_running "$service"; then
            log_info "$service is running"
        else
            log_error "$service failed to start (process not found)"
            start_result=1
        fi
    else
        log_error "Failed to start $service service (systemctl returned error)"
        start_result=1
    fi
    
    lock_release "$lock_file"
    return $start_result
}

# Stop a service
# Args: $1=service_name (auth|world)
# Returns: 0 on success, 1 on failure
server_stop() {
    local service="$1"
    local lock_file=""
    
    log_info "Stopping $service service..."
    
    # Validate service name
    if [[ "$service" != "$SERVICE_AUTH" && "$service" != "$SERVICE_WORLD" ]]; then
        log_error "Unknown service: $service"
        return 1
    fi
    
    # Acquire lock
    if ! lock_file=$(lock_acquire "server_${service}" 10); then
        log_error "Could not acquire lock for $service"
        return 1
    fi
    
    # Check if running
    if ! server_is_running "$service"; then
        log_warn "$service is not running"
        lock_release "$lock_file"
        return 0
    fi
    
    # Stop the service with timeout
    local stop_result=0
    if timeout "$SYSTEMCTL_TIMEOUT" systemctl stop "${service}.service"; then
        log_info "$service stopped successfully"
    else
        log_error "Failed to stop $service service"
        stop_result=1
    fi
    
    lock_release "$lock_file"
    return $stop_result
}

# Restart a service
# Args: $1=service_name (auth|world)
# Returns: 0 on success, 1 on failure
server_restart() {
    local service="$1"
    
    log_info "Restarting $service service..."
    
    # Stop first
    if ! server_stop "$service"; then
        log_error "Failed to stop $service, aborting restart"
        return 1
    fi
    
    # Wait between stop and start
    sleep 2
    
    # Then start
    if ! server_start "$service"; then
        log_error "Failed to start $service after stop"
        return 1
    fi
    
    return 0
}

# Get service status
# Args: $1=service_name (auth|world), $2=format (text|json, default: text)
# Returns: 0 on success, 1 on failure
# Outputs: status information
server_status() {
    local service="$1"
    local format="${2:-text}"
    
    # Validate service name
    if [[ "$service" != "$SERVICE_AUTH" && "$service" != "$SERVICE_WORLD" ]]; then
        log_error "Unknown service: $service"
        return 1
    fi
    
    local is_active is_enabled uptime memory
    
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
        # Build JSON safely
        local active_bool enabled_bool
        [[ "$is_active" == "active" ]] && active_bool="true" || active_bool="false"
        [[ "$is_enabled" == "enabled" ]] && enabled_bool="true" || enabled_bool="false"
        
        local data
        data=$(printf '{"service":"%s","active":%s,"enabled":%s,"uptime":"%s","memory_bytes":%s}' \
            "$service" "$active_bool" "$enabled_bool" "$uptime" "$memory")
        json_output true "$data"
    else
        echo "Service: $service"
        echo "Status: $is_active"
        echo "Autostart: $is_enabled"
        echo "Uptime: $uptime"
        if [[ "$memory" != "0" && "$memory" != "n/a" && "$memory" -gt 0 ]]; then
            # Safe memory calculation
            local mem_mb
            mem_mb=$((memory / 1024 / 1024))
            echo "Memory: ${mem_mb} MB"
        fi
    fi
    
    return 0
}

# =============================================================================
# Service Query Functions
# =============================================================================

# Check if service is running
# Args: $1=service_name
# Returns: 0 if running, 1 if not
server_is_running() {
    local service="$1"
    systemctl is-active --quiet "${service}.service" 2>/dev/null
}

# Get service PID
# Args: $1=service_name
# Outputs: PID or empty string
server_get_pid() {
    local service="$1"
    systemctl show "${service}.service" --property=MainPID --value 2>/dev/null
}

# =============================================================================
# Bulk Operations
# =============================================================================

# Start all services
# Returns: 0 on success, 1 on failure
server_start_all() {
    log_info "Starting all VMANGOS services..."
    
    local result=0
    
    # Start auth first (world depends on it)
    if ! server_start "$SERVICE_AUTH"; then
        result=1
    fi
    
    sleep 2
    
    if ! server_start "$SERVICE_WORLD"; then
        result=1
    fi
    
    if [[ $result -eq 0 ]]; then
        log_info "All services started successfully"
    else
        log_error "Some services failed to start"
    fi
    
    return $result
}

# Stop all services
# Returns: 0 on success, 1 on failure
server_stop_all() {
    log_info "Stopping all VMANGOS services..."
    
    local result=0
    
    # Stop world first, then auth
    if ! server_stop "$SERVICE_WORLD"; then
        result=1
    fi
    
    sleep 2
    
    if ! server_stop "$SERVICE_AUTH"; then
        result=1
    fi
    
    if [[ $result -eq 0 ]]; then
        log_info "All services stopped successfully"
    else
        log_error "Some services failed to stop"
    fi
    
    return $result
}

# Restart all services
# Returns: 0 on success, 1 on failure
server_restart_all() {
    log_info "Restarting all VMANGOS services..."
    
    if ! server_stop_all; then
        log_error "Failed to stop services, aborting restart"
        return 1
    fi
    
    sleep 3
    
    if ! server_start_all; then
        log_error "Failed to start services after stop"
        return 1
    fi
    
    return 0
}

# Get status of all services
# Args: $1=format (text|json, default: text)
# Returns: 0 on success
server_status_all() {
    local format="${1:-text}"
    
    if [[ "$format" == "json" ]]; then
        # Get individual statuses
        local auth_status world_status
        auth_status=$(server_status "$SERVICE_AUTH" json)
        world_status=$(server_status "$SERVICE_WORLD" json)
        
        # Combine into single JSON response
        local combined_data
        combined_data=$(printf '{"services":{"auth":%s,"world":%s}}' \
            "$(echo "$auth_status" | sed 's/.*"data":\({[^}]*}\).*/\1/')" \
            "$(echo "$world_status" | sed 's/.*"data":\({[^}]*}\).*/\1/')")
        
        json_output true "$combined_data"
    else
        echo "=== VMANGOS Service Status ==="
        echo ""
        server_status "$SERVICE_AUTH"
        echo ""
        server_status "$SERVICE_WORLD"
    fi
    
    return 0
}

# =============================================================================
# Service Health Check
# =============================================================================

# Check if service is healthy
# Args: $1=service_name, $2=max_wait_seconds (default: 30)
# Returns: 0 if healthy, 1 if not
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

# Show service logs
# Args: $1=service_name, $2=lines (default: 50), $3=follow (true|false, default: false)
# Returns: exit code from journalctl
server_logs() {
    local service="$1"
    local lines="${2:-50}"
    local follow="${3:-false}"
    
    local cmd=("journalctl" "-u" "${service}.service" "-n" "$lines")
    if [[ "$follow" == "true" ]]; then
        cmd+=("-f")
    fi
    
    "${cmd[@]}"
}
