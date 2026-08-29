#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
# shellcheck source=lib/server.sh
#
# Maintenance scheduling module for VMANGOS Manager
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/server.sh"

SCHEDULE_CONFIG_LOADED=""
SCHEDULE_MANAGER_ROOT=""
SCHEDULE_STATE_DIR=""
SCHEDULE_UNIT_DIR="${SCHEDULE_UNIT_DIR:-/etc/systemd/system}"
SCHEDULE_MANAGER_BIN=""
SCHEDULE_DEFAULT_TIMEZONE=""
SCHEDULE_HONOR_COMMAND=""
SCHEDULE_ANNOUNCE_COMMAND=""
SCHEDULE_RESTART_WARNINGS=""

schedule_detect_timezone() {
    local timezone=""

    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ -z "$timezone" ]] && [[ -f /etc/timezone ]]; then
        timezone=$(tr -d '\n' < /etc/timezone 2>/dev/null || true)
    fi
    if [[ -z "$timezone" ]]; then
        timezone="UTC"
    fi

    printf '%s\n' "$timezone"
}

schedule_load_config() {
    [[ "$SCHEDULE_CONFIG_LOADED" == "1" ]] && return 0

    config_load "$CONFIG_FILE" || {
        log_error "Failed to load configuration"
        return 1
    }

    server_load_config || {
        log_error "Failed to load server configuration"
        return 1
    }

    SCHEDULE_MANAGER_ROOT=$(config_resolve_manager_root "$CONFIG_FILE")
    SCHEDULE_STATE_DIR="${SCHEDULE_MANAGER_ROOT}/state/schedules"
    SCHEDULE_MANAGER_BIN="$(schedule_resolve_manager_bin)"
    SCHEDULE_DEFAULT_TIMEZONE="${CONFIG_MAINTENANCE_TIMEZONE:-$(schedule_detect_timezone)}"
    SCHEDULE_HONOR_COMMAND="${CONFIG_MAINTENANCE_HONOR_COMMAND:-}"
    SCHEDULE_ANNOUNCE_COMMAND="${CONFIG_MAINTENANCE_ANNOUNCE_COMMAND:-}"
    SCHEDULE_RESTART_WARNINGS="${CONFIG_MAINTENANCE_RESTART_WARNINGS:-30,15,5,1}"

    SCHEDULE_CONFIG_LOADED="1"
    return 0
}

schedule_resolve_manager_bin() {
    local manager_root
    manager_root=$(config_resolve_manager_root "$CONFIG_FILE")

    if [[ -x "$manager_root/bin/vmangos-manager" ]]; then
        printf '%s\n' "$manager_root/bin/vmangos-manager"
        return 0
    fi

    printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/vmangos-manager"
}

schedule_validate_time() {
    [[ "${1:-}" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

schedule_validate_day() {
    [[ "${1:-}" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]]
}

schedule_validate_timezone() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_+./-]+$ ]]
}

schedule_validate_warnings() {
    local warnings="${1:-}"
    local seen="" item

    [[ -n "$warnings" ]] || return 1

    IFS=',' read -r -a items <<< "$warnings"
    [[ "${#items[@]}" -gt 0 ]] || return 1

    for item in "${items[@]}"; do
        item=$(config_trim "$item")
        [[ "$item" =~ ^[1-9][0-9]*$ ]] || return 1
        if [[ ",$seen," == *",$item,"* ]]; then
            return 1
        fi
        seen="${seen:+$seen,}$item"
    done

    return 0
}

schedule_ensure_state_dir() {
    schedule_load_config || return 1
    mkdir -p "$SCHEDULE_STATE_DIR" || {
        log_error "Failed to create schedule state directory: $SCHEDULE_STATE_DIR"
        return 1
    }
}

schedule_generate_id() {
    printf '%s-%04d\n' "$(date +%Y%m%d%H%M%S)" "$((RANDOM % 10000))"
}

schedule_metadata_path() {
    printf '%s/%s.conf\n' "$SCHEDULE_STATE_DIR" "$1"
}

schedule_unit_prefix() {
    printf 'vmangos-schedule-%s\n' "$1"
}

schedule_main_service_name() {
    printf '%s.service\n' "$(schedule_unit_prefix "$1")"
}

schedule_main_timer_name() {
    printf '%s.timer\n' "$(schedule_unit_prefix "$1")"
}

schedule_warning_service_name() {
    printf '%s-warning-%s.service\n' "$(schedule_unit_prefix "$1")" "$2"
}

schedule_warning_timer_name() {
    printf '%s-warning-%s.timer\n' "$(schedule_unit_prefix "$1")" "$2"
}

schedule_timer_unit_path() {
    printf '%s/%s\n' "$SCHEDULE_UNIT_DIR" "$1"
}

schedule_write_file() {
    local path="$1"
    local content="$2"
    printf '%s' "$content" > "$path"
}

schedule_systemctl() {
    systemctl "$@"
}

schedule_day_index() {
    case "$1" in
        Mon) printf '0\n' ;;
        Tue) printf '1\n' ;;
        Wed) printf '2\n' ;;
        Thu) printf '3\n' ;;
        Fri) printf '4\n' ;;
        Sat) printf '5\n' ;;
        Sun) printf '6\n' ;;
        *) printf '0\n' ;;
    esac
}

schedule_day_from_index() {
    case "$1" in
        0) printf 'Mon\n' ;;
        1) printf 'Tue\n' ;;
        2) printf 'Wed\n' ;;
        3) printf 'Thu\n' ;;
        4) printf 'Fri\n' ;;
        5) printf 'Sat\n' ;;
        6) printf 'Sun\n' ;;
        *) printf 'Mon\n' ;;
    esac
}

schedule_time_minutes() {
    local time_value="$1"
    local hour minute
    hour="${time_value%%:*}"
    minute="${time_value#*:}"
    printf '%s\n' $((10#$hour * 60 + 10#$minute))
}

schedule_minutes_to_time() {
    local total_minutes="$1"
    printf '%02d:%02d\n' $((total_minutes / 60)) $((total_minutes % 60))
}

schedule_calculate_warning_slot() {
    local schedule_type="$1"
    local day="$2"
    local time_value="$3"
    local warning_minutes="$4"
    local total_minutes adjusted_minutes day_index

    total_minutes=$(schedule_time_minutes "$time_value")
    adjusted_minutes=$((total_minutes - warning_minutes))

    if [[ "$schedule_type" == "weekly" ]]; then
        day_index=$(schedule_day_index "$day")
    else
        day_index=-1
    fi

    while [[ "$adjusted_minutes" -lt 0 ]]; do
        adjusted_minutes=$((adjusted_minutes + 1440))
        if [[ "$schedule_type" == "weekly" ]]; then
            day_index=$(((day_index + 6) % 7))
        fi
    done

    if [[ "$schedule_type" == "weekly" ]]; then
        printf '%s|%s\n' "$(schedule_day_from_index "$day_index")" "$(schedule_minutes_to_time "$adjusted_minutes")"
    else
        printf 'daily|%s\n' "$(schedule_minutes_to_time "$adjusted_minutes")"
    fi
}

schedule_build_oncalendar() {
    local schedule_type="$1"
    local time_value="$2"
    local day="${3:-}"
    local timezone="${4:-}"
    local hour minute on_calendar

    hour="${time_value%%:*}"
    minute="${time_value#*:}"

    if [[ "$schedule_type" == "weekly" ]]; then
        on_calendar="$day *-*-* $hour:$minute:00"
    else
        on_calendar="*-*-* $hour:$minute:00"
    fi

    if [[ -n "$timezone" ]]; then
        on_calendar="$on_calendar $timezone"
    fi

    printf '%s\n' "$on_calendar"
}

schedule_build_warning_oncalendar() {
    local schedule_type="$1"
    local day="$2"
    local time_value="$3"
    local warning_minutes="$4"
    local timezone="$5"
    local slot warning_day warning_time

    slot=$(schedule_calculate_warning_slot "$schedule_type" "$day" "$time_value" "$warning_minutes")
    warning_day="${slot%%|*}"
    warning_time="${slot##*|}"

    if [[ "$warning_day" == "daily" ]]; then
        schedule_build_oncalendar "daily" "$warning_time" "" "$timezone"
    else
        schedule_build_oncalendar "weekly" "$warning_time" "$warning_day" "$timezone"
    fi
}

schedule_schedule_label() {
    local schedule_type="$1"
    local time_value="$2"
    local day="$3"
    local timezone="$4"

    if [[ "$schedule_type" == "weekly" ]]; then
        printf 'weekly %s %s %s\n' "$day" "$time_value" "$timezone"
    else
        printf 'daily %s %s\n' "$time_value" "$timezone"
    fi
}

schedule_conflict_overlap_minutes() {
    local left_minutes="$1"
    local right_minutes="$2"
    local diff

    diff=$((left_minutes - right_minutes))
    if [[ "$diff" -lt 0 ]]; then
        diff=$((diff * -1))
    fi
    if [[ "$diff" -gt 720 ]]; then
        diff=$((1440 - diff))
    fi

    printf '%s\n' "$diff"
}

schedule_days_conflict() {
    local new_type="$1"
    local new_day="$2"
    local existing_type="$3"
    local existing_day="$4"

    if [[ "$new_type" == "daily" || "$existing_type" == "daily" ]]; then
        return 0
    fi

    [[ "$new_day" == "$existing_day" ]]
}

schedule_warn_on_conflicts() {
    local new_type="$1"
    local new_day="$2"
    local new_time="$3"
    local new_timezone="$4"
    local new_job_type="$5"
    local metadata_file existing_type existing_day existing_time existing_timezone existing_job_type overlap

    schedule_ensure_state_dir || return 1

    for metadata_file in "$SCHEDULE_STATE_DIR"/*.conf; do
        [[ -f "$metadata_file" ]] || continue

        existing_job_type=$(ini_read "$metadata_file" "job" "job_type" "")
        existing_type=$(ini_read "$metadata_file" "job" "schedule_type" "")
        existing_day=$(ini_read "$metadata_file" "job" "day" "")
        existing_time=$(ini_read "$metadata_file" "job" "time" "")
        existing_timezone=$(ini_read "$metadata_file" "job" "timezone" "")

        [[ -n "$existing_type" && -n "$existing_time" ]] || continue
        [[ "$new_timezone" == "$existing_timezone" ]] || continue
        schedule_days_conflict "$new_type" "$new_day" "$existing_type" "$existing_day" || continue

        overlap=$(schedule_conflict_overlap_minutes "$(schedule_time_minutes "$new_time")" "$(schedule_time_minutes "$existing_time")")
        if [[ "$overlap" -lt 30 ]]; then
            log_warn "Potential schedule conflict: $new_job_type at $new_time overlaps with existing $existing_job_type at $existing_time"
        fi
    done
}

schedule_job_metadata_content() {
    local id="$1"
    local job_type="$2"
    local schedule_type="$3"
    local time_value="$4"
    local day="$5"
    local timezone="$6"
    local warnings="$7"
    local announce_message="$8"
    local main_timer="$9"

    cat <<EOF
[job]
id = $id
job_type = $job_type
schedule_type = $schedule_type
time = $time_value
day = $day
timezone = $timezone
warnings = $warnings
announce_message = $announce_message
main_service = $(schedule_main_service_name "$id")
main_timer = $main_timer
created_at = $(date -Iseconds)
EOF
}

schedule_write_metadata() {
    local id="$1"
    local content="$2"
    local metadata_path

    metadata_path=$(schedule_metadata_path "$id")
    schedule_write_file "$metadata_path" "$content"
    chmod 600 "$metadata_path" 2>/dev/null || true
}

schedule_load_job() {
    local job_id="$1"
    local metadata_path

    schedule_load_config || return 1
    metadata_path=$(schedule_metadata_path "$job_id")

    if [[ ! -f "$metadata_path" ]]; then
        log_error "Scheduled job not found: $job_id"
        return 1
    fi

    SCHEDULE_JOB_TYPE=$(ini_read "$metadata_path" "job" "job_type" "")
    SCHEDULE_JOB_SCHEDULE_TYPE=$(ini_read "$metadata_path" "job" "schedule_type" "")
    SCHEDULE_JOB_TIME=$(ini_read "$metadata_path" "job" "time" "")
    SCHEDULE_JOB_DAY=$(ini_read "$metadata_path" "job" "day" "")
    SCHEDULE_JOB_TIMEZONE=$(ini_read "$metadata_path" "job" "timezone" "")
    SCHEDULE_JOB_WARNINGS=$(ini_read "$metadata_path" "job" "warnings" "")
    SCHEDULE_JOB_ANNOUNCE_MESSAGE=$(ini_read "$metadata_path" "job" "announce_message" "")
    SCHEDULE_JOB_MAIN_SERVICE=$(ini_read "$metadata_path" "job" "main_service" "")
    SCHEDULE_JOB_MAIN_TIMER=$(ini_read "$metadata_path" "job" "main_timer" "")
    SCHEDULE_JOB_METADATA_PATH="$metadata_path"

    return 0
}

schedule_service_unit_content() {
    local description="$1"
    local exec_args="$2"

    cat <<EOF
[Unit]
Description=$description
After=network.target

[Service]
Type=oneshot
ExecStart=$SCHEDULE_MANAGER_BIN -c $CONFIG_FILE schedule $exec_args
User=root
StandardOutput=journal
StandardError=journal
EOF
}

schedule_timer_unit_content() {
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

schedule_main_exec_args() {
    local job_type="$1"
    local job_id="$2"

    case "$job_type" in
        honor) printf 'run-honor %s\n' "$job_id" ;;
        restart) printf 'run-restart %s\n' "$job_id" ;;
        *) return 1 ;;
    esac
}

schedule_warning_exec_args() {
    printf 'run-warning %s %s\n' "$1" "$2"
}

schedule_install_units() {
    local service_name="$1"
    local service_content="$2"
    local timer_name="$3"
    local timer_content="$4"

    schedule_write_file "$(schedule_timer_unit_path "$service_name")" "$service_content"
    schedule_write_file "$(schedule_timer_unit_path "$timer_name")" "$timer_content"
}

schedule_enable_timer() {
    local timer_name="$1"
    schedule_systemctl daemon-reload
    schedule_systemctl enable "$timer_name" >/dev/null
    schedule_systemctl start "$timer_name" >/dev/null
}

schedule_disable_timer() {
    local timer_name="$1"
    schedule_systemctl stop "$timer_name" >/dev/null 2>&1 || true
    schedule_systemctl disable "$timer_name" >/dev/null 2>&1 || true
}

schedule_create_warning_units() {
    local job_id="$1"
    local schedule_type="$2"
    local day="$3"
    local time_value="$4"
    local timezone="$5"
    local warnings="$6"
    local warning_minutes warning_oncalendar service_name timer_name

    IFS=',' read -r -a warning_items <<< "$warnings"
    for warning_minutes in "${warning_items[@]}"; do
        warning_minutes=$(config_trim "$warning_minutes")
        service_name=$(schedule_warning_service_name "$job_id" "$warning_minutes")
        timer_name=$(schedule_warning_timer_name "$job_id" "$warning_minutes")
        warning_oncalendar=$(schedule_build_warning_oncalendar "$schedule_type" "$day" "$time_value" "$warning_minutes" "$timezone")
        schedule_install_units \
            "$service_name" \
            "$(schedule_service_unit_content "VMANGOS restart warning ${warning_minutes}m ($job_id)" "$(schedule_warning_exec_args "$job_id" "$warning_minutes")")" \
            "$timer_name" \
            "$(schedule_timer_unit_content "Run VMANGOS restart warning ${warning_minutes}m ($job_id)" "$warning_oncalendar")"
        schedule_enable_timer "$timer_name"
    done
}

schedule_create_job() {
    local job_type="$1"
    local schedule_type="$2"
    local time_value="$3"
    local day="$4"
    local timezone="$5"
    local warnings="$6"
    local announce_message="$7"
    local job_id on_calendar main_service main_timer metadata_content

    check_root
    schedule_load_config || return 1
    schedule_ensure_state_dir || return 1

    if [[ -z "$timezone" ]]; then
        timezone="$SCHEDULE_DEFAULT_TIMEZONE"
    fi

    if ! schedule_validate_time "$time_value"; then
        log_error "Invalid time format: $time_value"
        return 1
    fi

    if [[ "$schedule_type" != "daily" && "$schedule_type" != "weekly" ]]; then
        log_error "Invalid schedule type: $schedule_type"
        return 1
    fi

    if [[ "$schedule_type" == "weekly" ]] && ! schedule_validate_day "$day"; then
        log_error "Invalid weekly schedule day: $day"
        return 1
    fi

    if ! schedule_validate_timezone "$timezone"; then
        log_error "Invalid timezone: $timezone"
        return 1
    fi

    if [[ "$job_type" == "restart" && -n "$warnings" ]] && ! schedule_validate_warnings "$warnings"; then
        log_error "Invalid warning intervals: $warnings"
        return 1
    fi

    schedule_warn_on_conflicts "$schedule_type" "$day" "$time_value" "$timezone" "$job_type"

    job_id=$(schedule_generate_id)
    on_calendar=$(schedule_build_oncalendar "$schedule_type" "$time_value" "$day" "$timezone")
    main_service=$(schedule_main_service_name "$job_id")
    main_timer=$(schedule_main_timer_name "$job_id")

    schedule_install_units \
        "$main_service" \
        "$(schedule_service_unit_content "VMANGOS scheduled $job_type ($job_id)" "$(schedule_main_exec_args "$job_type" "$job_id")")" \
        "$main_timer" \
        "$(schedule_timer_unit_content "Run VMANGOS scheduled $job_type ($job_id)" "$on_calendar")"

    schedule_enable_timer "$main_timer"

    if [[ "$job_type" == "restart" && -n "$warnings" ]]; then
        schedule_create_warning_units "$job_id" "$schedule_type" "$day" "$time_value" "$timezone" "$warnings"
    fi

    metadata_content=$(schedule_job_metadata_content "$job_id" "$job_type" "$schedule_type" "$time_value" "$day" "$timezone" "$warnings" "$announce_message" "$main_timer")
    schedule_write_metadata "$job_id" "$metadata_content"

    log_info "✓ Scheduled $job_type job: $job_id"
    log_info "Schedule: $(schedule_schedule_label "$schedule_type" "$time_value" "$day" "$timezone")"
    if [[ "$job_type" == "restart" && -n "$warnings" ]]; then
        log_info "Warnings: $warnings"
        if [[ -z "$SCHEDULE_ANNOUNCE_COMMAND" ]]; then
            log_info "Announcement mode: journal-only fallback (no maintenance.announce_command configured)"
        else
            log_info "Announcement mode: command backend"
        fi
    fi
}

schedule_honor() {
    local schedule_type="$1"
    local schedule_value="$2"
    local timezone="${3:-}"
    local day="" time_value="$schedule_value"

    schedule_load_config || return 1

    if [[ -z "$SCHEDULE_HONOR_COMMAND" ]]; then
        log_error "Honor scheduling requires maintenance.honor_command in manager.conf"
        return 1
    fi

    if [[ "$schedule_type" == "weekly" ]]; then
        day="${schedule_value%% *}"
        time_value="${schedule_value##* }"
    fi

    schedule_create_job "honor" "$schedule_type" "$time_value" "$day" "$timezone" "" ""
}

schedule_restart_create() {
    local schedule_type="$1"
    local schedule_value="$2"
    local timezone="$3"
    local warnings="$4"
    local announce_message="$5"
    local day="" time_value="$schedule_value"

    schedule_load_config || return 1

    if [[ -z "$warnings" ]]; then
        warnings="$SCHEDULE_RESTART_WARNINGS"
    fi

    if [[ "$schedule_type" == "weekly" ]]; then
        day="${schedule_value%% *}"
        time_value="${schedule_value##* }"
    fi

    schedule_create_job "restart" "$schedule_type" "$time_value" "$day" "$timezone" "$warnings" "$announce_message"
}

schedule_list_next_run() {
    local timer_name="$1"
    local next_run

    next_run=$(schedule_systemctl show -p NextElapseUSecRealtime "$timer_name" 2>/dev/null | cut -d= -f2- || true)
    printf '%s\n' "$next_run"
}

schedule_list() {
    local metadata_file id job_type schedule_type time_value day timezone warnings announce_message next_run

    schedule_load_config || return 1
    schedule_ensure_state_dir || return 1

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        local rows=()
        for metadata_file in "$SCHEDULE_STATE_DIR"/*.conf; do
            [[ -f "$metadata_file" ]] || continue
            id=$(ini_read "$metadata_file" "job" "id" "")
            job_type=$(ini_read "$metadata_file" "job" "job_type" "")
            schedule_type=$(ini_read "$metadata_file" "job" "schedule_type" "")
            time_value=$(ini_read "$metadata_file" "job" "time" "")
            day=$(ini_read "$metadata_file" "job" "day" "")
            timezone=$(ini_read "$metadata_file" "job" "timezone" "")
            warnings=$(ini_read "$metadata_file" "job" "warnings" "")
            announce_message=$(ini_read "$metadata_file" "job" "announce_message" "")
            next_run=$(schedule_list_next_run "$(ini_read "$metadata_file" "job" "main_timer" "")")
            rows+=("$(json_object \
                "$(json_kvs id "$id")" \
                "$(json_kvs job_type "$job_type")" \
                "$(json_kvs schedule_type "$schedule_type")" \
                "$(json_kvs time "$time_value")" \
                "$(json_kvs day "$day")" \
                "$(json_kvs timezone "$timezone")" \
                "$(json_kvs warnings "$warnings")" \
                "$(json_kvs announce_message "$announce_message")" \
                "$(json_kvs next_run "$next_run")")")
        done
        json_output true "$(json_object \
            "$(json_kv_raw schedules "$(json_array ${rows[@]+"${rows[@]}"})")")"
        return 0
    fi

    echo "VMANGOS Maintenance Schedules"
    echo "State dir: $SCHEDULE_STATE_DIR"
    echo ""

    for metadata_file in "$SCHEDULE_STATE_DIR"/*.conf; do
        [[ -f "$metadata_file" ]] || continue
        id=$(ini_read "$metadata_file" "job" "id" "")
        job_type=$(ini_read "$metadata_file" "job" "job_type" "")
        schedule_type=$(ini_read "$metadata_file" "job" "schedule_type" "")
        time_value=$(ini_read "$metadata_file" "job" "time" "")
        day=$(ini_read "$metadata_file" "job" "day" "")
        timezone=$(ini_read "$metadata_file" "job" "timezone" "")
        warnings=$(ini_read "$metadata_file" "job" "warnings" "")
        announce_message=$(ini_read "$metadata_file" "job" "announce_message" "")
        next_run=$(schedule_list_next_run "$(ini_read "$metadata_file" "job" "main_timer" "")")

        echo "ID: $id"
        echo "  Type: $job_type"
        echo "  Schedule: $(schedule_schedule_label "$schedule_type" "$time_value" "$day" "$timezone")"
        [[ -n "$warnings" ]] && echo "  Warnings: $warnings"
        [[ -n "$announce_message" ]] && echo "  Message: $announce_message"
        [[ -n "$next_run" ]] && echo "  Next run: $next_run"
        echo ""
    done
}

schedule_cancel() {
    local job_id="$1"
    local warning_minutes timer_name service_name item

    check_root
    schedule_load_job "$job_id" || return 1

    schedule_disable_timer "$SCHEDULE_JOB_MAIN_TIMER"
    rm -f "$(schedule_timer_unit_path "$SCHEDULE_JOB_MAIN_TIMER")" "$(schedule_timer_unit_path "$SCHEDULE_JOB_MAIN_SERVICE")"

    if [[ "$SCHEDULE_JOB_TYPE" == "restart" && -n "$SCHEDULE_JOB_WARNINGS" ]]; then
        IFS=',' read -r -a warning_items <<< "$SCHEDULE_JOB_WARNINGS"
        for item in "${warning_items[@]}"; do
            warning_minutes=$(config_trim "$item")
            timer_name=$(schedule_warning_timer_name "$job_id" "$warning_minutes")
            service_name=$(schedule_warning_service_name "$job_id" "$warning_minutes")
            schedule_disable_timer "$timer_name"
            rm -f "$(schedule_timer_unit_path "$timer_name")" "$(schedule_timer_unit_path "$service_name")"
        done
    fi

    schedule_systemctl daemon-reload
    rm -f "$SCHEDULE_JOB_METADATA_PATH"
    log_info "✓ Cancelled scheduled job: $job_id"
}

schedule_simulate() {
    local job_id="$1"
    local item warning_minutes on_calendar

    schedule_load_job "$job_id" || return 1

    echo "VMANGOS Schedule Simulation"
    echo "Job ID: $job_id"
    echo "Type: $SCHEDULE_JOB_TYPE"
    echo "Schedule: $(schedule_schedule_label "$SCHEDULE_JOB_SCHEDULE_TYPE" "$SCHEDULE_JOB_TIME" "$SCHEDULE_JOB_DAY" "$SCHEDULE_JOB_TIMEZONE")"
    echo "Main timer: $SCHEDULE_JOB_MAIN_TIMER"
    echo "Main service: $SCHEDULE_JOB_MAIN_SERVICE"
    echo "Main OnCalendar: $(schedule_build_oncalendar "$SCHEDULE_JOB_SCHEDULE_TYPE" "$SCHEDULE_JOB_TIME" "$SCHEDULE_JOB_DAY" "$SCHEDULE_JOB_TIMEZONE")"

    if [[ "$SCHEDULE_JOB_TYPE" == "restart" ]]; then
        echo "Action: vmangos-manager server restart --timeout 60"
        if [[ -n "$SCHEDULE_JOB_WARNINGS" ]]; then
            echo "Warning timers:"
            IFS=',' read -r -a warning_items <<< "$SCHEDULE_JOB_WARNINGS"
            for item in "${warning_items[@]}"; do
                warning_minutes=$(config_trim "$item")
                on_calendar=$(schedule_build_warning_oncalendar "$SCHEDULE_JOB_SCHEDULE_TYPE" "$SCHEDULE_JOB_DAY" "$SCHEDULE_JOB_TIME" "$warning_minutes" "$SCHEDULE_JOB_TIMEZONE")
                printf '  %sm -> %s (%s)\n' "$warning_minutes" "$(schedule_warning_timer_name "$job_id" "$warning_minutes")" "$on_calendar"
            done
        fi
        if [[ -n "$SCHEDULE_ANNOUNCE_COMMAND" ]]; then
            echo "Announcement backend: configured command"
        else
            echo "Announcement backend: journal-only fallback"
        fi
    else
        echo "Action: maintenance.honor_command"
    fi
}

schedule_run_command() {
    local command="$1"
    shift || true

    if [[ -z "$command" ]]; then
        return 1
    fi

    "$command" "$@"
}

schedule_run_honor() {
    local job_id="$1"

    schedule_load_job "$job_id" || return 1

    if [[ -z "$SCHEDULE_HONOR_COMMAND" ]]; then
        log_error "No maintenance.honor_command configured; cannot execute scheduled honor job"
        return 1
    fi

    log_info "Running scheduled honor job: $job_id"
    schedule_run_command "$SCHEDULE_HONOR_COMMAND" "$job_id"
}

schedule_run_warning() {
    local job_id="$1"
    local warning_minutes="$2"
    local player_count

    schedule_load_job "$job_id" || return 1
    player_count=$(get_online_player_count 2>/dev/null || printf '0')

    if [[ -n "$SCHEDULE_ANNOUNCE_COMMAND" ]]; then
        VMANGOS_SCHEDULE_JOB_ID="$job_id" \
        VMANGOS_SCHEDULE_TYPE="restart-warning" \
        VMANGOS_SCHEDULE_MINUTES="$warning_minutes" \
        VMANGOS_SCHEDULE_MESSAGE="$SCHEDULE_JOB_ANNOUNCE_MESSAGE" \
        VMANGOS_SCHEDULE_PLAYER_COUNT="$player_count" \
            schedule_run_command "$SCHEDULE_ANNOUNCE_COMMAND"
        return $?
    fi

    log_info "Scheduled restart warning: ${warning_minutes}m remaining; players online: $player_count; no announce backend configured"
}

schedule_run_restart() {
    local job_id="$1"
    local player_count

    check_root
    schedule_load_job "$job_id" || return 1
    player_count=$(get_online_player_count 2>/dev/null || printf '0')

    if [[ -n "$SCHEDULE_ANNOUNCE_COMMAND" ]]; then
        VMANGOS_SCHEDULE_JOB_ID="$job_id" \
        VMANGOS_SCHEDULE_TYPE="restart" \
        VMANGOS_SCHEDULE_MINUTES="0" \
        VMANGOS_SCHEDULE_MESSAGE="$SCHEDULE_JOB_ANNOUNCE_MESSAGE" \
        VMANGOS_SCHEDULE_PLAYER_COUNT="$player_count" \
            schedule_run_command "$SCHEDULE_ANNOUNCE_COMMAND"
    else
        log_info "Executing scheduled restart; players online: $player_count; no announce backend configured"
    fi

    server_restart 60
}
