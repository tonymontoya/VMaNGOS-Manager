#!/usr/bin/env bash
#
# Common utilities for VMANGOS Manager
# Shared functions used across all modules
#

set -euo pipefail

# ============================================================================
# GLOBALS (No privileged operations at import time)
# ============================================================================

export CONFIG_FILE="${MANAGER_CONFIG:-/opt/mangos/manager/config/manager.conf}"
LOCK_DIR="/var/run/vmangos-manager"
VERBOSE="${VERBOSE:-0}"

# Exit codes
export E_SUCCESS=0
E_ERROR=1
export E_INVALID_ARGS=2
E_NOT_ROOT=3
E_LOCK_FAILED=4
export E_CONFIG_ERROR=5
export E_SERVICE_ERROR=6

# ============================================================================
# INITIALIZATION (directory creation is lazy; nothing to do at import)
# ============================================================================

# ============================================================================
# LOGGING
# ============================================================================

log_debug() {
    [[ "$VERBOSE" -eq 1 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

cleanup_stack=()

register_cleanup() {
    cleanup_stack+=("$1")
}

run_cleanup() {
    local i
    for ((i = ${#cleanup_stack[@]} - 1; i >= 0; i--)); do
        eval "${cleanup_stack[$i]}" 2>/dev/null || true
    done
}

error_exit() {
    local message="$1"
    local code="${2:-$E_ERROR}"
    # config_load already reported the root cause with guidance; skip the
    # generic follow-on message so the user sees exactly one clear error.
    if [[ "${CONFIG_ERROR_REPORTED:-0}" != "1" ]]; then
        log_error "$message"
    fi
    run_cleanup
    exit "$code"
}

cleanup_on_exit() {
    run_cleanup
}

trap cleanup_on_exit EXIT

# ============================================================================
# VALIDATION
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This command must be run as root" "$E_NOT_ROOT"
    fi
}

# HH:MM (24-hour)
validate_hhmm() {
    [[ "${1:-}" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# Three-letter English day abbreviation
validate_day_name() {
    [[ "${1:-}" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]]
}

validate_positive_int() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

# ============================================================================
# DISK STATISTICS (single df parser family)
# ============================================================================

# Filesystem device of the mount containing <path> (empty on failure)
disk_device() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $1}' || true
}

# "total|used|available|pct" in KB from df -Pk (empty on failure, % stripped)
disk_stats_kb() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $2 "|" $3 "|" $4 "|" $5}' || true
}

# Available KB for the mount containing <path> (0 on failure)
disk_available_kb() {
    local stats
    stats=$(disk_stats_kb "$1")
    if [[ -n "$stats" ]]; then
        printf '%s\n' "$stats" | cut -d'|' -f3
    else
        printf '0\n'
    fi
}

# ============================================================================
# SYSTEMD UNIT INSTALLATION (single elevation strategy: direct write; the
# caller must already be root — see check_root)
# ============================================================================

systemd_service_unit_content() {
    local description="$1"
    local exec_start="$2"

    cat <<EOF
[Unit]
Description=$description
After=network.target

[Service]
Type=oneshot
ExecStart=$exec_start
User=root
StandardOutput=journal
StandardError=journal
EOF
}

systemd_timer_unit_content() {
    local description="$1"
    local on_calendar="$2"

    cat <<EOF
[Unit]
Description=$description

[Timer]
OnCalendar=$on_calendar
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# systemd_install_units <unit_dir> <service_name> <service_content> <timer_name> <timer_content>
systemd_install_units() {
    local unit_dir="$1"
    local service_name="$2"
    local service_content="$3"
    local timer_name="$4"
    local timer_content="$5"

    printf '%s' "$service_content" > "$unit_dir/$service_name"
    printf '%s' "$timer_content" > "$unit_dir/$timer_name"
}

# systemd_enable_timer <ctl_fn> <timer_name>
# ctl_fn is the module's systemctl seam (schedule_systemctl/backup_systemctl)
# so tests can stub the daemon interaction per module.
systemd_enable_timer() {
    local ctl_fn="$1"
    local timer_name="$2"
    "$ctl_fn" daemon-reload
    "$ctl_fn" enable "$timer_name" >/dev/null
    "$ctl_fn" start "$timer_name" >/dev/null
}

# ============================================================================
# INTERACTIVE WATCH LOOP (single implementation; render_fn returns non-zero
# to stop the loop; max_iterations empty = run until interrupted)
# ============================================================================

watch_loop() {
    local interval="$1"
    local title="$2"
    local max_iterations="${3:-}"
    local render_fn="$4"
    local interactive="false"
    local stop_requested=0
    local iterations=0

    [[ -t 1 ]] && interactive="true"

    trap 'stop_requested=1' INT TERM

    if [[ "$interactive" == "true" ]]; then
        printf '\033[?25l'
    fi

    while [[ "$stop_requested" -eq 0 ]]; do
        if [[ "$interactive" == "true" ]]; then
            printf '\033[H\033[2J'
        fi

        echo "$title"
        echo "Interval: ${interval}s"
        echo "Press Ctrl+C to stop"
        echo ""

        "$render_fn" || break

        if [[ -n "$max_iterations" ]]; then
            iterations=$((iterations + 1))
            if [[ "$iterations" -ge "$max_iterations" ]]; then
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
}

# ============================================================================
# LOCKING
# ============================================================================

# acquire_lock <name> [<label> <exit_code>]
# label customizes the "busy" message (default: "instance"); exit_code
# defaults to E_LOCK_FAILED.
acquire_lock() {
    local lock_name="${1:-global}"
    local lock_label="${2:-instance}"
    local lock_exit_code="${3:-$E_LOCK_FAILED}"
    local lock_file="$LOCK_DIR/$lock_name.lock"
    local pid

    # Create lock directory if needed (lazy init)
    if [[ ! -d "$LOCK_DIR" ]]; then
        mkdir -p "$LOCK_DIR" 2>/dev/null || {
            error_exit "Cannot create lock directory: $LOCK_DIR" "$lock_exit_code"
        }
    fi

    if [[ -f "$lock_file" ]]; then
        pid=$(cat "$lock_file" 2>/dev/null) || true
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error_exit "Another $lock_label is running (PID: $pid)" "$lock_exit_code"
        fi
        rm -f "$lock_file"
    fi

    echo $$ > "$lock_file"
    register_cleanup "rm -f $lock_file"
    log_debug "Acquired lock: $lock_name"
}

release_lock() {
    local lock_name="${1:-global}"
    local lock_file="$LOCK_DIR/$lock_name.lock"
    rm -f "$lock_file"
    log_debug "Released lock: $lock_name"
}

# ============================================================================
# TEMP FILES
# ============================================================================

mktemp_secure() {
    local template="${1:-vmangos-XXXXXX}"
    local temp_file
    temp_file=$(mktemp -t "$template")
    chmod 600 "$temp_file"
    register_cleanup "rm -f $temp_file"
    echo "$temp_file"
}

get_file_permissions() {
    local file_path="$1"
    stat -c "%a" "$file_path" 2>/dev/null || stat -f "%OLp" "$file_path"
}

get_file_size_bytes() {
    local file_path="$1"
    stat -c "%s" "$file_path" 2>/dev/null || stat -f "%z" "$file_path"
}

sha256_file() {
    local file_path="$1"
    sha256sum "$file_path" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$file_path" | cut -d' ' -f1
}

# ============================================================================
# JSON UTILITIES
# ============================================================================

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\t'/\\t}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    printf '%s' "$str"
}

# ============================================================================
# JSON BUILDERS — the only way bash code assembles JSON payloads.
# Build bottom-up: json_string/json_bool for scalars, json_object/json_array
# for containers, then hand the finished payload to json_output.
# ============================================================================

json_string() {
    printf '"%s"' "$(json_escape "$1")"
}

json_bool() {
    case "$1" in
        true|1|yes) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

# json_object '"key":value' '"key2":value2' ...  (members pre-encoded)
json_object() {
    local member joined=""
    for member in "$@"; do
        joined+="$member,"
    done
    printf '{%s}' "${joined%,}"
}

# json_array '"a"' '"b"' ...  (elements pre-encoded)
json_array() {
    if [[ $# -eq 0 ]]; then
        printf '[]'
        return 0
    fi
    local element joined=""
    for element in "$@"; do
        joined+="$element,"
    done
    printf '[%s]' "${joined%,}"
}

# json_string_array 'raw string' 'raw string' ...  (strings escaped here)
json_string_array() {
    local items=()
    local item
    for item in "$@"; do
        items+=("$(json_string "$item")")
    done
    json_array ${items[@]+"${items[@]}"}
}

# json_kv_raw <key> <pre-encoded value>  ->  '"key":value'
# "raw" = the value must already be valid JSON (from json_string/json_bool/
# json_object/json_array, or a pre-validated number). For plain strings use
# json_kvs, which escapes.
json_kv_raw() {
    printf '"%s":%s' "$(json_escape "$1")" "$2"
}

# json_kvs <key> <raw string value>  ->  '"key":"value"' (value escaped)
json_kvs() {
    json_kv_raw "$1" "$(json_string "$2")"
}

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
        local escaped_message
        escaped_message=$(json_escape "$error_message")
        local escaped_suggestion
        escaped_suggestion=$(json_escape "$error_suggestion")
        
        printf '{"success":false,"timestamp":"%s","data":null,"error":{"code":"%s","message":"%s","suggestion":"%s"}}\n' \
            "$timestamp" "$error_code" "$escaped_message" "$escaped_suggestion"
    fi
}

# ============================================================================
# SERVICE UTILITIES
# ============================================================================

service_active() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

service_start() {
    local service="$1"
    log_info "Starting $service..."
    if systemctl start "$service"; then
        log_info "$service started"
        return 0
    else
        log_error "Failed to start $service"
        return 1
    fi
}

log_section() {
    echo ""
    log_info "========================================"
    log_info "$1"
    log_info "========================================"
}
