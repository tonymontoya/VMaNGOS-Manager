#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Update check module for VMANGOS Manager
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

update_git() {
    git "$@"
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

update_get_tracking_ref() {
    local repo_root="$1"
    local upstream_ref

    upstream_ref=$(update_git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)
    if [[ -n "$upstream_ref" ]]; then
        printf '%s\n' "$upstream_ref"
    else
        printf 'origin/main\n'
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

update_check() {
    local repo_root current_branch remote_ref remote_name local_commit remote_commit commits_behind dirty_state install_target

    repo_root=$(update_find_repo_root) || {
        update_emit_error "NOT_A_GIT_REPO" \
            "Update check requires a VMANGOS-Manager git checkout" \
            "Run the command from a source checkout or set VMANGOS_MANAGER_REPO to that checkout"
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
