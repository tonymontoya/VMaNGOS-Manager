#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Update check module for VMANGOS Manager
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

UPDATE_INSTALL_ROOT=""
UPDATE_SOURCE_ROOT=""
UPDATE_BUILD_ROOT=""
UPDATE_RUN_ROOT=""

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
    if [[ -z "$UPDATE_SOURCE_ROOT" ]]; then
        update_load_install_context || return 1
    fi

    if ! update_git -C "$UPDATE_SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
        log_error "Configured VMANGOS source tree is not a git checkout: $UPDATE_SOURCE_ROOT"
        log_info "Expected a VMANGOS core checkout under $UPDATE_INSTALL_ROOT/source"
        return 1
    fi

    update_git -C "$UPDATE_SOURCE_ROOT" rev-parse --show-toplevel
}

update_try_source_repo_root() {
    if ! update_load_install_context >/dev/null 2>&1; then
        return 1
    fi

    if ! update_git -C "$UPDATE_SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
        return 1
    fi

    update_git -C "$UPDATE_SOURCE_ROOT" rev-parse --show-toplevel
}

update_collect_repo_state() {
    local repo_root="$1"
    local current_branch remote_ref remote_name remote_branch local_commit remote_commit commits_behind commits_ahead dirty_state

    current_branch=$(update_git -C "$repo_root" rev-parse --abbrev-ref HEAD) || {
        log_error "Failed to determine current branch for $repo_root"
        return 1
    }

    remote_ref=$(update_get_tracking_ref "$repo_root")
    remote_name="${remote_ref%%/*}"
    remote_branch="${remote_ref#*/}"

    if ! update_git -C "$repo_root" fetch --quiet "$remote_name"; then
        log_error "Failed to fetch remote metadata from $remote_name for $repo_root"
        return 1
    fi

    if ! update_git -C "$repo_root" rev-parse "$remote_ref^{commit}" >/dev/null 2>&1; then
        log_error "Unable to resolve remote reference: $remote_ref"
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

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$current_branch" "$remote_ref" "$remote_name" "$remote_branch" \
        "$local_commit" "$remote_commit" "$commits_behind" "$commits_ahead" "$dirty_state"
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
    local line escaped_line
    local json_lines=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        escaped_line=$(json_escape "$line")
        json_lines+=("\"$escaped_line\"")
    done <<< "$instructions_text"

    if [[ ${#json_lines[@]} -eq 0 ]]; then
        printf '[]'
        return 0
    fi

    local joined
    joined=$(printf '%s,' "${json_lines[@]}")
    printf '[%s]' "${joined%,}"
}

update_emit_result() {
    local repo_root="$1"
    local current_branch="$2"
    local remote_ref="$3"
    local local_commit="$4"
    local remote_commit="$5"
    local commits_behind="$6"
    local dirty_state="$7"
    local install_target="$8"
    local instructions_text instructions_json status_text

    instructions_text=$(update_build_manual_instructions "$repo_root" "$remote_ref" "$install_target")
    instructions_json=$(update_instructions_json "$instructions_text")

    if [[ "$commits_behind" -gt 0 ]]; then
        status_text="update available"
    else
        status_text="up to date"
    fi

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "{
\"repo_root\":\"$(json_escape "$repo_root")\",
\"branch\":\"$(json_escape "$current_branch")\",
\"remote_ref\":\"$(json_escape "$remote_ref")\",
\"local_commit\":\"$(json_escape "$local_commit")\",
\"remote_commit\":\"$(json_escape "$remote_commit")\",
\"commits_behind\":$commits_behind,
\"update_available\":$( [[ "$commits_behind" -gt 0 ]] && echo true || echo false ),
\"worktree_dirty\":$( [[ "$dirty_state" == "dirty" ]] && echo true || echo false ),
\"install_target\":\"$(json_escape "$install_target")\",
\"instructions\":$instructions_json
}"
        return 0
    fi

    echo "VMANGOS Manager Update Check"
    echo "Repository: $repo_root"
    echo "Branch: $current_branch"
    echo "Tracking: $remote_ref"
    echo "Local commit: $local_commit"
    echo "Remote commit: $remote_commit"
    echo "Commits behind: $commits_behind"
    echo "Worktree: $dirty_state"
    echo "Status: $status_text"

    if [[ "$dirty_state" == "dirty" ]]; then
        echo ""
        echo "Warning: local changes are present. Review them before applying any update."
    fi

    echo ""
    echo "Manual update steps (non-atomic):"
    while IFS= read -r line; do
        printf '  %s\n' "$line"
    done <<< "$instructions_text"
}

update_emit_plan_result() {
    local source_root="$1"
    local build_root="$2"
    local run_root="$3"
    local current_branch="$4"
    local remote_ref="$5"
    local local_commit="$6"
    local remote_commit="$7"
    local commits_behind="$8"
    local commits_ahead="$9"
    local dirty_state="${10}"
    local steps_text="${11}"
    local warning_text="${12}"
    local steps_json update_available

    steps_json=$(update_instructions_json "$steps_text")
    if [[ "$commits_behind" -gt 0 ]]; then
        update_available=true
    else
        update_available=false
    fi

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "{
\"source_repo\":\"$(json_escape "$source_root")\",
\"build_dir\":\"$(json_escape "$build_root")\",
\"run_dir\":\"$(json_escape "$run_root")\",
\"branch\":\"$(json_escape "$current_branch")\",
\"remote_ref\":\"$(json_escape "$remote_ref")\",
\"local_commit\":\"$(json_escape "$local_commit")\",
\"remote_commit\":\"$(json_escape "$remote_commit")\",
\"commits_behind\":$commits_behind,
\"commits_ahead\":$commits_ahead,
\"update_available\":$update_available,
\"worktree_dirty\":$( [[ "$dirty_state" == "dirty" ]] && echo true || echo false ),
\"backup_required\":true,
\"warning\":\"$(json_escape "$warning_text")\",
\"steps\":$steps_json
}"
        return 0
    fi

    echo "VMANGOS Core Update Plan"
    echo "Source repo: $source_root"
    echo "Build dir: $build_root"
    echo "Run dir: $run_root"
    echo "Branch: $current_branch"
    echo "Tracking: $remote_ref"
    echo "Local commit: $local_commit"
    echo "Remote commit: $remote_commit"
    echo "Commits behind: $commits_behind"
    echo "Commits ahead: $commits_ahead"
    echo "Worktree: $dirty_state"
    echo "Backup required: yes"
    if [[ -n "$warning_text" ]]; then
        echo ""
        echo "Warning: $warning_text"
    fi
    echo ""
    echo "Planned steps (non-atomic):"
    while IFS= read -r line; do
        printf '  %s\n' "$line"
    done <<< "$steps_text"
    echo ""
    echo "Recovery note: database migrations are one-way unless upstream explicitly documents rollback."
}

update_emit_source_check_result() {
    local source_root="$1"
    local build_root="$2"
    local run_root="$3"
    local current_branch="$4"
    local remote_ref="$5"
    local local_commit="$6"
    local remote_commit="$7"
    local commits_behind="$8"
    local commits_ahead="$9"
    local dirty_state="${10}"
    local status_text next_steps warning_text

    if [[ "$commits_behind" -gt 0 ]]; then
        status_text="update available"
    else
        status_text="up to date"
    fi

    warning_text=""
    if [[ "$dirty_state" == "dirty" ]]; then
        warning_text="Local changes are present in the VMANGOS source tree."
    elif [[ "$commits_ahead" -gt 0 ]]; then
        warning_text="Local commits are ahead of the tracked remote."
    fi

    next_steps=$'vmangos-manager update plan\nvmangos-manager update apply --backup-first'

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "{
\"target\":\"vmangos-core\",
\"source_repo\":\"$(json_escape "$source_root")\",
\"build_dir\":\"$(json_escape "$build_root")\",
\"run_dir\":\"$(json_escape "$run_root")\",
\"branch\":\"$(json_escape "$current_branch")\",
\"remote_ref\":\"$(json_escape "$remote_ref")\",
\"local_commit\":\"$(json_escape "$local_commit")\",
\"remote_commit\":\"$(json_escape "$remote_commit")\",
\"commits_behind\":$commits_behind,
\"commits_ahead\":$commits_ahead,
\"update_available\":$( [[ "$commits_behind" -gt 0 ]] && echo true || echo false ),
\"worktree_dirty\":$( [[ "$dirty_state" == "dirty" ]] && echo true || echo false ),
\"warning\":\"$(json_escape "$warning_text")\",
\"next_steps\":$(update_instructions_json "$next_steps")
}"
        return 0
    fi

    echo "VMANGOS Core Update Check"
    echo "Source repo: $source_root"
    echo "Build dir: $build_root"
    echo "Run dir: $run_root"
    echo "Branch: $current_branch"
    echo "Tracking: $remote_ref"
    echo "Local commit: $local_commit"
    echo "Remote commit: $remote_commit"
    echo "Commits behind: $commits_behind"
    echo "Commits ahead: $commits_ahead"
    echo "Worktree: $dirty_state"
    echo "Status: $status_text"

    if [[ -n "$warning_text" ]]; then
        echo ""
        echo "Warning: $warning_text"
    fi

    echo ""
    echo "Next steps:"
    while IFS= read -r line; do
        printf '  %s\n' "$line"
    done <<< "$next_steps"
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
    local repo_root current_branch remote_ref remote_name local_commit remote_commit commits_behind dirty_state install_target
    local source_repo_root repo_state commits_ahead

    source_repo_root=$(update_try_source_repo_root || true)
    if [[ -n "$source_repo_root" ]]; then
        update_load_install_context >/dev/null 2>&1 || true
        repo_state=$(update_collect_repo_state "$source_repo_root") || {
            update_emit_error "SOURCE_GIT_ERROR" "Failed to inspect the VMANGOS source repository" "Check git remote access and repository health"
            return 1
        }
        IFS='|' read -r current_branch remote_ref _ _ local_commit remote_commit commits_behind commits_ahead dirty_state <<< "$repo_state"
        update_emit_source_check_result "$source_repo_root" "$UPDATE_BUILD_ROOT" "$UPDATE_RUN_ROOT" "$current_branch" "$remote_ref" "$local_commit" "$remote_commit" "$commits_behind" "$commits_ahead" "$dirty_state"
        return 0
    fi

    repo_root=$(update_find_repo_root) || {
        update_emit_error "NOT_A_GIT_REPO" \
            "Update check requires either a configured VMANGOS source tree or a VMANGOS-Manager git checkout" \
            "Run the command on an installed host with a valid config, from a source checkout, or set VMANGOS_MANAGER_REPO"
        return 1
    }

    current_branch=$(update_git -C "$repo_root" rev-parse --abbrev-ref HEAD) || {
        update_emit_error "GIT_ERROR" "Failed to determine current branch" "Check that the repository is readable"
        return 1
    }

    remote_ref=$(update_get_tracking_ref "$repo_root")
    remote_name="${remote_ref%%/*}"

    if ! update_git -C "$repo_root" fetch --quiet "$remote_name"; then
        update_emit_error "FETCH_FAILED" "Failed to fetch remote metadata from $remote_name" "Check git remote access and retry"
        return 1
    fi

    if ! update_git -C "$repo_root" rev-parse "$remote_ref^{commit}" >/dev/null 2>&1; then
        update_emit_error "REMOTE_REF_NOT_FOUND" "Unable to resolve remote reference: $remote_ref" "Check the configured branch and remote tracking setup"
        return 1
    fi

    local_commit=$(update_git -C "$repo_root" rev-parse HEAD)
    remote_commit=$(update_git -C "$repo_root" rev-parse "$remote_ref")
    commits_behind=$(update_git -C "$repo_root" rev-list --count "HEAD..$remote_ref")

    if [[ -n "$(update_git -C "$repo_root" status --porcelain)" ]]; then
        dirty_state="dirty"
    else
        dirty_state="clean"
    fi

    install_target=$(update_get_install_target)
    update_emit_result "$repo_root" "$current_branch" "$remote_ref" "$local_commit" "$remote_commit" "$commits_behind" "$dirty_state" "$install_target"
}

update_plan() {
    local repo_root repo_state current_branch remote_ref local_commit remote_commit commits_behind commits_ahead dirty_state warning_text steps_text

    update_load_install_context || {
        update_emit_error "CONFIG_ERROR" "Failed to load manager configuration" "Check config file exists and is readable"
        return 1
    }

    repo_root=$(update_get_source_repo_root) || {
        update_emit_error "SOURCE_REPO_MISSING" "Configured VMANGOS source tree is not a git checkout" "Verify $UPDATE_INSTALL_ROOT/source exists and contains the VMANGOS core repository"
        return 1
    }

    repo_state=$(update_collect_repo_state "$repo_root") || {
        update_emit_error "SOURCE_GIT_ERROR" "Failed to inspect the VMANGOS source repository" "Check git remote access and repository health"
        return 1
    }

    IFS='|' read -r current_branch remote_ref _ _ local_commit remote_commit commits_behind commits_ahead dirty_state <<< "$repo_state"

    warning_text=""
    if [[ "$dirty_state" == "dirty" ]]; then
        warning_text="Local changes are present in the VMANGOS source tree. update apply will refuse to continue until the tree is clean."
    elif [[ "$commits_ahead" -gt 0 ]]; then
        warning_text="Local commits are ahead of the tracked remote. update apply will refuse to overwrite a divergent source tree."
    elif [[ "$commits_behind" -eq 0 ]]; then
        warning_text="No upstream update is currently pending."
    fi

    steps_text=$(update_build_core_steps "$repo_root" "$remote_ref" "$UPDATE_BUILD_ROOT" "$UPDATE_INSTALL_ROOT" "$(update_nproc)" "backup-first")
    update_emit_plan_result "$repo_root" "$UPDATE_BUILD_ROOT" "$UPDATE_RUN_ROOT" "$current_branch" "$remote_ref" "$local_commit" "$remote_commit" "$commits_behind" "$commits_ahead" "$dirty_state" "$steps_text" "$warning_text"
}

update_apply() {
    local backup_first="${1:-false}"
    local repo_root repo_state current_branch remote_ref remote_name remote_branch local_commit remote_commit commits_behind commits_ahead dirty_state
    local previous_commit jobs

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        update_emit_error "UNSUPPORTED_FORMAT" "update apply does not support JSON output" "Run update apply without --format json"
        return 1
    fi

    check_root
    update_load_install_context || return 1

    repo_root=$(update_get_source_repo_root) || return 1
    repo_state=$(update_collect_repo_state "$repo_root") || return 1
    IFS='|' read -r current_branch remote_ref remote_name remote_branch local_commit remote_commit commits_behind commits_ahead dirty_state <<< "$repo_state"

    if [[ "$dirty_state" == "dirty" ]]; then
        log_error "Refusing to apply update with local uncommitted changes in $repo_root"
        return 1
    fi

    if [[ "$commits_ahead" -gt 0 ]]; then
        log_error "Refusing to apply update because $repo_root has local commits ahead of $remote_ref"
        return 1
    fi

    if [[ "$commits_behind" -eq 0 ]]; then
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
    previous_commit="$local_commit"
    jobs=$(update_nproc)

    log_info "========================================"
    log_info "Applying VMANGOS Core Update"
    log_info "========================================"
    log_info "Source repo: $repo_root"
    log_info "Tracking: $remote_ref"
    log_info "Updating from $local_commit to $remote_commit"

    if ! server_stop true false; then
        log_error "Failed to stop services cleanly; aborting update"
        release_lock "update-assistant"
        return 1
    fi

    if ! update_git -C "$repo_root" pull --ff-only "$remote_name" "$remote_branch"; then
        log_error "git pull failed after services were stopped"
        update_print_recovery_steps "$repo_root" "$previous_commit"
        release_lock "update-assistant"
        return 1
    fi

    log_info "Reconfiguring build tree..."
    if ! update_run_cmake "$repo_root" "$UPDATE_BUILD_ROOT" "$UPDATE_INSTALL_ROOT"; then
        log_error "cmake configure failed"
        update_print_recovery_steps "$repo_root" "$previous_commit"
        release_lock "update-assistant"
        return 1
    fi

    log_info "Building with $jobs parallel jobs..."
    if ! update_run_make_build "$UPDATE_BUILD_ROOT" "$jobs"; then
        log_error "Build failed"
        update_print_recovery_steps "$repo_root" "$previous_commit"
        release_lock "update-assistant"
        return 1
    fi

    log_info "Installing updated binaries..."
    if ! update_run_make_install "$UPDATE_BUILD_ROOT"; then
        log_error "Install failed"
        update_print_recovery_steps "$repo_root" "$previous_commit"
        release_lock "update-assistant"
        return 1
    fi

    if ! ( server_start true 60 ); then
        log_error "Services failed to restart after update"
        update_print_recovery_steps "$repo_root" "$previous_commit"
        release_lock "update-assistant"
        return 1
    fi

    if ! update_post_apply_verify; then
        log_error "Post-update verification failed"
        update_print_recovery_steps "$repo_root" "$previous_commit"
        release_lock "update-assistant"
        return 1
    fi

    release_lock "update-assistant"
    log_info "✓ Update applied successfully"
    log_info "Current source commit: $(update_git -C "$repo_root" rev-parse HEAD)"
    log_info "Post-update status:"
    server_status "text"
}
