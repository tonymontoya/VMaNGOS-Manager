#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/installer.sh
#
# Install wizard launcher, bootstrap support, and existing-install gate
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/installer.sh"

wizard_lib_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

wizard_manager_root() {
    printf '%s\n' "$(cd "$(wizard_lib_dir)/.." && pwd)"
}

wizard_app_path() {
    printf '%s/wizard.py\n' "$(wizard_lib_dir)"
}

wizard_requirements_path() {
    # The wizard shares the dashboard's requirements file by default.
    printf '%s/dashboard-requirements.txt\n' "$(wizard_manager_root)"
}

wizard_venv_dir() {
    if [[ -n "${VMANGOS_WIZARD_VENV_DIR:-}" ]]; then
        printf '%s\n' "$VMANGOS_WIZARD_VENV_DIR"
    else
        printf '%s/.venv-dashboard\n' "$(wizard_manager_root)"
    fi
}

wizard_python_bin() {
    local venv_dir candidate
    if [[ -n "${VMANGOS_WIZARD_PYTHON:-}" ]]; then
        printf '%s\n' "$VMANGOS_WIZARD_PYTHON"
        return 0
    fi

    venv_dir=$(wizard_venv_dir)
    for candidate in "$venv_dir/bin/python3" "$venv_dir/bin/python"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '%s/bin/python3\n' "$venv_dir"
}

wizard_bootstrap_python() {
    printf '%s\n' "${VMANGOS_WIZARD_BOOTSTRAP_PYTHON:-python3}"
}

wizard_bootstrap() {
    local bootstrap_python requirements_file venv_dir python_bin

    requirements_file=$(wizard_requirements_path)
    venv_dir=$(wizard_venv_dir)
    bootstrap_python=$(wizard_bootstrap_python)

    if [[ ! -f "$requirements_file" ]]; then
        log_error "Wizard requirements file not found: $requirements_file"
        return 1
    fi

    if ! command -v "$bootstrap_python" >/dev/null 2>&1 && [[ ! -x "$bootstrap_python" ]]; then
        log_error "Wizard bootstrap requires python3: $bootstrap_python"
        return 1
    fi

    log_info "Bootstrapping wizard environment at $venv_dir"
    "$bootstrap_python" -m venv "$venv_dir" || {
        log_error "Failed to create wizard virtual environment"
        return 1
    }

    python_bin=$(wizard_python_bin)
    if [[ ! -x "$python_bin" ]]; then
        log_error "Wizard virtual environment is missing python: $python_bin"
        return 1
    fi

    "$python_bin" -m pip install -r "$requirements_file" >/dev/null || {
        log_error "Failed to install wizard dependencies"
        return 1
    }

    log_info "Wizard dependencies installed"
}

wizard_textual_available() {
    local python_bin="$1"
    "$python_bin" -c 'import textual' >/dev/null 2>&1
}

# Evaluate the existing-install gate exactly as auto_install.sh does:
# source vmangos_setup.sh and ask its existing_install_action, with the
# existing secrets file's INSTALLROOT/REINSTALL_POLICY in scope.
wizard_gate_action() {
    local secrets_file="$1"
    local setup_script="$2"
    local action

    if [[ ! -f "$setup_script" ]]; then
        log_error "Setup script not found: $setup_script"
        return 1
    fi

    if ! action=$(bash -c '
        if [[ -n "$2" && -f "$2" ]]; then
            # shellcheck source=/dev/null
            source "$2" >/dev/null 2>&1
        fi
        VMANGOS_INSTALL_ROOT="${INSTALLROOT:-/opt/mangos}"
        REINSTALL_POLICY="${REINSTALL_POLICY:-abort}"
        export VMANGOS_INSTALL_ROOT REINSTALL_POLICY
        source "$1" >/dev/null 2>&1
        existing_install_action
    ' _ "$setup_script" "$secrets_file" 2>&1); then
        log_error "Failed to evaluate the existing-install gate: $action"
        return 1
    fi

    case "$action" in
        clean|resume|abort|replace)
            printf '%s\n' "$action"
            ;;
        *)
            log_error "Unexpected gate action: $action"
            return 1
            ;;
    esac
}

# The checkpoint a resume would continue from (empty when there is none).
wizard_checkpoint() {
    local install_root="$1"
    local checkpoint_file

    [[ -n "$install_root" ]] || return 0
    checkpoint_file="$install_root/.install-checkpoints/checkpoint"
    if [[ -f "$checkpoint_file" ]]; then
        tr -d '[:space:]' < "$checkpoint_file"
        printf '\n'
    fi
}

wizard_run() {
    local manager_bin="$1"
    local secrets_file="$2"
    local setup_script="$3"
    local bootstrap="${4:-false}"
    local app_path python_bin gate_action checkpoint

    app_path=$(wizard_app_path)
    if [[ ! -f "$app_path" ]]; then
        log_error "Install wizard not found: $app_path"
        return 1
    fi

    # --bootstrap is a one-shot environment setup; handle it first (mirroring
    # dashboard_run) so a still-running install unit can't shadow it.
    if [[ "$bootstrap" == "true" ]]; then
        wizard_bootstrap || return 1
        return 0
    fi

    # Resolve the wizard python and check Textual once; both the attach
    # (viewer) path and the wizard flow need it.
    python_bin=$(wizard_python_bin)
    python_ok=0
    if [[ -x "$python_bin" ]] && wizard_textual_available "$python_bin"; then
        python_ok=1
    fi

    # A launch from a previous run may still be active: attach as the live
    # viewer (#103). When the viewer can't run (no Textual), fall back to a
    # one-line pointer so the user can still follow from the shell.
    if installer_unit_active; then
        if (( python_ok )); then
            "$python_bin" "$app_path" \
                --manager-bin "$manager_bin" \
                --config "$CONFIG_FILE" \
                --secrets-file "$secrets_file" \
                --setup-script "$setup_script" \
                --attach
            return $?
        fi
        log_info "Install already running — follow with: journalctl -u vmangos-install -f"
        return 0
    fi

    if (( ! python_ok )); then
        log_error "Wizard dependencies are not installed"
        log_info "Run '$manager_bin install --bootstrap' to install Textual support"
        return 1
    fi

    gate_action=$(wizard_gate_action "$secrets_file" "$setup_script") || return 1

    # The wizard needs the install root the gate evaluated against; it is
    # either the secrets file's INSTALLROOT or the default.
    if [[ -f "$secrets_file" ]]; then
        checkpoint=$(wizard_checkpoint "$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${INSTALLROOT:-}"' _ "$secrets_file")")
    else
        checkpoint=""
    fi

    "$python_bin" "$app_path" \
        --manager-bin "$manager_bin" \
        --config "$CONFIG_FILE" \
        --secrets-file "$secrets_file" \
        --setup-script "$setup_script" \
        --gate "$gate_action" \
        --checkpoint "$checkpoint"
}
