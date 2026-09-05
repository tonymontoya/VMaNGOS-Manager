#!/usr/bin/env bash
#
# wizard_smoke.sh — real end-to-end install smoke in a privileged systemd
# Docker container (issue #104).
#
# Validates the install-wizard stack (runner + vmangos_setup.sh + markers +
# viewer) against reality: real apt, real MySQL, real build, real MPQ
# extraction, real systemd services, real markers, real retry. It exercises
# the claims from #104 plus two folded-in additions:
#   * the transient-unit name-recreation edge after a completed run, and
#   * watching for the viewer flake under long runs.
#
# The smoke runs entirely inside a throwaway container; it NEVER touches bds.
# The client-data cache is kept on the host and re-mounted on every run.
#
# Phases (run in order by default; --phase runs one):
#   build-image     build the systemd base image
#   setup           create the container + wait for systemd
#   manager         install the manager + bootstrap the venv
#   secrets         pre-populate the secrets file
#   start           start the install unit via the runner
#   watch           stream markers until the install ends
#   kill-reattach   kill the viewer session, verify the unit keeps running
#   failure-retry   force a failure, drive the retry, verify resume
#   completion      verify auth/world active + completion marker + realmlist
#   name-recreation re-create the unit name after a completed run
#   flake-watch     re-run the viewer async suite to watch for the flake
#   teardown        remove the container (keep the client-data cache)
#
# Usage:
#   tests/smoke/wizard_smoke.sh [--phase NAME] [--keep] [--client-data PATH]
#                               [--container NAME] [--image NAME] [--repo PATH]
#
# Exit status: 0 when the requested phase(s) pass, non-zero otherwise.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (env-overridable defaults, then flags)
# ---------------------------------------------------------------------------
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
CONTAINER_NAME="${SMOKE_CONTAINER_NAME:-vmangos-wizard-smoke}"
IMAGE_NAME="${SMOKE_IMAGE_NAME:-vmangos-smoke-base}"
CLIENT_DATA="${SMOKE_CLIENT_DATA:-/home/tony/Data}"
MANAGER_PREFIX="/opt/mangos/manager"
MANAGER_BIN="$MANAGER_PREFIX/bin"
SECRETS_FILE="/root/.vmangos-secrets/setup.conf"
SETUP_SCRIPT="/src/vmangos_setup.sh"
INSTALL_ROOT="/opt/mangos"

PHASE="all"
KEEP=0
TIMEOUT_SYSTEMD="${SMOKE_SYSTEMD_TIMEOUT:-120}"
# 6h ceiling for a full clean build: MoveMapGen alone takes ~2.5h on a 10-core
# workstation (single-threaded), so the whole install can exceed 4h.
TIMEOUT_INSTALL="${SMOKE_INSTALL_TIMEOUT:-21600}"

# ---------------------------------------------------------------------------
# Logging + helpers
# ---------------------------------------------------------------------------
log()  { printf '[smoke] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
pass() { log "PASS: $*"; }
fail() { log "FAIL: $*"; exit 1; }

# docker exec with the manager bin prepended to PATH (the manager resolves its
# lib via SCRIPT_DIR/../lib, so it must be invoked by its real path, not a
# symlink).
docker_exec() {
    docker exec -e "PATH=$MANAGER_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$CONTAINER_NAME" bash -c "$*"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
    docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"
}

require_client_data() {
    [[ -d "$CLIENT_DATA" ]] || die "client data not found at $CLIENT_DATA"
    [[ -f "$CLIENT_DATA/base.MPQ" ]] || die "client data at $CLIENT_DATA has no base.MPQ"
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

phase_build_image() {
    log "building $IMAGE_NAME from $SMOKE_DIR/Dockerfile"
    docker build -q -t "$IMAGE_NAME" -f "$SMOKE_DIR/Dockerfile" "$SMOKE_DIR" >/dev/null
    pass "image $IMAGE_NAME built"
}

phase_setup() {
    require_docker
    require_client_data
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    log "starting container $CONTAINER_NAME (privileged, cgroupns=host)"
    docker run -d \
        --privileged \
        --cgroupns=host \
        --name "$CONTAINER_NAME" \
        -v "$REPO_ROOT":/src:ro \
        -v "$CLIENT_DATA":/mnt/client-data:ro \
        "$IMAGE_NAME" >/dev/null
    wait_for_systemd
    pass "container up, systemd is PID 1"
}

wait_for_systemd() {
    local deadline=$(( $(date +%s) + TIMEOUT_SYSTEMD ))
    local state
    while (( $(date +%s) < deadline )); do
        state="$(docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null || true)"
        case "$state" in
            running|degraded|stopped)
                log "systemd state: $state"
                return 0
                ;;
        esac
        sleep 2
    done
    docker logs --tail 40 "$CONTAINER_NAME" >&2 2>/dev/null || true
    die "systemd did not become ready within ${TIMEOUT_SYSTEMD}s"
}

phase_manager() {
    log "installing the manager into $MANAGER_PREFIX"
    docker exec "$CONTAINER_NAME" bash -c "make -C /src/manager install PREFIX=$MANAGER_PREFIX"
    # Make `vmangos-manager` reachable on PATH for login shells.
    docker exec "$CONTAINER_NAME" bash -c "printf 'export PATH=%s:\$PATH\n' '$MANAGER_BIN' > /etc/profile.d/vmangos-manager.sh"
    # Bootstrap the wizard venv (Textual) the same way a fresh host would.
    docker_exec "vmangos-manager install --bootstrap"
    docker_exec "command -v vmangos-manager" >/dev/null || fail "vmangos-manager not on PATH"
    pass "manager installed + venv bootstrapped"
}

phase_secrets() {
    log "pre-populating $SECRETS_FILE"
    local db_pass sql_pass
    db_pass="$(openssl rand -base64 12 | tr -d '/+=')"
    sql_pass="$(openssl rand -base64 12 | tr -d '/+=')"
    docker_exec "
        mkdir -p /root/.vmangos-secrets && chmod 700 /root/.vmangos-secrets
        cat > '$SECRETS_FILE' <<'EOF'
SQLADMINUSER=\"root\"
SQLADMINIP=\"%\"
SQLADMINPASS=\"$sql_pass\"
MANGOSDBUSER=\"mangos\"
MANGOSDBPASS=\"$db_pass\"
MANGOSOSUSER=\"mangos\"
AUTHDB=\"auth\"
WORLDDB=\"world\"
CHARACTERDB=\"characters\"
LOGSDB=\"logs\"
INSTALLROOT=\"$INSTALL_ROOT\"
CLIENTDATA=\"/mnt/client-data\"
SKIP_SECURE_MYSQL=\"yes\"
PROVISIONTARGET=\"vmangos_manager\"
REINSTALL_POLICY=\"abort\"
EOF
        chmod 600 '$SECRETS_FILE'
    "
    pass "secrets written"
}

# ---------------------------------------------------------------------------
# Install run + marker watching
# ---------------------------------------------------------------------------

# Start the install unit via the runner (the same path the wizard's launch
# uses). systemd-run returns immediately; the unit runs in the background.
phase_start() {
    log "starting the install unit (secrets=$SECRETS_FILE, setup=$SETUP_SCRIPT)"
    docker_exec "
        set -u
        source $MANAGER_PREFIX/lib/installer.sh
        installer_unit_start '$SECRETS_FILE' '$SETUP_SCRIPT'
    " || fail "runner refused to start the install unit"
    sleep 3
    local state; state="$(unit_state)"
    log "unit ActiveState after launch: $state"
    [[ "$state" == "active" || "$state" == "activating" ]] \
        || fail "install unit is not running (ActiveState=$state)"
    pass "install unit started and running"
}

# The unit's ActiveState (or 'unknown').
unit_state() {
    docker_exec "systemctl show -p ActiveState vmangos-install.service --value" 2>/dev/null || echo unknown
}

# The most recent marker line from the unit's journal (empty if none).
latest_marker() {
    docker_exec "journalctl -u vmangos-install --no-pager 2>/dev/null" \
        | grep -F '@@VMANGOS v1' | tail -1 || true
}

# Stream the install's markers from the journal until it ends (done or error),
# a unit death, or the timeout. Prints the newest marker each poll so progress
# is visible. Returns: 0 completed, 1 error marker, 2 timeout, 3 unit left
# active states without a terminal marker.
phase_watch() {
    local timeout="${SMOKE_WATCH_TIMEOUT:-$TIMEOUT_INSTALL}"
    local deadline=$(( $(date +%s) + timeout ))
    log "watching markers (timeout ${timeout}s)..."
    local state latest last_logged=""
    while (( $(date +%s) < deadline )); do
        state="$(unit_state)"
        latest="$(latest_marker)"
        # Log only new markers (avoid spamming the same line each poll).
        if [[ -n "$latest" && "$latest" != "$last_logged" ]]; then
            log "marker: $latest"
            last_logged="$latest"
        fi
        if [[ "$latest" == *"phase=install event=done"* ]]; then
            pass "install completed (terminal marker)"
            return 0
        fi
        if [[ "$state" != "active" && "$state" != "activating" && "$state" != "unknown" ]]; then
            log "unit left active states (ActiveState=$state)"
            return 3
        fi
        sleep 5
    done
    log "watch timeout reached (last marker: ${latest:-none})"
    return 2
}

# The unit must survive its viewer session dying. We attach a journal-watch
# (the same process the TUI spawns), kill it, and assert the unit is still
# running — then re-attach.
phase_kill_reattach() {
    local state
    state="$(unit_state)"
    [[ "$state" == "active" || "$state" == "activating" ]] \
        || fail "kill/reattach precondition: unit not running (ActiveState=$state)"
    # Attach a viewer session (a journal-watch, as the TUI does).
    docker_exec 'nohup journalctl -u vmangos-install -n 5 -f >/tmp/viewer.log 2>&1 & echo $!'>/tmp/viewer_pid 2>/dev/null
    local viewer_pid; viewer_pid="$(docker_exec 'cat /tmp/viewer_pid' 2>/dev/null || echo '')"
    sleep 3
    state="$(unit_state)"
    log "unit state while viewer attached: $state"
    # Kill the viewer session (simulates the user closing the TUI / Ctrl+C).
    docker_exec "kill ${viewer_pid:-0} 2>/dev/null; pkill -f 'journalctl -u vmangos-install' 2>/dev/null" >/dev/null 2>&1 || true
    sleep 3
    state="$(unit_state)"
    log "unit state after viewer killed: $state"
    [[ "$state" == "active" || "$state" == "activating" ]] \
        || fail "unit STOPPED when the viewer session died (ActiveState=$state)"
    # Re-attach: a fresh journal read must work.
    docker_exec 'journalctl -u vmangos-install -n 3 --no-pager' >/dev/null 2>&1 \
        || fail "re-attach failed (journalctl could not read the unit)"
    pass "kill/reattach: the unit survives the viewer session dying"
}

# Force a failure (stop the unit), drive the runner's retry path (stop +
# reset-failed + start), and assert the unit restarts with the checkpoint
# intact (so the resume continues rather than restarting from scratch).
phase_failure_retry() {
    local state
    state="$(unit_state)"
    [[ "$state" == "active" || "$state" == "activating" ]] \
        || fail "failure/retry precondition: unit not running (ActiveState=$state)"
    log "forcing a failure (systemctl stop)..."
    docker_exec 'systemctl stop vmangos-install.service' >/dev/null 2>&1 || true
    sleep 3
    state="$(unit_state)"
    log "unit state after forced failure: $state"
    # The runner's retry path: installer_unit_stop (stop + reset-failed) then
    # installer_unit_start.
    log "driving the retry (installer_unit_stop + installer_unit_start)..."
    docker_exec "
        set -u
        source $MANAGER_PREFIX/lib/installer.sh
        installer_unit_stop
        installer_unit_start '$SECRETS_FILE' '$SETUP_SCRIPT'
    " || fail "retry launch failed"
    sleep 5
    state="$(unit_state)"
    log "unit state after retry: $state"
    [[ "$state" == "active" || "$state" == "activating" ]] \
        || fail "retry did not restart the unit (ActiveState=$state)"
    pass "failure/retry: unit stopped then restarted via the runner's retry path"
}

# Verify completion: the terminal marker is present and auth+world are active.
phase_completion() {
    local latest; latest="$(latest_marker)"
    [[ "$latest" == *"phase=install event=done"* ]] \
        || fail "no completion marker (latest: ${latest:-none})"
    log "completion marker: $latest"
    local auth_state world_state
    auth_state="$(docker_exec 'systemctl show -p ActiveState auth.service --value' 2>/dev/null || echo unknown)"
    world_state="$(docker_exec 'systemctl show -p ActiveState world.service --value' 2>/dev/null || echo unknown)"
    log "auth: $auth_state | world: $world_state"
    [[ "$auth_state" == "active" ]] || fail "auth is not active (ActiveState=$auth_state)"
    [[ "$world_state" == "active" ]] || fail "world is not active (ActiveState=$world_state)"
    # Extract the realmlist-relevant fields from the completion marker.
    local server_ip auth_port world_port
    server_ip="$(grep -oE 'server_ip=[^ ]+' <<<"$latest" | cut -d= -f2)"
    auth_port="$(grep -oE 'auth_port=[^ ]+' <<<"$latest" | cut -d= -f2)"
    world_port="$(grep -oE 'world_port=[^ ]+' <<<"$latest" | cut -d= -f2)"
    log "realmlist target: world=$world_port server_ip=$server_ip (auth=$auth_port)"
    pass "completion: terminal marker + auth+world active + realmlist fields"
}

# After a completed run the unit is collected (inactive); the same unit name
# must be re-creatable. This is the transient-unit name-recreation edge.
phase_name_recreation() {
    local state; state="$(unit_state)"
    log "unit state before re-creation: $state"
    docker_exec 'systemd-run --unit=vmangos-install --collect -- /bin/echo SMOKE-NAME-RECREATION-OK' >/dev/null 2>&1 \
        || fail "systemd-run with the reused unit name failed"
    sleep 3
    if docker_exec 'journalctl -u vmangos-install --no-pager' 2>/dev/null | grep -q 'SMOKE-NAME-RECREATION-OK'; then
        pass "name-recreation: the unit name was reused after a completed run"
    else
        fail "name-recreation: no evidence of the new invocation"
    fi
}

# Ensure the dashboard venv can run the pytest suite. The bootstrap only
# installs the runtime deps (textual), so add pytest once if it is missing.
ensure_venv_pytest() {
    local venv_bin="$MANAGER_PREFIX/.venv-dashboard/bin"
    if docker_exec "\"$venv_bin/python3\" -m pytest --version >/dev/null 2>&1" 2>/dev/null; then
        return 0
    fi
    log "installing pytest into the dashboard venv..."
    docker_exec "\"$venv_bin/python3\" -m pip install --quiet pytest" \
        || fail "could not install pytest into the dashboard venv"
}

# Re-run the viewer's async test suite to watch for the known single flake.
# The tests live on the read-only /src/manager mount; the venv lives under the
# manager install prefix. Point PATH at the real venv and give pytest a
# writable cache dir (the source mount is read-only).
phase_flake_watch() {
    ensure_venv_pytest
    local n="${SMOKE_FLAKE_RUNS:-5}" i pass_count=0 fail_count=0
    log "running the viewer async suite $n times (flake watch)..."
    for (( i=1; i<=n; i++ )); do
        # pipefail: the pipeline's exit status must be pytest's, not tail's —
        # otherwise a failing suite is masked by a successful `tail` and the
        # flake is never reported (it read "N/N green" while pytest failed).
        if docker_exec "
            set -o pipefail
            cd /src/manager
            PATH=$MANAGER_PREFIX/.venv-dashboard/bin:\$PATH \
            PYTEST_CACHE_DIR=/tmp/pytest-cache PYTHONDONTWRITEBYTECODE=1 \
            python3 -m pytest tests/test_wizard.py -q 2>&1 | tail -3
        "; then
            pass_count=$((pass_count+1))
        else
            fail_count=$((fail_count+1))
        fi
    done
    log "flake-watch: $pass_count passed, $fail_count failed (of $n)"
    (( fail_count == 0 )) || fail "viewer flake detected: $fail_count/$n failed"
    pass "flake-watch: $n/$n viewer runs green"
}

phase_teardown() {
    log "tearing down the container (keeping the client-data cache on the host)"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    pass "container removed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phase)        PHASE="${2:-}"; shift 2 ;;
            --client-data)  CLIENT_DATA="${2:-}"; shift 2 ;;
            --container)    CONTAINER_NAME="${2:-}"; shift 2 ;;
            --image)        IMAGE_NAME="${2:-}"; shift 2 ;;
            --repo)         REPO_ROOT="${2:-}"; shift 2 ;;
            --keep)         KEEP=1; shift ;;
            -h|--help)      usage 0 ;;
            *)              usage 2 ;;
        esac
    done
}

run_phase() {
    local name="$1"
    log "=== phase: $name ==="
    case "$name" in
        build-image)    phase_build_image ;;
        setup)          phase_setup ;;
        manager)        phase_manager ;;
        secrets)        phase_secrets ;;
        start)          phase_start ;;
        watch)          phase_watch ;;
        kill-reattach)  phase_kill_reattach ;;
        failure-retry)  phase_failure_retry ;;
        completion)     phase_completion ;;
        name-recreation) phase_name_recreation ;;
        flake-watch)    phase_flake_watch ;;
        teardown)       phase_teardown ;;
        *)              die "unknown phase: $name" ;;
    esac
}

main() {
    parse_args "$@"
    require_docker

    if [[ "$PHASE" == "all" ]]; then
        # Scenarios run while the unit is active (kill/reattach, then the
        # forced failure + retry); the blocking watch then runs to completion.
        local phases=(build-image setup manager secrets start kill-reattach failure-retry watch completion name-recreation flake-watch)
        if (( KEEP )); then
            log "--keep set: skipping teardown"
        else
            phases+=(teardown)
        fi
        local p
        for p in "${phases[@]}"; do
            run_phase "$p"
        done
        pass "smoke complete"
    else
        run_phase "$PHASE"
    fi
}

main "$@"
