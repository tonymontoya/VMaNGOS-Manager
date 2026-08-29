#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
# shellcheck source=lib/db.sh
#
# Update check module for VMANGOS Manager
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/db.sh"

UPDATE_INSTALL_ROOT=""
UPDATE_SOURCE_ROOT=""
UPDATE_BUILD_ROOT=""
UPDATE_RUN_ROOT=""
UPDATE_DB_PENDING_ENTRIES=()
UPDATE_DB_MANUAL_CHANGES=()
UPDATE_DB_ASSESSMENT_MODE=""
UPDATE_DB_CURRENT_PENDING_COUNT=0
UPDATE_DB_INCOMING_PENDING_COUNT=0
UPDATE_DB_MANUAL_CHANGE_COUNT=0
UPDATE_DB_AUTH_APPLIED_IDS=""
UPDATE_DB_WORLD_APPLIED_IDS=""
UPDATE_DB_LOGS_APPLIED_IDS=""
UPDATE_DB_AUTH_APPLIED_LOADED=0
UPDATE_DB_WORLD_APPLIED_LOADED=0
UPDATE_DB_LOGS_APPLIED_LOADED=0
UPDATE_SOURCE_REPO_ERROR_CODE=""
UPDATE_SOURCE_REPO_ERROR_MESSAGE=""
UPDATE_SOURCE_REPO_ERROR_SUGGESTION=""
UPDATE_SOURCE_REPO_ROOT=""

# Repo state populated by update_collect_repo_state (single source of truth;
# no pipe-delimited records, no re-parsing at call sites).
declare -A UPDATE_REPO_STATE=()
UPDATE_REPO_STATE_ERROR_CODE=""
UPDATE_REPO_STATE_ERROR_MESSAGE=""
UPDATE_REPO_STATE_ERROR_SUGGESTION=""

update_git() {
    git "$@"
}

update_nproc() {
    nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
}

update_find_repo_root() {
    local candidate
    local candidates=()

    if [[ -n "${VMANGOS_MANAGER_REPO:-}" ]]; then
        candidates+=("$VMANGOS_MANAGER_REPO")
    fi

    candidates+=("$(pwd)")

    if [[ -n "${SCRIPT_DIR:-}" ]]; then
        candidates+=("$SCRIPT_DIR/..")
    fi

    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" ]] || continue
        if update_git -C "$candidate" rev-parse --show-toplevel >/dev/null 2>&1; then
            update_git -C "$candidate" rev-parse --show-toplevel
            return 0
        fi
    done

    return 1
}

update_load_install_context() {
    config_load "$CONFIG_FILE" >/dev/null 2>&1 || {
        log_error "Failed to load configuration: $CONFIG_FILE"
        return 1
    }

    UPDATE_INSTALL_ROOT="${CONFIG_SERVER_INSTALL_ROOT:-/opt/mangos}"
    UPDATE_SOURCE_ROOT="$UPDATE_INSTALL_ROOT/source"
    UPDATE_BUILD_ROOT="$UPDATE_INSTALL_ROOT/build"
    UPDATE_RUN_ROOT="$UPDATE_INSTALL_ROOT/run"
}

update_clear_source_repo_error() {
    UPDATE_SOURCE_REPO_ERROR_CODE=""
    UPDATE_SOURCE_REPO_ERROR_MESSAGE=""
    UPDATE_SOURCE_REPO_ERROR_SUGGESTION=""
    UPDATE_SOURCE_REPO_ROOT=""
}

update_set_source_repo_error() {
    UPDATE_SOURCE_REPO_ERROR_CODE="$1"
    UPDATE_SOURCE_REPO_ERROR_MESSAGE="$2"
    UPDATE_SOURCE_REPO_ERROR_SUGGESTION="$3"
}

update_emit_source_repo_error() {
    [[ -n "$UPDATE_SOURCE_REPO_ERROR_CODE" ]] || return 1
    update_emit_error "$UPDATE_SOURCE_REPO_ERROR_CODE" "$UPDATE_SOURCE_REPO_ERROR_MESSAGE" "$UPDATE_SOURCE_REPO_ERROR_SUGGESTION"
}

update_log_source_repo_error() {
    [[ -n "$UPDATE_SOURCE_REPO_ERROR_MESSAGE" ]] || return 1
    log_error "$UPDATE_SOURCE_REPO_ERROR_MESSAGE"
    [[ -n "$UPDATE_SOURCE_REPO_ERROR_SUGGESTION" ]] && log_info "$UPDATE_SOURCE_REPO_ERROR_SUGGESTION"
}

update_get_tracking_ref() {
    local repo_root="$1"
    local upstream_ref

    upstream_ref=$(update_git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)
    if [[ -n "$upstream_ref" ]]; then
        printf '%s\n' "$upstream_ref"
    else
        upstream_ref=$(update_git -C "$repo_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
        if [[ -n "$upstream_ref" ]]; then
            printf '%s\n' "$upstream_ref"
        else
            printf 'origin/main\n'
        fi
    fi
}

update_get_install_target() {
    config_load "$CONFIG_FILE" >/dev/null 2>&1 || true
    config_resolve_manager_root "$CONFIG_FILE"
}

update_build_manual_instructions() {
    local repo_root="$1"
    local remote_ref="$2"
    local install_target="$3"
    local remote_name remote_branch

    remote_name="${remote_ref%%/*}"
    remote_branch="${remote_ref#*/}"

    printf 'cd %s\n' "$repo_root"
    printf 'git fetch %s\n' "$remote_name"
    printf 'git log --oneline HEAD..%s\n' "$remote_ref"
    printf 'git checkout %s\n' "$remote_branch"
    printf 'git pull --ff-only %s %s\n' "$remote_name" "$remote_branch"
    printf 'cd %s/manager\n' "$repo_root"
    printf 'make test\n'
    printf 'sudo make install PREFIX=%s\n' "$install_target"
}

update_get_source_repo_root() {
    local output

    if [[ -z "$UPDATE_SOURCE_ROOT" ]]; then
        update_load_install_context || return 1
    fi

    update_clear_source_repo_error

    if output=$(update_git -C "$UPDATE_SOURCE_ROOT" rev-parse --show-toplevel 2>&1); then
        UPDATE_SOURCE_REPO_ROOT="$output"
        return 0
    fi

    if [[ "$output" == *"detected dubious ownership"* ]] || [[ "$output" == *"safe.directory"* ]]; then
        update_set_source_repo_error \
            "SOURCE_REPO_UNSAFE" \
            "Configured VMANGOS source tree is blocked by Git safe.directory protection" \
            "Run 'git config --global --add safe.directory $UPDATE_SOURCE_ROOT' as the invoking user, or run Manager as the repository owner"
        return 1
    fi

    if [[ "$output" == *"cannot change to"* ]] || [[ "$output" == *"No such file or directory"* ]]; then
        update_set_source_repo_error \
            "SOURCE_REPO_MISSING" \
            "Configured VMANGOS source tree is missing" \
            "Verify $UPDATE_SOURCE_ROOT exists and contains the VMANGOS core repository"
        return 1
    fi

    update_set_source_repo_error \
        "SOURCE_REPO_MISSING" \
        "Configured VMANGOS source tree is not a git checkout" \
        "Verify $UPDATE_SOURCE_ROOT exists and contains the VMANGOS core repository"
    return 1
}

update_try_source_repo_root() {
    update_clear_source_repo_error

    if ! update_load_install_context >/dev/null 2>&1; then
        return 1
    fi

    if update_get_source_repo_root; then
        return 0
    fi

    if [[ "$UPDATE_SOURCE_REPO_ERROR_CODE" == "SOURCE_REPO_UNSAFE" ]]; then
        return 1
    fi

    update_clear_source_repo_error
    return 1
}

update_repo_state_set_error() {
    UPDATE_REPO_STATE_ERROR_CODE="$1"
    UPDATE_REPO_STATE_ERROR_MESSAGE="$2"
    UPDATE_REPO_STATE_ERROR_SUGGESTION="$3"
    log_error "$UPDATE_REPO_STATE_ERROR_MESSAGE"
}

update_collect_repo_state() {
    local repo_root="$1"
    local current_branch remote_ref remote_name remote_branch local_commit remote_commit commits_behind commits_ahead dirty_state

    UPDATE_REPO_STATE_ERROR_CODE=""
    UPDATE_REPO_STATE_ERROR_MESSAGE=""
    UPDATE_REPO_STATE_ERROR_SUGGESTION=""

    current_branch=$(update_git -C "$repo_root" rev-parse --abbrev-ref HEAD) || {
        update_repo_state_set_error "GIT_ERROR" "Failed to determine current branch for $repo_root" "Check that the repository is readable"
        return 1
    }

    remote_ref=$(update_get_tracking_ref "$repo_root")
    remote_name="${remote_ref%%/*}"
    remote_branch="${remote_ref#*/}"

    if ! update_git -C "$repo_root" fetch --quiet "$remote_name"; then
        update_repo_state_set_error "FETCH_FAILED" "Failed to fetch remote metadata from $remote_name for $repo_root" "Check git remote access and retry"
        return 1
    fi

    if ! update_git -C "$repo_root" rev-parse "$remote_ref^{commit}" >/dev/null 2>&1; then
        update_repo_state_set_error "REMOTE_REF_NOT_FOUND" "Unable to resolve remote reference: $remote_ref" "Check the configured branch and remote tracking setup"
        return 1
    fi

    local_commit=$(update_git -C "$repo_root" rev-parse HEAD)
    remote_commit=$(update_git -C "$repo_root" rev-parse "$remote_ref")
    commits_behind=$(update_git -C "$repo_root" rev-list --count "HEAD..$remote_ref")
    commits_ahead=$(update_git -C "$repo_root" rev-list --count "$remote_ref..HEAD")

    if [[ -n "$(update_git -C "$repo_root" status --porcelain)" ]]; then
        dirty_state="dirty"
    else
        dirty_state="clean"
    fi

    UPDATE_REPO_STATE[current_branch]="$current_branch"
    UPDATE_REPO_STATE[remote_ref]="$remote_ref"
    UPDATE_REPO_STATE[remote_name]="$remote_name"
    UPDATE_REPO_STATE[remote_branch]="$remote_branch"
    UPDATE_REPO_STATE[local_commit]="$local_commit"
    UPDATE_REPO_STATE[remote_commit]="$remote_commit"
    UPDATE_REPO_STATE[commits_behind]="$commits_behind"
    UPDATE_REPO_STATE[commits_ahead]="$commits_ahead"
    UPDATE_REPO_STATE[dirty_state]="$dirty_state"

    return 0
}

update_reset_db_assessment() {
    UPDATE_DB_PENDING_ENTRIES=()
    UPDATE_DB_MANUAL_CHANGES=()
    UPDATE_DB_ASSESSMENT_MODE=""
    UPDATE_DB_CURRENT_PENDING_COUNT=0
    UPDATE_DB_INCOMING_PENDING_COUNT=0
    UPDATE_DB_MANUAL_CHANGE_COUNT=0
}

update_db_role_label() {
    case "$1" in
        auth) printf 'auth\n' ;;
        world) printf 'world\n' ;;
        logs) printf 'logs\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

update_parse_migration_path() {
    local path="$1"

    if [[ "$path" =~ ^sql/migrations/([0-9]{14})_(world|logon|logs)\.sql$ ]]; then
        printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    return 1
}

update_role_from_migration_suffix() {
    case "$1" in
        world) printf 'world\n' ;;
        logon) printf 'auth\n' ;;
        logs) printf 'logs\n' ;;
        *)
            log_error "Unknown migration suffix: $1"
            return 1
            ;;
    esac
}

update_list_current_migration_files() {
    local repo_root="$1"
    local migrations_dir="$repo_root/sql/migrations"
    local file

    [[ -d "$migrations_dir" ]] || return 0

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        printf '%s\n' "${file#"$repo_root"/}"
    done < <(find "$migrations_dir" -maxdepth 1 -type f -name '*.sql' | sort)
}

update_collect_sql_change_status() {
    local repo_root="$1"
    local remote_ref="$2"

    [[ -n "$remote_ref" ]] || return 0

    update_git -C "$repo_root" diff --name-status --find-renames "HEAD..$remote_ref" -- sql
}

update_get_cached_applied_ids() {
    case "$1" in
        auth) printf '%s' "$UPDATE_DB_AUTH_APPLIED_IDS" ;;
        world) printf '%s' "$UPDATE_DB_WORLD_APPLIED_IDS" ;;
        logs) printf '%s' "$UPDATE_DB_LOGS_APPLIED_IDS" ;;
        *)
            log_error "Unknown DB role: $1"
            return 1
            ;;
    esac
}

update_load_applied_migrations_for_role() {
    local role="$1"
    local database table_name ids

    case "$role" in
        auth)
            [[ "$UPDATE_DB_AUTH_APPLIED_LOADED" -eq 0 ]] || return 0
            ;;
        world)
            [[ "$UPDATE_DB_WORLD_APPLIED_LOADED" -eq 0 ]] || return 0
            ;;
        logs)
            [[ "$UPDATE_DB_LOGS_APPLIED_LOADED" -eq 0 ]] || return 0
            ;;
        *)
            log_error "Unknown DB role: $role"
            return 1
            ;;
    esac

    database=$(db_name_for_role "$role") || return 1

    if ! table_name=$(db_query "$database" "SHOW TABLES LIKE 'migrations';" 2>/dev/null); then
        log_error "Failed to inspect migrations table in database: $database"
        return 1
    fi

    if [[ "$table_name" != "migrations" ]]; then
        log_error "Database $database does not expose a migrations table"
        return 1
    fi

    if ! ids=$(db_query "$database" "SELECT id FROM migrations ORDER BY id;" 2>/dev/null); then
        log_error "Failed to read applied migrations from database: $database"
        return 1
    fi

    case "$role" in
        auth)
            UPDATE_DB_AUTH_APPLIED_IDS="$ids"
            UPDATE_DB_AUTH_APPLIED_LOADED=1
            ;;
        world)
            UPDATE_DB_WORLD_APPLIED_IDS="$ids"
            UPDATE_DB_WORLD_APPLIED_LOADED=1
            ;;
        logs)
            UPDATE_DB_LOGS_APPLIED_IDS="$ids"
            UPDATE_DB_LOGS_APPLIED_LOADED=1
            ;;
    esac
}

update_preload_applied_migrations() {
    update_load_applied_migrations_for_role auth || return 1
    update_load_applied_migrations_for_role world || return 1
    update_load_applied_migrations_for_role logs || return 1
}

update_text_has_exact_line() {
    local text="$1"
    local needle="$2"

    [[ -n "$text" ]] || return 1
    printf '%s\n' "$text" | grep -Fqx "$needle"
}

update_add_db_pending_entry() {
    local source="$1"
    local role="$2"
    local migration_id="$3"
    local path="$4"
    local entry="$source|$role|$migration_id|$path"
    local existing

    for existing in "${UPDATE_DB_PENDING_ENTRIES[@]}"; do
        if [[ "$existing" == "$entry" ]]; then
            return 0
        fi
    done

    UPDATE_DB_PENDING_ENTRIES+=("$entry")
    if [[ "$source" == "incoming" ]]; then
        UPDATE_DB_INCOMING_PENDING_COUNT=$((UPDATE_DB_INCOMING_PENDING_COUNT + 1))
    else
        UPDATE_DB_CURRENT_PENDING_COUNT=$((UPDATE_DB_CURRENT_PENDING_COUNT + 1))
    fi
}

update_add_db_manual_change() {
    local path="$1"
    local reason="$2"
    local entry="$path|$reason"
    local existing

    for existing in "${UPDATE_DB_MANUAL_CHANGES[@]}"; do
        if [[ "$existing" == "$entry" ]]; then
            return 0
        fi
    done

    UPDATE_DB_MANUAL_CHANGES+=("$entry")
    UPDATE_DB_MANUAL_CHANGE_COUNT=$((UPDATE_DB_MANUAL_CHANGE_COUNT + 1))
}

update_assess_db_requirements() {
    local repo_root="$1"
    local remote_ref="${2:-}"
    local migration_path parsed migration_id suffix role applied_ids
    local change_line status path_a path_b final_path

    update_reset_db_assessment
    update_preload_applied_migrations || return 1

    while IFS= read -r migration_path; do
        [[ -n "$migration_path" ]] || continue
        parsed=$(update_parse_migration_path "$migration_path" || true)
        [[ -n "$parsed" ]] || continue
        IFS='|' read -r migration_id suffix <<< "$parsed"
        role=$(update_role_from_migration_suffix "$suffix") || return 1
        applied_ids=$(update_get_cached_applied_ids "$role") || return 1
        if ! update_text_has_exact_line "$applied_ids" "$migration_id"; then
            update_add_db_pending_entry "current" "$role" "$migration_id" "$migration_path"
        fi
    done < <(update_list_current_migration_files "$repo_root")

    while IFS= read -r change_line; do
        [[ -n "$change_line" ]] || continue

        IFS=$'\t' read -r status path_a path_b <<< "$change_line"
        final_path="$path_a"
        if [[ "$status" == R* ]]; then
            final_path="$path_b"
        fi

        [[ "$final_path" == sql/* ]] || continue

        parsed=$(update_parse_migration_path "$final_path" || true)
        if [[ -n "$parsed" ]]; then
            if [[ "$status" == "A" ]]; then
                IFS='|' read -r migration_id suffix <<< "$parsed"
                role=$(update_role_from_migration_suffix "$suffix") || return 1
                applied_ids=$(update_get_cached_applied_ids "$role") || return 1
                if ! update_text_has_exact_line "$applied_ids" "$migration_id"; then
                    update_add_db_pending_entry "incoming" "$role" "$migration_id" "$final_path"
                fi
            else
                update_add_db_manual_change "$final_path" "Unsupported migration file change status: $status"
            fi
            continue
        fi

        update_add_db_manual_change "$final_path" "SQL change requires manual review"
    done < <(update_collect_sql_change_status "$repo_root" "$remote_ref")

    if [[ ${#UPDATE_DB_MANUAL_CHANGES[@]} -gt 0 ]]; then
        UPDATE_DB_ASSESSMENT_MODE="manual_review_required"
    elif [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -gt 0 ]]; then
        UPDATE_DB_ASSESSMENT_MODE="schema_migrations_pending"
    else
        UPDATE_DB_ASSESSMENT_MODE="no_db_action_required"
    fi
}

update_db_pending_entries_json() {
    local entry source role migration_id path database rows=()

    if [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -eq 0 ]]; then
        printf '[]'
        return 0
    fi

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r source role migration_id path <<< "$entry"
        database=$(db_name_for_role "$role") || return 1
        rows+=("$(json_object \
            "$(json_kvs source "$source")" \
            "$(json_kvs role "$role")" \
            "$(json_kvs database "$database")" \
            "$(json_kvs id "$migration_id")" \
            "$(json_kvs path "$path")")")
    done < <(printf '%s\n' "${UPDATE_DB_PENDING_ENTRIES[@]}" | sort)

    json_array ${rows[@]+"${rows[@]}"}
}

update_db_manual_changes_json() {
    local entry path reason rows=()

    if [[ ${#UPDATE_DB_MANUAL_CHANGES[@]} -eq 0 ]]; then
        printf '[]'
        return 0
    fi

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r path reason <<< "$entry"
        rows+=("$(json_object \
            "$(json_kvs path "$path")" \
            "$(json_kvs reason "$reason")")")
    done < <(printf '%s\n' "${UPDATE_DB_MANUAL_CHANGES[@]}" | sort)

    json_array ${rows[@]+"${rows[@]}"}
}

update_emit_db_inspect_result() {
    local automation_supported=true
    local entry source role migration_id path reason database
    local members=() lines=()

    if [[ "$UPDATE_DB_ASSESSMENT_MODE" == "manual_review_required" ]]; then
        automation_supported=false
    fi

    mapfile -t members <<< "$(update_repo_state_json_fields source_repo 1)"
    members+=(
        "$(json_kvs target "vmangos-core")"
        "$(json_kv_raw db_assessment "$(json_string "$UPDATE_DB_ASSESSMENT_MODE")")"
        "$(json_kv_raw db_automation_supported "$(json_bool "$automation_supported")")"
        "$(json_kv_raw pending_migrations "$(update_db_pending_entries_json)")"
        "$(json_kv_raw manual_review "$(update_db_manual_changes_json)")"
    )

    mapfile -t lines <<< "$(update_repo_state_text_fields "Source repo" 1)"
    lines+=(
        "DB assessment: $UPDATE_DB_ASSESSMENT_MODE"
        "DB automation supported: $automation_supported"
    )

    if [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -gt 0 ]]; then
        lines+=("")
        lines+=("Pending supported migrations:")
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            IFS='|' read -r source role migration_id path <<< "$entry"
            database=$(db_name_for_role "$role") || return 1
            lines+=("  [$source] $(update_db_role_label "$role") $migration_id -> $database ($path)")
        done < <(printf '%s\n' "${UPDATE_DB_PENDING_ENTRIES[@]}" | sort)
    else
        lines+=("")
        lines+=("Pending supported migrations: none")
    fi

    if [[ ${#UPDATE_DB_MANUAL_CHANGES[@]} -gt 0 ]]; then
        lines+=("")
        lines+=("Manual DB review required:")
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            IFS='|' read -r path reason <<< "$entry"
            lines+=("  $path - $reason")
        done < <(printf '%s\n' "${UPDATE_DB_MANUAL_CHANGES[@]}" | sort)
    fi

    update_emit_snapshot "VMANGOS Core DB Update Inspect" "${members[@]}" <<< "$(printf '%s\n' "${lines[@]}")"
}

update_build_db_steps() {
    local entry source role migration_id path database

    if [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -eq 0 ]]; then
        return 0
    fi

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r source role migration_id path <<< "$entry"
        database=$(db_name_for_role "$role") || return 1
        printf 'Apply migration %s to %s database (%s) from %s\n' "$migration_id" "$(update_db_role_label "$role")" "$database" "$path"
    done < <(printf '%s\n' "${UPDATE_DB_PENDING_ENTRIES[@]}" | sort)
}

update_build_core_steps() {
    local source_root="$1"
    local remote_ref="$2"
    local build_root="$3"
    local install_root="$4"
    local jobs="$5"
    local backup_mode="$6"

    if [[ "$backup_mode" == "backup-first" ]]; then
        printf 'vmangos-manager backup now --verify\n'
    else
        printf 'Confirm an existing verified backup before apply\n'
    fi
    printf 'vmangos-manager server stop --graceful\n'
    printf 'git -C %s pull --ff-only %s %s\n' "$source_root" "${remote_ref%%/*}" "${remote_ref#*/}"
    printf 'cmake -S %s -B %s -DCMAKE_INSTALL_PREFIX=%s/run -DCONF_DIR=%s/run/etc -DBUILD_EXTRACTORS=1 -DDEBUG=0\n' \
        "$source_root" "$build_root" "$install_root" "$install_root"
    printf 'make -C %s -j %s\n' "$build_root" "$jobs"
    printf 'make -C %s install\n' "$build_root"
    printf 'vmangos-manager server start --wait\n'
    printf 'vmangos-manager server status\n'
}

update_instructions_json() {
    local instructions_text="$1"
    local line
    local json_lines=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        json_lines+=("$(json_string "$line")")
    done <<< "$instructions_text"

    json_array ${json_lines[@]+"${json_lines[@]}"}
}

# Common repo-state JSON members. <repo_key> is the payload key for the repo
# path (repo_root|source_repo|target); build_dir/run_dir members are added
# when install roots are known; commits_ahead when <with_ahead> is 1.
update_repo_state_json_fields() {
    local repo_key="$1"
    local with_ahead="$2"
    local repo_root="${3:-$UPDATE_SOURCE_REPO_ROOT}"

    json_kvs "$repo_key" "$repo_root"
    if [[ -n "$UPDATE_BUILD_ROOT" ]]; then
        printf '\n%s' "$(json_kvs build_dir "$UPDATE_BUILD_ROOT")"
    fi
    if [[ -n "$UPDATE_RUN_ROOT" ]]; then
        printf '\n%s' "$(json_kvs run_dir "$UPDATE_RUN_ROOT")"
    fi
    printf '\n%s' "$(json_kvs branch "${UPDATE_REPO_STATE[current_branch]}")"
    printf '\n%s' "$(json_kvs remote_ref "${UPDATE_REPO_STATE[remote_ref]}")"
    printf '\n%s' "$(json_kvs local_commit "${UPDATE_REPO_STATE[local_commit]}")"
    printf '\n%s' "$(json_kvs remote_commit "${UPDATE_REPO_STATE[remote_commit]}")"
    printf '\n%s' "$(json_kv_raw commits_behind "${UPDATE_REPO_STATE[commits_behind]}")"
    if [[ "$with_ahead" == "1" ]]; then
        printf '\n%s' "$(json_kv_raw commits_ahead "${UPDATE_REPO_STATE[commits_ahead]}")"
    fi
    printf '\n%s' "$(json_kv_raw worktree_dirty "$(json_bool "$( [[ "${UPDATE_REPO_STATE[dirty_state]}" == "dirty" ]] && echo true)")")"
}

# Common repo-state text lines (must mirror update_repo_state_json_fields).
update_repo_state_text_fields() {
    local repo_label="$1"
    local with_ahead="$2"
    local repo_root="${3:-$UPDATE_SOURCE_REPO_ROOT}"

    printf '%s: %s\n' "$repo_label" "$repo_root"
    if [[ -n "$UPDATE_BUILD_ROOT" ]]; then
        printf 'Build dir: %s\n' "$UPDATE_BUILD_ROOT"
    fi
    if [[ -n "$UPDATE_RUN_ROOT" ]]; then
        printf 'Run dir: %s\n' "$UPDATE_RUN_ROOT"
    fi
    printf 'Branch: %s\n' "${UPDATE_REPO_STATE[current_branch]}"
    printf 'Tracking: %s\n' "${UPDATE_REPO_STATE[remote_ref]}"
    printf 'Local commit: %s\n' "${UPDATE_REPO_STATE[local_commit]}"
    printf 'Remote commit: %s\n' "${UPDATE_REPO_STATE[remote_commit]}"
    printf 'Commits behind: %s\n' "${UPDATE_REPO_STATE[commits_behind]}"
    if [[ "$with_ahead" == "1" ]]; then
        printf 'Commits ahead: %s\n' "${UPDATE_REPO_STATE[commits_ahead]}"
    fi
    printf 'Worktree: %s\n' "${UPDATE_REPO_STATE[dirty_state]}"
}

# The single success emitter: JSON members as arguments, text body on stdin.
update_emit_snapshot() {
    local title="$1"
    shift

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "$(json_object "$@")"
        return 0
    fi

    echo "$title"
    local line
    while IFS= read -r line; do
        printf '%s\n' "$line"
    done
}

update_print_lines() {
    local text="$1"
    local line

    while IFS= read -r line; do
        printf '  %s\n' "$line"
    done <<< "$text"
}

update_emit_result() {
    local repo_root="$1"
    local install_target="$2"
    local instructions_text status_text line
    local members=() lines=()

    instructions_text=$(update_build_manual_instructions "$repo_root" "${UPDATE_REPO_STATE[remote_ref]}" "$install_target")

    if [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]]; then
        status_text="update available"
    else
        status_text="up to date"
    fi

    mapfile -t members <<< "$(update_repo_state_json_fields repo_root 0 "$repo_root")"
    members+=(
        "$(json_kv_raw update_available "$(json_bool "$( [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]] && echo true)")")"
        "$(json_kvs install_target "$install_target")"
        "$(json_kv_raw instructions "$(update_instructions_json "$instructions_text")")"
    )

    mapfile -t lines <<< "$(update_repo_state_text_fields "Repository" 0 "$repo_root")"
    lines+=("Status: $status_text")

    if [[ "${UPDATE_REPO_STATE[dirty_state]}" == "dirty" ]]; then
        lines+=("")
        lines+=("Warning: local changes are present. Review them before applying any update.")
    fi

    lines+=("")
    lines+=("Manual update steps (non-atomic):")
    while IFS= read -r line; do
        lines+=("  $line")
    done <<< "$instructions_text"

    update_emit_snapshot "VMANGOS Manager Update Check" "${members[@]}" <<< "$(printf '%s\n' "${lines[@]}")"
}

update_emit_plan_result() {
    local steps_text="$1"
    local warning_text="$2"
    local line
    local members=() lines=()

    mapfile -t members <<< "$(update_repo_state_json_fields source_repo 1)"
    members+=(
        "$(json_kv_raw update_available "$(json_bool "$( [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]] && echo true)")")"
        "$(json_kv_raw backup_required "$(json_bool true)")"
        "$(json_kvs warning "$warning_text")"
        "$(json_kv_raw steps "$(update_instructions_json "$steps_text")")"
    )

    mapfile -t lines <<< "$(update_repo_state_text_fields "Source repo" 1)"
    lines+=("Backup required: yes")
    if [[ -n "$warning_text" ]]; then
        lines+=("")
        lines+=("Warning: $warning_text")
    fi
    lines+=("")
    lines+=("Planned steps (non-atomic):")
    while IFS= read -r line; do
        lines+=("  $line")
    done <<< "$steps_text"
    lines+=("")
    lines+=("Recovery note: database migrations are one-way unless upstream explicitly documents rollback.")

    update_emit_snapshot "VMANGOS Core Update Plan" "${members[@]}" <<< "$(printf '%s\n' "${lines[@]}")"
}

update_emit_source_check_result() {
    local status_text next_steps warning_text line
    local members=() lines=()

    if [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]]; then
        status_text="update available"
    else
        status_text="up to date"
    fi

    warning_text=""
    if [[ "${UPDATE_REPO_STATE[dirty_state]}" == "dirty" ]]; then
        warning_text="Local changes are present in the VMANGOS source tree."
    elif [[ "${UPDATE_REPO_STATE[commits_ahead]}" -gt 0 ]]; then
        warning_text="Local commits are ahead of the tracked remote."
    fi

    next_steps=$'vmangos-manager update plan\nvmangos-manager update apply --backup-first'

    mapfile -t members <<< "$(update_repo_state_json_fields source_repo 1)"
    members+=(
        "$(json_kvs target "vmangos-core")"
        "$(json_kv_raw update_available "$(json_bool "$( [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]] && echo true)")")"
        "$(json_kvs warning "$warning_text")"
        "$(json_kv_raw next_steps "$(update_instructions_json "$next_steps")")"
    )

    mapfile -t lines <<< "$(update_repo_state_text_fields "Source repo" 1)"
    lines+=("Status: $status_text")

    if [[ -n "$warning_text" ]]; then
        lines+=("")
        lines+=("Warning: $warning_text")
    fi

    lines+=("")
    lines+=("Next steps:")
    while IFS= read -r line; do
        lines+=("  $line")
    done <<< "$next_steps"

    update_emit_snapshot "VMANGOS Core Update Check" "${members[@]}" <<< "$(printf '%s\n' "${lines[@]}")"
}

update_emit_db_plan_result() {
    local steps_text="$1"
    local warning_text="$2"
    local automation_supported=true
    local entry path reason line
    local members=() lines=()

    if [[ "$UPDATE_DB_ASSESSMENT_MODE" == "manual_review_required" ]]; then
        automation_supported=false
    fi

    mapfile -t members <<< "$(update_repo_state_json_fields source_repo 1)"
    members+=(
        "$(json_kv_raw backup_required "$(json_bool true)")"
        "$(json_kv_raw db_assessment "$(json_string "$UPDATE_DB_ASSESSMENT_MODE")")"
        "$(json_kv_raw db_automation_supported "$(json_bool "$automation_supported")")"
        "$(json_kv_raw pending_migrations "$(update_db_pending_entries_json)")"
        "$(json_kv_raw manual_review "$(update_db_manual_changes_json)")"
        "$(json_kvs warning "$warning_text")"
        "$(json_kv_raw steps "$(update_instructions_json "$steps_text")")"
    )

    mapfile -t lines <<< "$(update_repo_state_text_fields "Source repo" 1)"
    lines+=(
        "Backup required: yes"
        "DB assessment: $UPDATE_DB_ASSESSMENT_MODE"
        "DB automation supported: $automation_supported"
    )
    if [[ -n "$warning_text" ]]; then
        lines+=("")
        lines+=("Warning: $warning_text")
    fi
    lines+=("")
    if [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -gt 0 ]]; then
        lines+=("Pending supported migrations:")
        while IFS= read -r line; do
            lines+=("  $line")
        done < <(update_build_db_steps)
        lines+=("")
    fi
    if [[ ${#UPDATE_DB_MANUAL_CHANGES[@]} -gt 0 ]]; then
        lines+=("Manual DB review required:")
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            IFS='|' read -r path reason <<< "$entry"
            lines+=("  $path - $reason")
        done < <(printf '%s\n' "${UPDATE_DB_MANUAL_CHANGES[@]}" | sort)
        lines+=("")
    fi
    lines+=("Planned steps:")
    while IFS= read -r line; do
        lines+=("  $line")
    done <<< "$steps_text"

    update_emit_snapshot "VMANGOS Core DB-Aware Update Plan" "${members[@]}" <<< "$(printf '%s\n' "${lines[@]}")"
}

update_emit_error() {
    local code="$1"
    local message="$2"
    local suggestion="$3"

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output false "null" "$code" "$message" "$suggestion"
    else
        log_error "$message"
        [[ -n "$suggestion" ]] && log_info "$suggestion"
    fi
}

update_build_apply_steps() {
    local source_root="$1"
    local remote_ref="$2"
    local build_root="$3"
    local install_root="$4"
    local jobs="$5"
    local backup_mode="$6"
    local include_db="$7"
    local commits_behind="$8"

    if [[ "$backup_mode" == "backup-first" ]]; then
        printf 'vmangos-manager backup now --verify\n'
    else
        printf 'Confirm an existing verified backup before apply\n'
    fi

    printf 'vmangos-manager server stop --graceful\n'

    if [[ "$commits_behind" -gt 0 ]]; then
        printf 'git -C %s pull --ff-only %s %s\n' "$source_root" "${remote_ref%%/*}" "${remote_ref#*/}"
    fi

    if [[ "$include_db" == "true" ]] && [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -gt 0 ]]; then
        update_build_db_steps
    fi

    if [[ "$commits_behind" -gt 0 ]]; then
        printf 'cmake -S %s -B %s -DCMAKE_INSTALL_PREFIX=%s/run -DCONF_DIR=%s/run/etc -DBUILD_EXTRACTORS=1 -DDEBUG=0\n' \
            "$source_root" "$build_root" "$install_root" "$install_root"
        printf 'make -C %s -j %s\n' "$build_root" "$jobs"
        printf 'make -C %s install\n' "$build_root"
    fi

    printf 'vmangos-manager server start --wait\n'
    printf 'vmangos-manager server status\n'
}

update_apply_pending_db_migrations() {
    local repo_root="$1"
    local entry source role migration_id path database full_path

    [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -gt 0 ]] || return 0

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r source role migration_id path <<< "$entry"
        database=$(db_name_for_role "$role") || return 1
        full_path="$repo_root/$path"

        if [[ ! -f "$full_path" ]]; then
            log_error "Migration file not found after update pull: $full_path"
            return 1
        fi

        log_info "Applying $(update_db_role_label "$role") migration $migration_id to $database"
        if ! db_exec_file "$database" "$full_path"; then
            log_error "Failed applying migration $migration_id from $path"
            return 1
        fi
    done < <(printf '%s\n' "${UPDATE_DB_PENDING_ENTRIES[@]}" | sort)
}

update_confirm_existing_backup() {
    local response

    if [[ "${VMANGOS_UPDATE_CONFIRM_BACKUP:-}" == "yes" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_error "Refusing to apply update without backup confirmation in non-interactive mode"
        log_info "Create a verified backup first or rerun with --backup-first"
        return 1
    fi

    echo "This update workflow is non-atomic and may require manual restore if it fails."
    read -r -p "Type YES to confirm you already have a verified backup: " response
    [[ "$response" == "YES" ]]
}

update_run_cmake() {
    local source_root="$1"
    local build_root="$2"
    local install_root="$3"

    cmake -S "$source_root" -B "$build_root" \
        -DCMAKE_INSTALL_PREFIX="$install_root/run" \
        -DCONF_DIR="$install_root/run/etc" \
        -DBUILD_EXTRACTORS=1 \
        -DDEBUG=0
}

update_run_make_build() {
    local build_root="$1"
    local jobs="$2"

    make -C "$build_root" -j "$jobs"
}

update_run_make_install() {
    local build_root="$1"

    make -C "$build_root" install
}

update_post_apply_verify() {
    server_load_config || return 1

    if ! service_active "$AUTH_SERVICE"; then
        log_error "Auth service is not active after update"
        return 1
    fi

    if ! service_active "$WORLD_SERVICE"; then
        log_error "World service is not active after update"
        return 1
    fi

    if ! db_check_connection; then
        log_error "Database connectivity check failed after update"
        return 1
    fi

    return 0
}

update_print_recovery_steps() {
    local source_root="$1"
    local previous_commit="$2"

    log_info "Manual recovery guidance:"
    log_info "  Review build and service logs before restarting anything"
    log_info "  cd $source_root && git status && git log --oneline -n 5"
    log_info "  If needed, inspect the pre-update commit: $previous_commit"
    log_info "  If binaries remain usable, restart services with: vmangos-manager server start --wait"
    log_info "  If the upgrade changed data incompatibly, restore from a verified backup using vmangos-manager backup restore <file>"
}

update_check() {
    local repo_root install_target
    local source_repo_root

    if update_try_source_repo_root; then
        source_repo_root="$UPDATE_SOURCE_REPO_ROOT"
        update_load_install_context >/dev/null 2>&1 || true
        update_collect_repo_state "$source_repo_root" || {
            update_emit_error "SOURCE_GIT_ERROR" "Failed to inspect the VMANGOS source repository" "Check git remote access and repository health"
            return 1
        }
        update_emit_source_check_result
        return 0
    fi

    if [[ -n "$UPDATE_SOURCE_REPO_ERROR_CODE" ]]; then
        update_emit_source_repo_error
        return 1
    fi

    repo_root=$(update_find_repo_root) || {
        update_emit_error "NOT_A_GIT_REPO" \
            "Update check requires either a configured VMANGOS source tree or a VMANGOS-Manager git checkout" \
            "Run the command on an installed host with a valid config, from a source checkout, or set VMANGOS_MANAGER_REPO"
        return 1
    }

    if ! update_collect_repo_state "$repo_root"; then
        update_emit_error "$UPDATE_REPO_STATE_ERROR_CODE" "$UPDATE_REPO_STATE_ERROR_MESSAGE" "$UPDATE_REPO_STATE_ERROR_SUGGESTION"
        return 1
    fi

    install_target=$(update_get_install_target)
    update_emit_result "$repo_root" "$install_target"
}

update_inspect() {
    local repo_root

    update_load_install_context || {
        update_emit_error "CONFIG_ERROR" "Failed to load manager configuration" "Check config file exists and is readable"
        return 1
    }

    if ! update_get_source_repo_root; then
        update_emit_source_repo_error
        return 1
    fi
    repo_root="$UPDATE_SOURCE_REPO_ROOT"

    update_collect_repo_state "$repo_root" || {
        update_emit_error "SOURCE_GIT_ERROR" "Failed to inspect the VMANGOS source repository" "Check git remote access and repository health"
        return 1
    }

    update_assess_db_requirements "$repo_root" "${UPDATE_REPO_STATE[remote_ref]}" || {
        update_emit_error "DB_ASSESSMENT_FAILED" "Failed to assess DB update requirements" "Verify DB connectivity, migrations tables, and manager DB configuration"
        return 1
    }

    update_emit_db_inspect_result
}

update_plan() {
    local include_db="${1:-false}"
    local repo_root warning_text steps_text

    update_load_install_context || {
        update_emit_error "CONFIG_ERROR" "Failed to load manager configuration" "Check config file exists and is readable"
        return 1
    }

    if ! update_get_source_repo_root; then
        update_emit_source_repo_error
        return 1
    fi
    repo_root="$UPDATE_SOURCE_REPO_ROOT"

    update_collect_repo_state "$repo_root" || {
        update_emit_error "SOURCE_GIT_ERROR" "Failed to inspect the VMANGOS source repository" "Check git remote access and repository health"
        return 1
    }

    warning_text=""
    if [[ "${UPDATE_REPO_STATE[dirty_state]}" == "dirty" ]]; then
        warning_text="Local changes are present in the VMANGOS source tree. update apply will refuse to continue until the tree is clean."
    elif [[ "${UPDATE_REPO_STATE[commits_ahead]}" -gt 0 ]]; then
        warning_text="Local commits are ahead of the tracked remote. update apply will refuse to overwrite a divergent source tree."
    elif [[ "${UPDATE_REPO_STATE[commits_behind]}" -eq 0 ]]; then
        warning_text="No upstream update is currently pending."
    fi

    if [[ "$include_db" == "true" ]]; then
        update_assess_db_requirements "$repo_root" "${UPDATE_REPO_STATE[remote_ref]}" || {
            update_emit_error "DB_ASSESSMENT_FAILED" "Failed to assess DB update requirements" "Verify DB connectivity, migrations tables, and manager DB configuration"
            return 1
        }

        if [[ "$UPDATE_DB_ASSESSMENT_MODE" == "manual_review_required" ]]; then
            if [[ -n "$warning_text" ]]; then
                warning_text="$warning_text DB-related SQL changes require manual review before any DB mutation."
            else
                warning_text="DB-related SQL changes require manual review before any DB mutation."
            fi
        elif [[ "$UPDATE_DB_ASSESSMENT_MODE" == "schema_migrations_pending" ]]; then
            if [[ -n "$warning_text" ]]; then
                warning_text="$warning_text Supported DB migrations are pending."
            else
                warning_text="Supported DB migrations are pending."
            fi
        fi

        steps_text=$(update_build_apply_steps "$repo_root" "${UPDATE_REPO_STATE[remote_ref]}" "$UPDATE_BUILD_ROOT" "$UPDATE_INSTALL_ROOT" "$(update_nproc)" "backup-first" "true" "${UPDATE_REPO_STATE[commits_behind]}")
        update_emit_db_plan_result "$steps_text" "$warning_text"
        return 0
    fi

    steps_text=$(update_build_core_steps "$repo_root" "${UPDATE_REPO_STATE[remote_ref]}" "$UPDATE_BUILD_ROOT" "$UPDATE_INSTALL_ROOT" "$(update_nproc)" "backup-first")
    update_emit_plan_result "$steps_text" "$warning_text"
}

# Shared failure tail for update_apply: print recovery guidance, drop the
# update lock, and signal failure to the caller (which returns 1).
update_fail_apply() {
    local repo_root="$1"
    local previous_commit="$2"

    update_print_recovery_steps "$repo_root" "$previous_commit"
    release_lock "update-assistant"
    return 1
}

update_apply() {
    local backup_first="${1:-false}"
    local include_db="${2:-false}"
    local repo_root previous_commit jobs

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        update_emit_error "UNSUPPORTED_FORMAT" "update apply does not support JSON output" "Run update apply without --format json"
        return 1
    fi

    check_root
    update_load_install_context || return 1

    if ! update_get_source_repo_root; then
        update_log_source_repo_error
        return 1
    fi
    repo_root="$UPDATE_SOURCE_REPO_ROOT"
    update_collect_repo_state "$repo_root" || return 1

    if [[ "${UPDATE_REPO_STATE[dirty_state]}" == "dirty" ]]; then
        log_error "Refusing to apply update with local uncommitted changes in $repo_root"
        return 1
    fi

    if [[ "${UPDATE_REPO_STATE[commits_ahead]}" -gt 0 ]]; then
        log_error "Refusing to apply update because $repo_root has local commits ahead of ${UPDATE_REPO_STATE[remote_ref]}"
        return 1
    fi

    if [[ "$include_db" == "true" ]]; then
        if ! update_assess_db_requirements "$repo_root" "${UPDATE_REPO_STATE[remote_ref]}"; then
            log_error "Failed to assess DB update requirements"
            return 1
        fi

        if [[ "$UPDATE_DB_ASSESSMENT_MODE" == "manual_review_required" ]]; then
            log_error "Refusing DB-aware update because SQL changes require manual review"
            return 1
        fi

        if [[ "${UPDATE_REPO_STATE[commits_behind]}" -eq 0 && ${#UPDATE_DB_PENDING_ENTRIES[@]} -eq 0 ]]; then
            log_info "No code or supported DB update available for $repo_root"
            return 0
        fi
    elif [[ "${UPDATE_REPO_STATE[commits_behind]}" -eq 0 ]]; then
        log_info "No update available for $repo_root"
        return 0
    fi

    if [[ "$backup_first" == "true" ]]; then
        log_info "Creating verified backup before update..."
        if ! ( backup_now true ); then
            log_error "Backup failed; aborting update"
            return 1
        fi
    elif ! update_confirm_existing_backup; then
        return 1
    fi

    acquire_lock "update-assistant"
    previous_commit="${UPDATE_REPO_STATE[local_commit]}"
    jobs=$(update_nproc)

    log_info "========================================"
    log_info "Applying VMANGOS Core Update"
    log_info "========================================"
    log_info "Source repo: $repo_root"
    log_info "Tracking: ${UPDATE_REPO_STATE[remote_ref]}"
    if [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]]; then
        log_info "Updating from ${UPDATE_REPO_STATE[local_commit]} to ${UPDATE_REPO_STATE[remote_commit]}"
    else
        log_info "No code pull required; applying supported DB changes only"
    fi

    if ! server_stop true false; then
        log_error "Failed to stop services cleanly; aborting update"
        release_lock "update-assistant"
        return 1
    fi

    if [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]]; then
        if ! update_git -C "$repo_root" pull --ff-only "${UPDATE_REPO_STATE[remote_name]}" "${UPDATE_REPO_STATE[remote_branch]}"; then
            log_error "git pull failed after services were stopped"
            update_fail_apply "$repo_root" "$previous_commit"
            return 1
        fi
    fi

    if [[ "$include_db" == "true" ]]; then
        if ! update_assess_db_requirements "$repo_root" ""; then
            log_error "Failed to reassess DB update requirements after pull"
            update_fail_apply "$repo_root" "$previous_commit"
            return 1
        fi

        if [[ ${#UPDATE_DB_PENDING_ENTRIES[@]} -gt 0 ]]; then
            if ! update_apply_pending_db_migrations "$repo_root"; then
                update_fail_apply "$repo_root" "$previous_commit"
                return 1
            fi
        fi
    fi

    if [[ "${UPDATE_REPO_STATE[commits_behind]}" -gt 0 ]]; then
        log_info "Reconfiguring build tree..."
        if ! update_run_cmake "$repo_root" "$UPDATE_BUILD_ROOT" "$UPDATE_INSTALL_ROOT"; then
            log_error "cmake configure failed"
            update_fail_apply "$repo_root" "$previous_commit"
            return 1
        fi

        log_info "Building with $jobs parallel jobs..."
        if ! update_run_make_build "$UPDATE_BUILD_ROOT" "$jobs"; then
            log_error "Build failed"
            update_fail_apply "$repo_root" "$previous_commit"
            return 1
        fi

        log_info "Installing updated binaries..."
        if ! update_run_make_install "$UPDATE_BUILD_ROOT"; then
            log_error "Install failed"
            update_fail_apply "$repo_root" "$previous_commit"
            return 1
        fi
    fi

    if ! ( server_start true 60 ); then
        log_error "Services failed to restart after update"
        update_fail_apply "$repo_root" "$previous_commit"
        return 1
    fi

    if ! update_post_apply_verify; then
        log_error "Post-update verification failed"
        update_fail_apply "$repo_root" "$previous_commit"
        return 1
    fi

    release_lock "update-assistant"
    log_info "✓ Update applied successfully"
    log_info "Current source commit: $(update_git -C "$repo_root" rev-parse HEAD)"
    log_info "Post-update status:"
    server_status_text
}
