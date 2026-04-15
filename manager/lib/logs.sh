#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Log rotation module for VMANGOS Manager
# Generates and validates logrotate configuration for VMANGOS logs
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

LOGS_CONFIG_LOADED=""
LOGS_INSTALL_ROOT=""
LOGS_ROOT=""
LOGS_ROTATE_CONFIG_PATH="${VMANGOS_LOGROTATE_CONFIG_PATH:-/etc/logrotate.d/vmangos}"
LOGS_ROTATE_STATE_PATH="${VMANGOS_LOGROTATE_STATE_PATH:-}"
LOGS_ROTATE_OWNER_USER="${VMANGOS_LOGROTATE_OWNER_USER:-mangos}"
LOGS_ROTATE_OWNER_GROUP="${VMANGOS_LOGROTATE_OWNER_GROUP:-mangos}"
LOGS_MIN_FREE_KB="${VMANGOS_LOGROTATE_MIN_FREE_KB:-512000}"
LOGS_RETENTION_DAYS="${VMANGOS_LOGROTATE_RETENTION_DAYS:-30}"
LOGS_SENSITIVE_RETENTION_DAYS="${VMANGOS_LOGROTATE_SENSITIVE_RETENTION_DAYS:-90}"
LOGS_MAX_SIZE="${VMANGOS_LOGROTATE_MAX_SIZE:-100M}"
LOGS_MIN_SIZE="${VMANGOS_LOGROTATE_MIN_SIZE:-1M}"
LOGS_RECENT_DEFAULT_SOURCE="${VMANGOS_LOGS_RECENT_SOURCE:-all}"
LOGS_RECENT_DEFAULT_WINDOW="${VMANGOS_LOGS_RECENT_WINDOW:-15m}"
LOGS_RECENT_DEFAULT_SEVERITY="${VMANGOS_LOGS_RECENT_SEVERITY:-all}"
LOGS_RECENT_DEFAULT_LIMIT="${VMANGOS_LOGS_RECENT_LIMIT:-25}"
LOGS_RECENT_DEFAULT_INTERVAL="${VMANGOS_LOGS_RECENT_INTERVAL:-2}"

logs_load_config() {
    [[ "$LOGS_CONFIG_LOADED" == "1" ]] && return 0

    config_load "$CONFIG_FILE" || {
        log_error "Failed to load configuration"
        return 1
    }

    LOGS_INSTALL_ROOT="${CONFIG_SERVER_INSTALL_ROOT:-/opt/mangos}"
    LOGS_ROOT="${LOGS_INSTALL_ROOT}/logs"
    LOGS_CONFIG_LOADED="1"
    return 0
}

logs_logrotate_bin() {
    if [[ -n "${LOGROTATE_BIN:-}" ]]; then
        printf '%s\n' "$LOGROTATE_BIN"
        return 0
    fi

    command -v logrotate 2>/dev/null || printf '%s\n' /usr/sbin/logrotate
}

logs_journalctl_bin() {
    if [[ -n "${LOGS_JOURNALCTL_BIN:-}" ]]; then
        printf '%s\n' "$LOGS_JOURNALCTL_BIN"
        return 0
    fi

    command -v journalctl 2>/dev/null || printf '%s\n' /usr/bin/journalctl
}

logs_python_bin() {
    command -v python3 2>/dev/null || printf '%s\n' /usr/bin/python3
}

logs_validate_positive_integer() {
    local value="${1:-}"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

logs_validate_recent_source() {
    case "${1:-}" in
        all|auth|world)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

logs_validate_recent_window() {
    local value="${1:-}"
    [[ "$value" =~ ^[1-9][0-9]*[mhd]$ ]]
}

logs_validate_recent_severity() {
    case "${1:-}" in
        all|debug|info|notice|warning|error|critical|alert)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

logs_validate_recent_limit() {
    local value="${1:-}"
    logs_validate_positive_integer "$value" && [[ "$value" -le 200 ]]
}

logs_validate_recent_interval() {
    logs_validate_positive_integer "${1:-}"
}

logs_validate_recent_request() {
    local source="${1:-$LOGS_RECENT_DEFAULT_SOURCE}"
    local window="${2:-$LOGS_RECENT_DEFAULT_WINDOW}"
    local severity="${3:-$LOGS_RECENT_DEFAULT_SEVERITY}"
    local limit="${4:-$LOGS_RECENT_DEFAULT_LIMIT}"

    if ! logs_validate_recent_source "$source"; then
        printf '%s\n' "Invalid log source: $source (expected all, auth, or world)"
        return 1
    fi
    if ! logs_validate_recent_window "$window"; then
        printf '%s\n' "Invalid log window: $window (expected values like 15m, 1h, or 1d)"
        return 1
    fi
    if ! logs_validate_recent_severity "$severity"; then
        printf '%s\n' "Invalid log severity: $severity (expected all, debug, info, notice, warning, error, critical, or alert)"
        return 1
    fi
    if ! logs_validate_recent_limit "$limit"; then
        printf '%s\n' "Invalid log limit: $limit (expected an integer between 1 and 200)"
        return 1
    fi
}

logs_recent_sources_for_selection() {
    local source="${1:-all}"
    if [[ "$source" == "all" ]]; then
        printf '%s\n' auth
        printf '%s\n' world
    else
        printf '%s\n' "$source"
    fi
}

logs_source_service_name() {
    case "${1:-}" in
        auth)
            printf '%s\n' "${CONFIG_SERVER_AUTH_SERVICE:-auth}"
            ;;
        world)
            printf '%s\n' "${CONFIG_SERVER_WORLD_SERVICE:-world}"
            ;;
        *)
            printf '%s\n' "${1:-unknown}"
            ;;
    esac
}

logs_recent_since_arg() {
    local window="${1:-15m}"
    local amount unit label
    amount="${window%[mhd]}"
    unit="${window#"$amount"}"

    case "$unit" in
        m)
            label="minute"
            ;;
        h)
            label="hour"
            ;;
        d)
            label="day"
            ;;
        *)
            label="minute"
            ;;
    esac

    if [[ "$amount" != "1" ]]; then
        label="${label}s"
    fi

    printf '%s %s ago\n' "$amount" "$label"
}

logs_recent_priority_range() {
    case "${1:-all}" in
        all)
            printf '%s\n' ""
            ;;
        debug)
            printf '%s\n' "debug"
            ;;
        info)
            printf '%s\n' "info..alert"
            ;;
        notice)
            printf '%s\n' "notice..alert"
            ;;
        warning)
            printf '%s\n' "warning..alert"
            ;;
        error)
            printf '%s\n' "err..alert"
            ;;
        critical)
            printf '%s\n' "crit..alert"
            ;;
        alert)
            printf '%s\n' "alert..alert"
            ;;
    esac
}

logs_df_target() {
    if [[ -d "$LOGS_ROOT" ]]; then
        printf '%s\n' "$LOGS_ROOT"
    elif [[ -d "$LOGS_INSTALL_ROOT" ]]; then
        printf '%s\n' "$LOGS_INSTALL_ROOT"
    else
        printf '%s\n' "$(dirname "$LOGS_ROOT")"
    fi
}

logs_collect_disk_stats() {
    local target disk_data
    target=$(logs_df_target)
    disk_data=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $2 "|" $3 "|" $4 "|" $5}' || true)

    if [[ -n "$disk_data" ]]; then
        printf '%s\n' "$disk_data"
    else
        printf '0|0|0|0\n'
    fi
}

logs_check_disk_space() {
    local disk_data available_kb
    disk_data=$(logs_collect_disk_stats)
    available_kb="${disk_data#*|}"
    available_kb="${available_kb#*|}"
    available_kb="${available_kb%%|*}"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || available_kb=0
    [[ "$LOGS_MIN_FREE_KB" =~ ^[0-9]+$ ]] || LOGS_MIN_FREE_KB=512000
    [[ "$available_kb" -ge "$LOGS_MIN_FREE_KB" ]]
}

logs_sensitive_paths() {
    cat <<EOF
$LOGS_ROOT/mangosd/gm_critical.log
$LOGS_ROOT/mangosd/Anticheat.log
EOF
}

logs_general_paths() {
    cat <<EOF
$LOGS_ROOT/mangosd/Bg.log
$LOGS_ROOT/mangosd/Char.log
$LOGS_ROOT/mangosd/Chat.log
$LOGS_ROOT/mangosd/DBErrors.log
$LOGS_ROOT/mangosd/LevelUp.log
$LOGS_ROOT/mangosd/Loot.log
$LOGS_ROOT/mangosd/Movement.log
$LOGS_ROOT/mangosd/Network.log
$LOGS_ROOT/mangosd/Perf.log
$LOGS_ROOT/mangosd/Ra.log
$LOGS_ROOT/mangosd/Scripts.log
$LOGS_ROOT/mangosd/Server.log
$LOGS_ROOT/mangosd/Trades.log
$LOGS_ROOT/realmd/*.log
$LOGS_ROOT/honor/*.log
EOF
}

logs_find_active_files() {
    [[ -d "$LOGS_ROOT" ]] || return 0
    find "$LOGS_ROOT" -type f -name '*.log' -print0 2>/dev/null
}

logs_find_rotated_files() {
    [[ -d "$LOGS_ROOT" ]] || return 0
    find "$LOGS_ROOT" -type f \( -name '*.log-*' -o -name '*.log.[0-9]*' -o -name '*.log.[0-9]*.gz' \) -print0 2>/dev/null
}

logs_find_sensitive_files() {
    local file
    while IFS= read -r file; do
        [[ -n "$file" && -f "$file" ]] && printf '%s\0' "$file"
    done < <(logs_sensitive_paths)
}

logs_collect_file_stats() {
    local mode="$1"
    local count=0
    local total_bytes=0
    local file size

    while IFS= read -r -d '' file; do
        count=$((count + 1))
        size=$(get_file_size_bytes "$file" 2>/dev/null || echo 0)
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        total_bytes=$((total_bytes + size))
    done < <(
        if [[ "$mode" == "active" ]]; then
            logs_find_active_files
        else
            logs_find_rotated_files
        fi
    )

    printf '%s|%s\n' "$count" "$total_bytes"
}

logs_sensitive_permissions_ok() {
    local file perms

    while IFS= read -r -d '' file; do
        perms=$(get_file_permissions "$file" 2>/dev/null || echo "")
        if [[ "$perms" != "600" ]]; then
            return 1
        fi
    done < <(logs_find_sensitive_files)

    return 0
}

logs_harden_sensitive_permissions() {
    local file changed=0

    while IFS= read -r -d '' file; do
        chmod 600 "$file" || {
            log_error "Failed to harden sensitive log permissions: $file"
            return 1
        }
        changed=$((changed + 1))
    done < <(logs_find_sensitive_files)

    log_debug "Sensitive log permission check applied to $changed files"
    return 0
}

logs_render_logrotate_config() {
    logs_load_config || return 1

    local general_paths sensitive_paths
    general_paths=$(logs_general_paths)
    sensitive_paths=$(logs_sensitive_paths)

    cat <<EOF
# Managed by VMANGOS Manager. Manual edits will be overwritten.
# copytruncate is intentional because VMANGOS keeps log file descriptors open
# and does not provide a consistent reopen mechanism across mangosd/realmd logs.

$general_paths {
    daily
    rotate $LOGS_RETENTION_DAYS
    compress
    delaycompress
    compressoptions -6
    copytruncate
    missingok
    notifempty
    sharedscripts
    su $LOGS_ROTATE_OWNER_USER $LOGS_ROTATE_OWNER_GROUP
    dateext
    dateformat -%Y%m%d-%s
    maxsize $LOGS_MAX_SIZE
    minsize $LOGS_MIN_SIZE
    prerotate
        AVAILABLE=\$(/bin/df -Pk "$LOGS_ROOT" | /usr/bin/awk 'NR==2 {print \$4}')
        if [ "\${AVAILABLE:-0}" -lt $LOGS_MIN_FREE_KB ]; then
            /usr/bin/logger -t vmangos-logrotate "ERROR: Insufficient disk space for log rotation"
            exit 1
        fi
    endscript
}

$sensitive_paths {
    daily
    rotate $LOGS_SENSITIVE_RETENTION_DAYS
    compress
    delaycompress
    copytruncate
    missingok
    notifempty
    su $LOGS_ROTATE_OWNER_USER $LOGS_ROTATE_OWNER_GROUP
    dateext
    dateformat -%Y%m%d-%s
}
EOF
}

logs_config_in_sync() {
    local temp_file
    temp_file=$(mktemp_secure vmangos-logrotate-XXXXXX)
    logs_render_logrotate_config > "$temp_file"

    [[ -f "$LOGS_ROTATE_CONFIG_PATH" ]] && cmp -s "$temp_file" "$LOGS_ROTATE_CONFIG_PATH"
}

logs_install_config() {
    logs_load_config || return 1

    local temp_file config_dir
    temp_file=$(mktemp_secure vmangos-logrotate-XXXXXX)
    logs_render_logrotate_config > "$temp_file"
    chmod 644 "$temp_file"

    config_dir=$(dirname "$LOGS_ROTATE_CONFIG_PATH")
    install -d "$config_dir" || {
        log_error "Failed to create config directory: $config_dir"
        return 1
    }

    if [[ -f "$LOGS_ROTATE_CONFIG_PATH" ]] && cmp -s "$temp_file" "$LOGS_ROTATE_CONFIG_PATH"; then
        log_debug "Logrotate config already current: $LOGS_ROTATE_CONFIG_PATH"
        return 0
    fi

    install -m 644 "$temp_file" "$LOGS_ROTATE_CONFIG_PATH" || {
        log_error "Failed to install logrotate config: $LOGS_ROTATE_CONFIG_PATH"
        return 1
    }

    log_info "Installed logrotate config: $LOGS_ROTATE_CONFIG_PATH"
}

logs_run_logrotate() {
    local mode="$1"
    local force="${2:-false}"
    local logrotate_bin
    local cmd=()

    logrotate_bin=$(logs_logrotate_bin)
    if [[ ! -x "$logrotate_bin" ]]; then
        log_error "logrotate not found: $logrotate_bin"
        return 1
    fi

    cmd+=("$logrotate_bin")
    [[ "$mode" == "debug" ]] && cmd+=("-d")
    [[ "$force" == "true" ]] && cmd+=("-f")
    [[ -n "$LOGS_ROTATE_STATE_PATH" ]] && cmd+=("-s" "$LOGS_ROTATE_STATE_PATH")
    cmd+=("$LOGS_ROTATE_CONFIG_PATH")

    "${cmd[@]}"
}

logs_collect_status() {
    logs_load_config || return 1

    LOGS_STATUS_TIMESTAMP=$(date -Iseconds)
    LOGS_STATUS_CONFIG_PRESENT="false"
    LOGS_STATUS_CONFIG_IN_SYNC="false"
    LOGS_STATUS_LOG_ROOT_PRESENT="false"
    LOGS_STATUS_DISK_OK="false"
    LOGS_STATUS_SENSITIVE_PERMISSIONS_OK="true"

    if [[ -f "$LOGS_ROTATE_CONFIG_PATH" ]]; then
        LOGS_STATUS_CONFIG_PRESENT="true"
        if logs_config_in_sync; then
            LOGS_STATUS_CONFIG_IN_SYNC="true"
        fi
    fi

    if [[ -d "$LOGS_ROOT" ]]; then
        LOGS_STATUS_LOG_ROOT_PRESENT="true"
    fi

    local active_stats rotated_stats disk_data
    active_stats=$(logs_collect_file_stats "active")
    rotated_stats=$(logs_collect_file_stats "rotated")
    disk_data=$(logs_collect_disk_stats)

    LOGS_STATUS_ACTIVE_FILE_COUNT="${active_stats%%|*}"
    LOGS_STATUS_ACTIVE_SIZE_BYTES="${active_stats##*|}"
    LOGS_STATUS_ROTATED_FILE_COUNT="${rotated_stats%%|*}"
    LOGS_STATUS_ROTATED_SIZE_BYTES="${rotated_stats##*|}"

    LOGS_STATUS_DISK_TOTAL_KB="${disk_data%%|*}"
    disk_data="${disk_data#*|}"
    LOGS_STATUS_DISK_USED_KB="${disk_data%%|*}"
    disk_data="${disk_data#*|}"
    LOGS_STATUS_DISK_AVAILABLE_KB="${disk_data%%|*}"
    LOGS_STATUS_DISK_USED_PERCENT="${disk_data##*|}"

    [[ "$LOGS_STATUS_ACTIVE_FILE_COUNT" =~ ^[0-9]+$ ]] || LOGS_STATUS_ACTIVE_FILE_COUNT=0
    [[ "$LOGS_STATUS_ACTIVE_SIZE_BYTES" =~ ^[0-9]+$ ]] || LOGS_STATUS_ACTIVE_SIZE_BYTES=0
    [[ "$LOGS_STATUS_ROTATED_FILE_COUNT" =~ ^[0-9]+$ ]] || LOGS_STATUS_ROTATED_FILE_COUNT=0
    [[ "$LOGS_STATUS_ROTATED_SIZE_BYTES" =~ ^[0-9]+$ ]] || LOGS_STATUS_ROTATED_SIZE_BYTES=0
    [[ "$LOGS_STATUS_DISK_TOTAL_KB" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_TOTAL_KB=0
    [[ "$LOGS_STATUS_DISK_USED_KB" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_USED_KB=0
    [[ "$LOGS_STATUS_DISK_AVAILABLE_KB" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_AVAILABLE_KB=0
    [[ "$LOGS_STATUS_DISK_USED_PERCENT" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_USED_PERCENT=0

    local sensitive_count=0
    local file
    while IFS= read -r -d '' file; do
        sensitive_count=$((sensitive_count + 1))
    done < <(logs_find_sensitive_files)
    LOGS_STATUS_SENSITIVE_FILE_COUNT="$sensitive_count"

    if logs_sensitive_permissions_ok; then
        LOGS_STATUS_SENSITIVE_PERMISSIONS_OK="true"
    else
        LOGS_STATUS_SENSITIVE_PERMISSIONS_OK="false"
    fi

    if logs_check_disk_space; then
        LOGS_STATUS_DISK_OK="true"
    fi

    LOGS_STATUS_HEALTH="healthy"
    if [[ "$LOGS_STATUS_CONFIG_PRESENT" != "true" || "$LOGS_STATUS_CONFIG_IN_SYNC" != "true" || "$LOGS_STATUS_DISK_OK" != "true" || "$LOGS_STATUS_SENSITIVE_PERMISSIONS_OK" != "true" ]]; then
        LOGS_STATUS_HEALTH="degraded"
    fi
    if [[ "$LOGS_STATUS_LOG_ROOT_PRESENT" != "true" ]]; then
        LOGS_STATUS_HEALTH="missing"
    fi
}

logs_status_text() {
    logs_collect_status || {
        log_error "Failed to load configuration"
        return 1
    }

    local disk_free_mb=$((LOGS_STATUS_DISK_AVAILABLE_KB / 1024))

    echo "VMANGOS Log Rotation Status"
    echo "Timestamp: $LOGS_STATUS_TIMESTAMP"
    echo "Log Root: $LOGS_ROOT"
    echo "Health: $LOGS_STATUS_HEALTH"
    echo ""
    echo "Config:"
    echo "  File:    $LOGS_ROTATE_CONFIG_PATH"
    echo "  Present: $LOGS_STATUS_CONFIG_PRESENT"
    echo "  In sync: $LOGS_STATUS_CONFIG_IN_SYNC"
    echo ""
    echo "Logs:"
    echo "  Active files:        $LOGS_STATUS_ACTIVE_FILE_COUNT"
    echo "  Active size bytes:   $LOGS_STATUS_ACTIVE_SIZE_BYTES"
    echo "  Rotated files:       $LOGS_STATUS_ROTATED_FILE_COUNT"
    echo "  Rotated size bytes:  $LOGS_STATUS_ROTATED_SIZE_BYTES"
    echo "  Sensitive files:     $LOGS_STATUS_SENSITIVE_FILE_COUNT"
    echo "  Sensitive perms OK:  $LOGS_STATUS_SENSITIVE_PERMISSIONS_OK"
    echo ""
    echo "Disk:"
    echo "  OK:        $LOGS_STATUS_DISK_OK"
    echo "  Free MB:   $disk_free_mb"
    echo "  Used %:    $LOGS_STATUS_DISK_USED_PERCENT"
    echo "  Threshold: $LOGS_MIN_FREE_KB KB"
}

logs_status_json() {
    logs_collect_status || {
        json_output false "null" "CONFIG_ERROR" "Failed to load configuration" "Check config file exists and is readable"
        return 1
    }

    local data
    data=$(cat <<EOF
{
  "status": "$(json_escape "$LOGS_STATUS_HEALTH")",
  "log_root": "$(json_escape "$LOGS_ROOT")",
  "config": {
    "path": "$(json_escape "$LOGS_ROTATE_CONFIG_PATH")",
    "present": $LOGS_STATUS_CONFIG_PRESENT,
    "in_sync": $LOGS_STATUS_CONFIG_IN_SYNC
  },
  "logs": {
    "active_files": $LOGS_STATUS_ACTIVE_FILE_COUNT,
    "active_size_bytes": $LOGS_STATUS_ACTIVE_SIZE_BYTES,
    "rotated_files": $LOGS_STATUS_ROTATED_FILE_COUNT,
    "rotated_size_bytes": $LOGS_STATUS_ROTATED_SIZE_BYTES,
    "sensitive_files": $LOGS_STATUS_SENSITIVE_FILE_COUNT,
    "sensitive_permissions_ok": $LOGS_STATUS_SENSITIVE_PERMISSIONS_OK
  },
  "disk": {
    "path": "$(json_escape "$(logs_df_target)")",
    "ok": $LOGS_STATUS_DISK_OK,
    "total_kb": $LOGS_STATUS_DISK_TOTAL_KB,
    "used_kb": $LOGS_STATUS_DISK_USED_KB,
    "available_kb": $LOGS_STATUS_DISK_AVAILABLE_KB,
    "used_percent": $LOGS_STATUS_DISK_USED_PERCENT,
    "required_free_kb": $LOGS_MIN_FREE_KB
  },
  "policy": {
    "copytruncate": true,
    "retention_days": $LOGS_RETENTION_DAYS,
    "sensitive_retention_days": $LOGS_SENSITIVE_RETENTION_DAYS,
    "max_size": "$(json_escape "$LOGS_MAX_SIZE")",
    "min_size": "$(json_escape "$LOGS_MIN_SIZE")"
  }
}
EOF
)

    json_output true "$data"
}

logs_test_config() {
    logs_install_config || return 1

    if ! logs_run_logrotate "debug" "false" >/dev/null; then
        if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
            json_output false "null" "LOGROTATE_INVALID" "logrotate validation failed" "Run with --verbose or inspect the generated config"
        else
            log_error "logrotate validation failed"
        fi
        return 1
    fi

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "{\"config_path\":\"$(json_escape "$LOGS_ROTATE_CONFIG_PATH")\",\"valid\":true}"
    else
        log_info "Logrotate configuration is valid: $LOGS_ROTATE_CONFIG_PATH"
    fi
}

logs_rotate() {
    local force="${1:-false}"

    logs_install_config || return 1

    if ! logs_check_disk_space; then
        if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
            json_output false "null" "INSUFFICIENT_DISK" "Insufficient disk space for log rotation" "Free at least ${LOGS_MIN_FREE_KB} KB under $LOGS_ROOT"
        else
            log_error "Insufficient disk space for log rotation"
        fi
        return 1
    fi

    logs_harden_sensitive_permissions || return 1

    if ! logs_run_logrotate "rotate" "$force" >/dev/null; then
        if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
            json_output false "null" "LOGROTATE_FAILED" "logrotate execution failed" "Inspect logrotate output and generated config"
        else
            log_error "logrotate execution failed"
        fi
        return 1
    fi

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "{\"config_path\":\"$(json_escape "$LOGS_ROTATE_CONFIG_PATH")\",\"force\":$force,\"disk_precheck_ok\":true}"
    else
        log_info "Log rotation completed using $LOGS_ROTATE_CONFIG_PATH"
    fi
}

logs_collect_recent_source_json() {
    local source="$1"
    local service="$2"
    local window="$3"
    local severity="$4"
    local limit="$5"
    local journalctl_bin python_bin since_arg priority_range
    local command_output=""
    local command_status=0
    local output_file

    journalctl_bin=$(logs_journalctl_bin)
    python_bin=$(logs_python_bin)

    if [[ ! -x "$python_bin" ]]; then
        printf '{"source":"%s","service":"%s","backing":"unavailable","available":false,"severity_supported":false,"time_window_supported":false,"events":[],"error":"python3 not found"}\n' \
            "$(json_escape "$source")" "$(json_escape "$service")"
        return 0
    fi

    if [[ ! -x "$journalctl_bin" ]]; then
        printf '{"source":"%s","service":"%s","backing":"unavailable","available":false,"severity_supported":false,"time_window_supported":false,"events":[],"error":"journalctl not found"}\n' \
            "$(json_escape "$source")" "$(json_escape "$service")"
        return 0
    fi

    since_arg=$(logs_recent_since_arg "$window")
    priority_range=$(logs_recent_priority_range "$severity")

    if [[ -n "$priority_range" ]]; then
        command_output=$("$journalctl_bin" --no-pager --output json --since "$since_arg" -n "$limit" -u "$service" -p "$priority_range" 2>/dev/null) || command_status=$?
    else
        command_output=$("$journalctl_bin" --no-pager --output json --since "$since_arg" -n "$limit" -u "$service" 2>/dev/null) || command_status=$?
    fi

    output_file=$(mktemp_secure "vmangos-logs-source-${source}-XXXXXX")
    printf '%s' "$command_output" > "$output_file"

    "$python_bin" - "$source" "$service" "$command_status" "$output_file" <<'PY'
import json
import sys
from datetime import datetime, timezone

source = sys.argv[1]
service = sys.argv[2]
status = int(sys.argv[3])
output_path = sys.argv[4]


def severity_label(priority: object) -> str:
    try:
        value = int(priority)
    except (TypeError, ValueError):
        return "info"
    mapping = {
        0: "emergency",
        1: "alert",
        2: "critical",
        3: "error",
        4: "warning",
        5: "notice",
        6: "info",
        7: "debug",
    }
    return mapping.get(value, "info")


payload = {
    "source": source,
    "service": service,
    "backing": "journald" if status == 0 else "unavailable",
    "available": status == 0,
    "severity_supported": status == 0,
    "time_window_supported": status == 0,
    "events": [],
    "error": "" if status == 0 else "journalctl query failed",
}

if status != 0:
    print(json.dumps(payload, separators=(",", ":")))
    raise SystemExit(0)

events = []
with open(output_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line or line.startswith("-- "):
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        message = " ".join(str(entry.get("MESSAGE", "") or "").split())
        if not message:
            continue

        timestamp = ""
        realtime = str(entry.get("__REALTIME_TIMESTAMP", "") or "")
        if realtime.isdigit():
            timestamp = (
                datetime.fromtimestamp(int(realtime) / 1_000_000, tz=timezone.utc)
                .astimezone()
                .isoformat()
            )

        priority = entry.get("PRIORITY")
        events.append(
            {
                "timestamp": timestamp,
                "source": source,
                "service": service,
                "unit": str(entry.get("_SYSTEMD_UNIT", "") or service),
                "identifier": str(entry.get("SYSLOG_IDENTIFIER", "") or entry.get("_COMM", "") or service),
                "severity": severity_label(priority),
                "priority": int(priority) if str(priority).isdigit() else 6,
                "message": message,
                "raw": message,
            }
        )

events.sort(key=lambda item: (item.get("timestamp", ""), item.get("message", "")), reverse=True)
payload["events"] = events
print(json.dumps(payload, separators=(",", ":")))
PY
}

logs_collect_recent_data() {
    local source="${1:-$LOGS_RECENT_DEFAULT_SOURCE}"
    local window="${2:-$LOGS_RECENT_DEFAULT_WINDOW}"
    local severity="${3:-$LOGS_RECENT_DEFAULT_SEVERITY}"
    local limit="${4:-$LOGS_RECENT_DEFAULT_LIMIT}"
    local python_bin temp_file service selected_source
    local temp_files=()

    logs_load_config || return 1
    logs_validate_recent_request "$source" "$window" "$severity" "$limit" || {
        log_error "$(logs_validate_recent_request "$source" "$window" "$severity" "$limit")"
        return 1
    }

    python_bin=$(logs_python_bin)
    if [[ ! -x "$python_bin" ]]; then
        log_error "python3 not found"
        return 1
    fi

    while IFS= read -r selected_source; do
        [[ -n "$selected_source" ]] || continue
        temp_file=$(mktemp_secure "vmangos-logs-recent-${selected_source}-XXXXXX")
        service=$(logs_source_service_name "$selected_source")
        logs_collect_recent_source_json "$selected_source" "$service" "$window" "$severity" "$limit" > "$temp_file"
        temp_files+=("$temp_file")
    done < <(logs_recent_sources_for_selection "$source")

    "$python_bin" - "$source" "$window" "$severity" "$limit" "${temp_files[@]}" <<'PY'
import json
import sys
from collections import Counter

selected_source = sys.argv[1]
window = sys.argv[2]
severity = sys.argv[3]
limit = int(sys.argv[4])
source_files = sys.argv[5:]

sources = []
events = []
for path in source_files:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    sources.append(payload)
    events.extend(payload.get("events", []))

events.sort(key=lambda item: (item.get("timestamp", ""), item.get("source", ""), item.get("message", "")), reverse=True)
events = events[:limit]

available_sources = [entry.get("source", "") for entry in sources if entry.get("available")]
source_counts = Counter(entry.get("source", "unknown") for entry in events)
severity_counts = Counter(entry.get("severity", "unknown") for entry in events)
backings = sorted({entry.get("backing", "") for entry in sources if entry.get("backing") and entry.get("available")})
if not backings:
    backing = "unavailable"
elif len(backings) == 1:
    backing = backings[0]
else:
    backing = "mixed"

payload = {
    "scope": "realm",
    "filters": {
        "source": selected_source,
        "window": window,
        "severity": severity,
        "limit": limit,
    },
    "summary": {
        "backing": backing,
        "events_returned": len(events),
        "sources_requested": len(sources),
        "sources_available": len(available_sources),
        "available_sources": available_sources,
        "source_counts": dict(source_counts),
        "severity_counts": dict(severity_counts),
    },
    "capabilities": {
        "severity_filter_supported": bool(available_sources) and all(
            bool(entry.get("severity_supported")) for entry in sources if entry.get("available")
        ),
        "time_window_supported": bool(available_sources) and all(
            bool(entry.get("time_window_supported")) for entry in sources if entry.get("available")
        ),
        "follow_via_refresh": True,
    },
    "sources": sources,
    "events": events,
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

logs_recent_text() {
    local source="${1:-$LOGS_RECENT_DEFAULT_SOURCE}"
    local window="${2:-$LOGS_RECENT_DEFAULT_WINDOW}"
    local severity="${3:-$LOGS_RECENT_DEFAULT_SEVERITY}"
    local limit="${4:-$LOGS_RECENT_DEFAULT_LIMIT}"
    local python_bin data data_file

    if ! data=$(logs_collect_recent_data "$source" "$window" "$severity" "$limit"); then
        return 1
    fi

    python_bin=$(logs_python_bin)
    data_file=$(mktemp_secure "vmangos-logs-recent-text-XXXXXX")
    printf '%s' "$data" > "$data_file"

    "$python_bin" - "$data_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
filters = payload.get("filters", {})
summary = payload.get("summary", {})
capabilities = payload.get("capabilities", {})
events = payload.get("events", [])

print("VMANGOS Realm Log Activity")
print(
    "Filters: source={source} window={window} severity={severity} limit={limit}".format(
        source=filters.get("source", "all"),
        window=filters.get("window", "15m"),
        severity=filters.get("severity", "all"),
        limit=filters.get("limit", 25),
    )
)
print(
    "Backing: {backing}  Sources: {available}/{requested} available  Auto-follow: refresh every interval".format(
        backing=summary.get("backing", "unavailable"),
        available=summary.get("sources_available", 0),
        requested=summary.get("sources_requested", 0),
    )
)
print(
    "Capabilities: severity_filter={severity_filter} time_window={time_window}".format(
        severity_filter=str(capabilities.get("severity_filter_supported", False)).lower(),
        time_window=str(capabilities.get("time_window_supported", False)).lower(),
    )
)
print("")

if not events:
    print("No log events matched the current filters.")
    raise SystemExit(0)

for event in events:
    timestamp = event.get("timestamp", "") or "n/a"
    source = event.get("source", "unknown")
    severity = event.get("severity", "info")
    message = event.get("message", "")
    print(f"{timestamp} [{source}] {severity}: {message}")
PY
}

logs_recent_json() {
    local source="${1:-$LOGS_RECENT_DEFAULT_SOURCE}"
    local window="${2:-$LOGS_RECENT_DEFAULT_WINDOW}"
    local severity="${3:-$LOGS_RECENT_DEFAULT_SEVERITY}"
    local limit="${4:-$LOGS_RECENT_DEFAULT_LIMIT}"
    local validation_error data

    validation_error=$(logs_validate_recent_request "$source" "$window" "$severity" "$limit" || true)
    if [[ -n "$validation_error" ]]; then
        json_output false "null" "INVALID_ARGS" "$validation_error" "Adjust the requested source, window, severity, or limit"
        return 1
    fi

    data=$(logs_collect_recent_data "$source" "$window" "$severity" "$limit") || {
        json_output false "null" "LOGS_RECENT_FAILED" "Failed to collect recent realm logs" "Verify the Manager config and journald access for realm services"
        return 1
    }

    json_output true "$data"
}

logs_recent_watch() {
    local source="${1:-$LOGS_RECENT_DEFAULT_SOURCE}"
    local window="${2:-$LOGS_RECENT_DEFAULT_WINDOW}"
    local severity="${3:-$LOGS_RECENT_DEFAULT_SEVERITY}"
    local limit="${4:-$LOGS_RECENT_DEFAULT_LIMIT}"
    local interval="${5:-$LOGS_RECENT_DEFAULT_INTERVAL}"
    local interactive="false"
    local stop_requested=0
    local iterations=0

    logs_validate_recent_request "$source" "$window" "$severity" "$limit" || {
        log_error "$(logs_validate_recent_request "$source" "$window" "$severity" "$limit")"
        return "$E_INVALID_ARGS"
    }
    if ! logs_validate_recent_interval "$interval"; then
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

        echo "VMANGOS Realm Log Watch"
        echo "Interval: ${interval}s"
        echo "Press Ctrl+C to stop"
        echo ""

        logs_recent_text "$source" "$window" "$severity" "$limit" || break

        if [[ -n "${LOGS_WATCH_MAX_ITERATIONS:-}" ]]; then
            iterations=$((iterations + 1))
            if [[ "$iterations" -ge "$LOGS_WATCH_MAX_ITERATIONS" ]]; then
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

    echo "Stopped log watch."
}
