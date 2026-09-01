#!/usr/bin/env bash
# shellcheck source=lib/common.sh
#
# Transient install unit lifecycle for VMANGOS Manager
#
# Owns the systemd-run transient unit that executes vmangos_setup.sh in
# automated mode. This module is the only layer allowed to touch
# systemd-run/systemctl for installs; the wizard and tests call it.
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# The whole install lifecycle shares one transient unit.
INSTALLER_UNIT_NAME="vmangos-install"

# systemd interaction wrappers; tests override these to capture invocations.
installer_systemctl() {
    systemctl "$@"
}

installer_systemd_run() {
    systemd-run "$@"
}

installer_unit_name() {
    printf '%s\n' "$INSTALLER_UNIT_NAME"
}

installer_unit_state() {
    local value
    value=$(installer_systemctl show -p ActiveState "$INSTALLER_UNIT_NAME.service" 2>/dev/null | cut -d= -f2- || true)
    printf '%s\n' "${value:-unknown}"
}

installer_unit_active() {
    [[ "$(installer_unit_state)" == "active" ]]
}

installer_unit_stop() {
    # Retry path: the unit may be active, failed, or not yet created. Both
    # operations are safe no-ops in the not-yet-created case (same pattern
    # as schedule cancel).
    installer_systemctl stop "$INSTALLER_UNIT_NAME.service" >/dev/null 2>&1 || true
    installer_systemctl reset-failed "$INSTALLER_UNIT_NAME.service" >/dev/null 2>&1 || true
}

# Remove an existing installation before a fresh (replace / start-over)
# launch. This is the destructive verb the wizard's confirmation gate leads
# to: it deletes INSTALLROOT exactly as auto_install.sh's replace path does
# (auto_install.sh:153), so the checkpoint file is gone and the setup script
# starts from START instead of resuming the old checkpoint.
#
# Safety — defense in depth, because the wizard feeds this the install-root
# form field (user-controlled):
#   * the path must be absolute, not the filesystem root, not a bare /name,
#     and must have at least two path components — so /tmp, /home, /opt,
#     /var, /etc, ... can never be cleared;
#   * if the directory exists and is non-empty it must carry the VMaNGOS
#     installer marker (.install-checkpoints). A non-empty directory that is
#     not an installation is never deleted.
installer_clear_install() {
    local install_root="${1:-}"

    if [[ -z "$install_root" || "$install_root" != /* || "$install_root" == "/" || "$install_root" == "/*" ]]; then
        log_error "Refusing to clear an unsafe install root: ${install_root:-<none>}"
        return 1
    fi

    # Depth floor: require at least two path components so a single top-level
    # directory (/tmp, /home, /opt, ...) can never be cleared.
    local stripped="${install_root#/}"
    local components=0
    local part
    local -a parts
    IFS='/' read -ra parts <<< "$stripped"
    for part in "${parts[@]}"; do
        if [[ -n "$part" ]]; then
            components=$((components + 1))
        fi
    done
    if (( components < 2 )); then
        log_error "Refusing to clear a top-level directory: $install_root"
        return 1
    fi

    # Marker check: a non-empty directory must be a VMaNGOS install root
    # (carry .install-checkpoints) before it may be removed. This protects
    # any non-empty directory that is not an installation.
    local entries
    entries=$(ls -A -- "$install_root" 2>/dev/null)
    if [[ -n "$entries" && ! -d "$install_root/.install-checkpoints" ]]; then
        log_error "Refusing to clear $install_root: non-empty without the .install-checkpoints marker"
        return 1
    fi

    log_info "Removing existing installation at $install_root"
    rm -rf -- "$install_root"
}

installer_journal_cmd() {
    printf 'journalctl -u %s\n' "$INSTALLER_UNIT_NAME"
}

# Resolve a secrets file to the final VAR=value environment list.
# The list mirrors auto_install.sh's exports (the legacy automated entry
# point) plus two vars vmangos_setup.sh reads from the environment that
# auto_install.sh only inherited through shell scope: VMANGOS_LOGS_DB
# (secrets key LOGSDB) and REINSTALL_POLICY.
installer_env_from_secrets() {
    local secrets_file="$1"
    (
        # shellcheck source=/dev/null
        source "$secrets_file"
        printf '%s\n' \
            "VMANGOS_AUTO_INSTALL=1" \
            "VMANGOS_INPUT_MODE=automated" \
            "VMANGOS_PROVISION_TARGET=${PROVISIONTARGET:-vmangos_manager}" \
            "VMANGOS_CLIENT_DATA=${CLIENTDATA:-}" \
            "VMANGOS_INSTALL_ROOT=${INSTALLROOT:-}" \
            "VMANGOS_SQL_ADMIN_USER=${SQLADMINUSER:-root}" \
            "VMANGOS_SQL_ADMIN_IP=${SQLADMINIP:-%}" \
            "VMANGOS_SQL_ADMIN_PASS=${SQLADMINPASS:-}" \
            "VMANGOS_WORLD_DB=${WORLDDB:-world}" \
            "VMANGOS_AUTH_DB=${AUTHDB:-auth}" \
            "VMANGOS_CHAR_DB=${CHARACTERDB:-characters}" \
            "VMANGOS_LOGS_DB=${LOGSDB:-logs}" \
            "VMANGOS_DB_USER=${MANGOSDBUSER:-mangos}" \
            "VMANGOS_DB_PASS=${MANGOSDBPASS:-mangos}" \
            "VMANGOS_OS_USER=${MANGOSOSUSER:-mangos}" \
            "VMANGOS_SKIP_SECURE_MYSQL=${SKIP_SECURE_MYSQL:-no}" \
            "VMANGOS_BACKGROUND_BUILD=1" \
            "REINSTALL_POLICY=${REINSTALL_POLICY:-abort}" \
            "INSTALL_LOG=/var/log/vmangos-install.log"
    )
}

installer_unit_start() {
    local secrets_file="${1:-}"
    local setup_script="${2:-}"

    check_root

    if [[ -z "$secrets_file" || ! -f "$secrets_file" ]]; then
        log_error "Install secrets file not found: ${secrets_file:-<none>}"
        log_error "Create it first (see docs/install-automation.md) or pass its path."
        return 1
    fi

    if [[ -z "$setup_script" || ! -f "$setup_script" ]]; then
        log_error "Setup script not found: ${setup_script:-<none>}"
        log_error "Pass the absolute path to vmangos_setup.sh."
        return 1
    fi

    local setup_path
    setup_path="$(cd "$(dirname "$setup_script")" && pwd)/$(basename "$setup_script")"

    if installer_unit_active; then
        log_error "Install already in progress: ${INSTALLER_UNIT_NAME}.service is active"
        log_error "Follow it with: $(installer_journal_cmd) -f"
        log_error "Stop it first (installer_unit_stop) before starting a fresh run."
        return 1
    fi

    local env_lines
    if ! env_lines=$(installer_env_from_secrets "$secrets_file"); then
        log_error "Failed to read install secrets from: $secrets_file"
        return 1
    fi

    local pair
    local setenv_args=()
    while IFS= read -r pair; do
        [[ -n "$pair" ]] || continue
        setenv_args+=("--setenv" "$pair")
    done <<< "$env_lines"

    if ! installer_systemd_run \
        "--unit=$INSTALLER_UNIT_NAME" \
        --description="VMaNGOS install" \
        --collect \
        "${setenv_args[@]}" \
        bash "$setup_path"; then
        log_error "systemd-run failed to start ${INSTALLER_UNIT_NAME}.service"
        log_error "Diagnosis: $(installer_journal_cmd) -n 50"
        return 1
    fi

    log_info "Install started as ${INSTALLER_UNIT_NAME}.service"
    log_info "Follow progress with: $(installer_journal_cmd) -f"
}
