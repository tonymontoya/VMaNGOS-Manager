#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Textual dashboard launcher and bootstrap support
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

dashboard_lib_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

dashboard_manager_root() {
    printf '%s\n' "$(cd "$(dashboard_lib_dir)/.." && pwd)"
}

dashboard_app_path() {
    printf '%s/dashboard.py\n' "$(dashboard_lib_dir)"
}

dashboard_requirements_path() {
    printf '%s/dashboard-requirements.txt\n' "$(dashboard_manager_root)"
}

dashboard_venv_dir() {
    if [[ -n "${VMANGOS_DASHBOARD_VENV_DIR:-}" ]]; then
        printf '%s\n' "$VMANGOS_DASHBOARD_VENV_DIR"
    else
        printf '%s/.venv-dashboard\n' "$(dashboard_manager_root)"
    fi
}

dashboard_python_bin() {
    local venv_dir candidate
    if [[ -n "${VMANGOS_DASHBOARD_PYTHON:-}" ]]; then
        printf '%s\n' "$VMANGOS_DASHBOARD_PYTHON"
        return 0
    fi

    venv_dir=$(dashboard_venv_dir)
    for candidate in "$venv_dir/bin/python3" "$venv_dir/bin/python"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '%s/bin/python3\n' "$venv_dir"
}

dashboard_bootstrap_python() {
    printf '%s\n' "${VMANGOS_DASHBOARD_BOOTSTRAP_PYTHON:-python3}"
}

dashboard_validate_interval() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

dashboard_validate_theme() {
    case "${1:-}" in
        dark|light)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

dashboard_bootstrap() {
    local bootstrap_python requirements_file venv_dir python_bin

    requirements_file=$(dashboard_requirements_path)
    venv_dir=$(dashboard_venv_dir)
    bootstrap_python=$(dashboard_bootstrap_python)

    if [[ ! -f "$requirements_file" ]]; then
        log_error "Dashboard requirements file not found: $requirements_file"
        return 1
    fi

    if ! command -v "$bootstrap_python" >/dev/null 2>&1 && [[ ! -x "$bootstrap_python" ]]; then
        log_error "Dashboard bootstrap requires python3: $bootstrap_python"
        return 1
    fi

    log_info "Bootstrapping dashboard environment at $venv_dir"
    "$bootstrap_python" -m venv "$venv_dir" || {
        log_error "Failed to create dashboard virtual environment"
        return 1
    }

    python_bin=$(dashboard_python_bin)
    if [[ ! -x "$python_bin" ]]; then
        log_error "Dashboard virtual environment is missing python: $python_bin"
        return 1
    fi

    "$python_bin" -m pip install -r "$requirements_file" >/dev/null || {
        log_error "Failed to install dashboard dependencies"
        return 1
    }

    log_info "Dashboard dependencies installed"
}

dashboard_textual_available() {
    local python_bin="$1"
    "$python_bin" -c 'import textual' >/dev/null 2>&1
}

dashboard_run() {
    local manager_bin="$1"
    local refresh="${2:-2}"
    local theme="${3:-dark}"
    local bootstrap="${4:-false}"
    local app_path python_bin

    if ! dashboard_validate_interval "$refresh"; then
        log_error "Invalid dashboard refresh interval: $refresh"
        return 1
    fi

    if ! dashboard_validate_theme "$theme"; then
        log_error "Invalid dashboard theme: $theme"
        return 1
    fi

    app_path=$(dashboard_app_path)
    if [[ ! -f "$app_path" ]]; then
        log_error "Dashboard application not found: $app_path"
        return 1
    fi

    if [[ "$bootstrap" == "true" ]]; then
        dashboard_bootstrap || return 1
        return 0
    fi

    python_bin=$(dashboard_python_bin)
    if [[ ! -x "$python_bin" ]]; then
        log_error "Dashboard dependencies are not installed"
        log_info "Run '$manager_bin dashboard --bootstrap' to install Textual support"
        return 1
    fi

    if ! dashboard_textual_available "$python_bin"; then
        log_error "Dashboard environment is missing the Textual dependency"
        log_info "Run '$manager_bin dashboard --bootstrap' to install Textual support"
        return 1
    fi

    "$python_bin" "$app_path" \
        --manager-bin "$manager_bin" \
        --config "$CONFIG_FILE" \
        --refresh "$refresh" \
        --theme "$theme"
}
