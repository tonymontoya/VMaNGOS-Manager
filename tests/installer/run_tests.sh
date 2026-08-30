#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo "✓ $message"
        return 0
    fi

    echo "✗ $message"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    return 1
}

run_test() {
    local name="$1"
    local func="$2"
    local result=0

    echo ""
    echo "Running: $name"
    TESTS_RUN=$((TESTS_RUN + 1))

    if "$func"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        result=1
    fi

    return "$result"
}

extract_result() {
    local output="$1"
    printf '%s\n' "${output##*RESULT=}"
}

test_service_account_creation() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    cat > "$tmp_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_USER_EXISTS:-0}" == "1" ]] && exit 0
exit 1
EOF
    cat > "$tmp_dir/bin/useradd" <<'EOF'
#!/usr/bin/env bash
printf 'USERADD:%s\n' "$*"
EOF
    chmod +x "$tmp_dir/bin/id" "$tmp_dir/bin/useradd"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        PATH="$tmp_dir/bin:$PATH" \
        REPO_ROOT="$REPO_ROOT" \
        bash -c '
            set -euo pipefail
            source "$REPO_ROOT/vmangos_setup.sh"
            MANGOSOSUSER="mangos"
            INSTALLROOT="/opt/mangos"

            ensure_service_account
            FAKE_USER_EXISTS=1 ensure_service_account
        ' 2>/dev/null | grep '^USERADD:'
    )"
    rm -rf "$tmp_dir"

    local call_count
    call_count="$(printf '%s\n' "$output" | grep -c '^USERADD:' || true)"

    assert_equals \
        "USERADD:--system --home-dir /opt/mangos --no-create-home --shell /usr/sbin/nologin mangos" \
        "$(printf '%s\n' "$output" | head -1)" \
        "installer creates the mangos service account with system-user flags"
    assert_equals "1" "$call_count" "existing service account is left alone (idempotent)"
}

test_existing_install_action() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        bash -lc "
            set -euo pipefail
            source \"$REPO_ROOT/vmangos_setup.sh\"

            INSTALLROOT=\"$tmp_dir/missing-root\"
            refresh_runtime_paths
            printf 'clean=%s\n' \"\$(existing_install_action)\"

            INSTALLROOT=\"$tmp_dir/partial-root\"
            refresh_runtime_paths
            mkdir -p \"\$CHECKPOINT_DIR\"
            echo PREREQS_DONE > \"\$CHECKPOINT_FILE\"
            printf 'resume=%s\n' \"\$(existing_install_action)\"

            rm -f \"\$CHECKPOINT_FILE\"
            REINSTALL_POLICY=\"abort\"
            printf 'abort=%s\n' \"\$(existing_install_action)\"

            REINSTALL_POLICY=\"replace\"
            printf 'replace=%s\n' \"\$(existing_install_action)\"
        "
    )"
    rm -rf "$tmp_dir"

    assert_equals "clean=clean" "$(printf '%s\n' "$output" | grep '^clean=')" "no install root means a clean install"
    assert_equals "resume=resume" "$(printf '%s\n' "$output" | grep '^resume=')" "existing checkpoints switch the wrapper to resume instead of abort"
    assert_equals "abort=abort" "$(printf '%s\n' "$output" | grep '^abort=')" "completed installation without checkpoints follows REINSTALL_POLICY=abort"
    assert_equals "replace=replace" "$(printf '%s\n' "$output" | grep '^replace=')" "REINSTALL_POLICY=replace still wipes the tree"
}

test_noninteractive_defaults() {
    local tmp_dir output result
    tmp_dir="$(mktemp -d)"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        VMANGOS_MANAGER_ROOT="$REPO_ROOT" \
        bash -lc '
            set -euo pipefail
            source "$VMANGOS_MANAGER_ROOT/vmangos_setup.sh"
            VMANGOS_AUTO_INSTALL=1
            VMANGOS_PROVISION_TARGET=""
            VMANGOS_INPUT_MODE=""

            select_installer_target
            select_input_mode
            printf "RESULT=%s|%s\n" "$VMANGOS_PROVISION_TARGET" "$VMANGOS_INPUT_MODE"
        '
    )"

    result="$(extract_result "$output")"
    rm -rf "$tmp_dir"

    assert_equals "vmangos_manager|automated" "$result" "noninteractive mode defaults to VMANGOS + Manager automated flow"
}

test_guided_prompts_collect_values() {
    local tmp_dir output result
    tmp_dir="$(mktemp -d)"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        VMANGOS_MANAGER_ROOT="$REPO_ROOT" \
        bash -lc '
            set -euo pipefail
            source "$VMANGOS_MANAGER_ROOT/vmangos_setup.sh"
            VMANGOS_AUTO_INSTALL=0
            VMANGOS_PROVISION_TARGET=""
            VMANGOS_INPUT_MODE=""
            INSTALLROOT="/opt/mangos"
            CLIENT_DATA=""
            AUTHDB="auth"
            WORLDDB="world"
            CHARACTERDB="characters"
            LOGSDB="logs"
            MANGOSDBUSER="mangos"
            MANGOSDBPASS="mangos"
            MANGOSOSUSER="mangos"

            select_installer_target
            select_input_mode
            prompt_guided_install_root
            prompt_guided_values
            printf "RESULT=%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
                "$VMANGOS_PROVISION_TARGET" \
                "$VMANGOS_INPUT_MODE" \
                "$INSTALLROOT" \
                "$CLIENT_DATA" \
                "$AUTHDB" \
                "$WORLDDB" \
                "$CHARACTERDB" \
                "$LOGSDB" \
                "$MANGOSDBUSER" \
                "$MANGOSDBPASS" \
                "$MANGOSOSUSER"
        ' <<'EOF'
1
2
/srv/vmangos
/srv/client-data
auth_custom
world_custom
characters_custom
logs_custom
vmangos_app
secret_pass
vmangosd
EOF
    )"

    result="$(extract_result "$output")"
    rm -rf "$tmp_dir"

    assert_equals \
        "vmangos_only|guided|/srv/vmangos|/srv/client-data|auth_custom|world_custom|characters_custom|logs_custom|vmangos_app|secret_pass|vmangosd" \
        "$result" \
        "guided mode captures operator-provided install values"
}

test_guided_state_round_trip() {
    local tmp_dir output result
    tmp_dir="$(mktemp -d)"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        VMANGOS_MANAGER_ROOT="$REPO_ROOT" \
        TEST_INSTALL_ROOT="$tmp_dir/install-root" \
        bash -lc '
            set -euo pipefail
            source "$VMANGOS_MANAGER_ROOT/vmangos_setup.sh"
            VMANGOS_AUTO_INSTALL=0
            VMANGOS_PROVISION_TARGET="vmangos_manager"
            VMANGOS_INPUT_MODE="guided"
            INSTALLROOT="$TEST_INSTALL_ROOT"
            refresh_runtime_paths

            CLIENT_DATA="/srv/client-data"
            AUTHDB="auth_saved"
            MANGOSDBPASS="saved_secret"

            save_installer_state

            CLIENT_DATA=""
            AUTHDB="auth"
            MANGOSDBPASS="changed"

            load_installer_state
            printf "RESULT=%s|%s|%s\n" "$CLIENT_DATA" "$AUTHDB" "$MANGOSDBPASS"
        '
    )"

    result="$(extract_result "$output")"
    rm -rf "$tmp_dir"

    assert_equals "/srv/client-data|auth_saved|saved_secret" "$result" "guided installer state persists across reruns"
}

main() {
    echo "========================================"
    echo "VMANGOS Installer Test Suite"
    echo "========================================"

    run_test "Installer: Service account" test_service_account_creation
    run_test "Installer: Existing install action" test_existing_install_action
    run_test "Installer: Noninteractive defaults" test_noninteractive_defaults
    run_test "Installer: Guided prompts" test_guided_prompts_collect_values
    run_test "Installer: Guided state" test_guided_state_round_trip

    echo ""
    echo "========================================"
    echo "Tests run:    $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo "========================================"

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
