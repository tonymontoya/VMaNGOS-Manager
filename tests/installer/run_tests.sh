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

test_extraction_root_preparation() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin" "$tmp_dir/client-src" "$tmp_dir/root"

    cat > "$tmp_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
if [[ "${1:-}" == "test" ]]; then
    if [[ "${3:-}" == "${SUDO_DENY:-__no_deny__}" ]]; then exit 1; fi
    [[ -r "${3:-}" ]] && exit 0
    exit 1
fi
exec "$@"
EOF
    cat > "$tmp_dir/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$tmp_dir/bin/sudo" "$tmp_dir/bin/chown"

    touch "$tmp_dir/client-src/dbc.MPQ" "$tmp_dir/client-src/terrain.MPQ"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        PATH="$tmp_dir/bin:$PATH" \
        REPO_ROOT="$REPO_ROOT" \
        bash -c '
            set -euo pipefail
            source "$REPO_ROOT/vmangos_setup.sh"
            INSTALLROOT="'"$tmp_dir"'/root"
            CLIENT_DATA="'"$tmp_dir"'/client-src"
            MANGOSOSUSER="mangos"

            prepare_extraction_root
            printf "RESULT1=%s\n" "$CLIENT_DATA_EXTRACT_ROOT"

            prepare_extraction_root
            printf "RESULT2=%s\n" "$CLIENT_DATA_EXTRACT_ROOT"

            if [[ -L "$CLIENT_DATA/Data" ]]; then
                printf "SYMLINK=1\n"
            else
                printf "SYMLINK=0\n"
            fi

            # Deny the path the extractor actually reads (via Data/): the
            # client data is then unreadable from the extractor point of
            # view, so the staged copy under $INSTALLROOT must be used.
            export SUDO_DENY="'"$tmp_dir"'/client-src/Data/dbc.MPQ"
            mkdir -p "$INSTALLROOT/client-data"
            touch "$INSTALLROOT/client-data/dbc.MPQ"
            prepare_extraction_root
            printf "RESULT3=%s\n" "$CLIENT_DATA_EXTRACT_ROOT"
        ' 2>/dev/null
    )"
    rm -rf "$tmp_dir"

    assert_equals "$tmp_dir/client-src" \
        "$(printf '%s\n' "$output" | sed -n 's/^RESULT1=//p')" \
        "extraction root defaults to the client data folder"
    assert_equals "$tmp_dir/client-src" \
        "$(printf '%s\n' "$output" | sed -n 's/^RESULT2=//p')" \
        "extraction root preparation is idempotent"
    assert_equals "1" \
        "$(printf '%s\n' "$output" | sed -n 's/^SYMLINK=//p')" \
        "Data/Data self-symlink is created for extractor compatibility"
    assert_equals "1" \
        "$(printf '%s\n' "$output" | grep -c 'RESULT3=.*root/client-data')" \
        "unreadable client data falls back to the staged client-data copy"
}

# ensure_database_server's three provisioning paths, with every external
# command stubbed: adopt a running reachable server, install a server when
# none is running, and refuse (with an error marker, at adoption time) a
# running server root cannot administer.
test_database_server_provisioning() {
    local tmp_dir state capture failed=0
    tmp_dir="$(mktemp -d)"
    state="$tmp_dir/state"
    capture="$tmp_dir/capture"
    mkdir -p "$tmp_dir/bin" "$tmp_dir/bin2" "$state"

    cat > "$tmp_dir/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf 'systemctl:%s\n' "\$*" >> '$capture'
if [[ "\${1:-}" == "is-active" ]]; then
    [[ -f '$state/active' ]] && exit 0
    exit 3
fi
if [[ "\${1:-}" == "start" ]]; then
    touch '$state/active'
fi
exit 0
EOF
    # apt-get records every call; installing either package also provides
    # the mysql binary (bin2 is the only PATH entry that ever holds mysql).
    cat > "$tmp_dir/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf 'apt-get:%s\n' "\$*" >> '$capture'
case " \$* " in
    *" mysql-client "*) cp '$tmp_dir/mysql-stub' '$tmp_dir/bin2/mysql' ;;
    *" mysql-server "*) cp '$tmp_dir/mysql-stub' '$tmp_dir/bin2/mysql' ;;
esac
exit 0
EOF
    # The mysql client: connectable (as root, via the socket) only while a
    # server is active and not flagged unreachable.
    cat > "$tmp_dir/mysql-stub" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "-e" ]] || exit 2
[[ -f '$state/unreachable' ]] && exit 1
[[ -f '$state/active' ]] || exit 1
exit 0
EOF
    chmod +x "$tmp_dir/bin/systemctl" "$tmp_dir/bin/apt-get" "$tmp_dir/mysql-stub"

    # run_scenario NAME PRELUDE — sources the installer, runs the prelude
    # (flag/client setup), then ensure_database_server; captures rc + output.
    run_scenario() {
        local name="$1" prelude="$2"
        rm -rf "$state" "$tmp_dir/bin2"
        mkdir -p "$state" "$tmp_dir/bin2"
        : > "$capture"
        INSTALL_LOG="$tmp_dir/install-$name.log" \
        PATH="$tmp_dir/bin2:$tmp_dir/bin:$PATH" \
        REPO_ROOT="$REPO_ROOT" \
        bash -c '
            set -u
            source "$REPO_ROOT/vmangos_setup.sh"
            '"$prelude"'
            set +e
            ensure_database_server
            rc=$?
            set -e
            printf "RC=%s\n" "$rc"
        ' > "$tmp_dir/out-$name" 2>/dev/null
    }

    # A. A running, reachable server is adopted; nothing is installed.
    run_scenario adopt \
        "touch '$state/active'; cp '$tmp_dir/mysql-stub' '$tmp_dir/bin2/mysql'"
    assert_equals "0" "$(sed -n 's/^RC=//p' "$tmp_dir/out-adopt")" \
        "a running reachable server is adopted" || failed=1
    assert_equals "1" \
        "$(grep -c 'Using existing MySQL/MariaDB server (already reachable)' "$tmp_dir/out-adopt" || true)" \
        "adoption of a reachable server is logged" || failed=1
    assert_equals "0" \
        "$(grep -c '^apt-get:' "$capture" || true)" \
        "adopting a reachable server installs nothing" || failed=1

    # B. No server running: mysql-server is installed and started.
    run_scenario install ""
    assert_equals "0" "$(sed -n 's/^RC=//p' "$tmp_dir/out-install")" \
        "a fresh host provisions its own server" || failed=1
    assert_equals "1" \
        "$(grep -c '^apt-get:install -y mysql-server$' "$capture" || true)" \
        "no running server means mysql-server is installed" || failed=1
    assert_equals "1" \
        "$(grep -c '^systemctl:start mysql$' "$capture" || true)" \
        "the installed server is started" || failed=1
    assert_equals "1" \
        "$(grep -c 'installed, started, and reachable' "$tmp_dir/out-install" || true)" \
        "a provisioned server is confirmed reachable" || failed=1

    # C. A server is running but root cannot connect: refused at adoption
    #    time with an error marker, not adopted to fail later at grants.
    run_scenario unreachable \
        "touch '$state/active' '$state/unreachable'; cp '$tmp_dir/mysql-stub' '$tmp_dir/bin2/mysql'"
    assert_equals "1" "$(sed -n 's/^RC=//p' "$tmp_dir/out-unreachable")" \
        "a running but unreachable server is refused" || failed=1
    assert_equals "1" \
        "$(grep -c '^@@VMANGOS v1 phase=database event=error' "$tmp_dir/out-unreachable" || true)" \
        "refusing an unreachable server emits a database error marker" || failed=1
    assert_equals "1" \
        "$(grep '^@@VMANGOS v1 ' "$tmp_dir/out-unreachable" | grep -c 'msg="A database server is running but root cannot connect to it"' || true)" \
        "the error marker names the real problem" || failed=1
    assert_equals "1" \
        "$(grep -c 'cannot administer' "$tmp_dir/out-unreachable" || true)" \
        "the refusal names the exact broken check" || failed=1
    assert_equals "0" \
        "$(grep -c '^apt-get:' "$capture" || true)" \
        "an unreachable server with a client present installs nothing" || failed=1

    # D. A server is running and reachable, but the client is missing: the
    #    client is installed and the server adopted.
    run_scenario client-missing "touch '$state/active'"
    assert_equals "0" "$(sed -n 's/^RC=//p' "$tmp_dir/out-client-missing")" \
        "a running server without a client is adopted after client install" || failed=1
    assert_equals "1" \
        "$(grep -c '^apt-get:install -y mysql-client$' "$capture" || true)" \
        "only the mysql client is installed for an adoptable server" || failed=1
    assert_equals "0" \
        "$(grep -c '^apt-get:install -y mysql-server' "$capture" || true)" \
        "no second server is installed next to a running one" || failed=1

    # E. A server is running, the client is missing, and it stays
    #    unreachable after the client install: still refused with a marker.
    run_scenario client-missing-unreachable "touch '$state/active' '$state/unreachable'"
    assert_equals "1" "$(sed -n 's/^RC=//p' "$tmp_dir/out-client-missing-unreachable")" \
        "a server that stays unreachable after client install is refused" || failed=1
    assert_equals "1" \
        "$(grep -c '^@@VMANGOS v1 phase=database event=error' "$tmp_dir/out-client-missing-unreachable" || true)" \
        "the refusal after client install emits an error marker" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

# The symlink farm staged over read-only client data: created with per-MPQ
# symlinks plus the Data/ entry, and reused as-is (not rebuilt) on a resume.
test_client_data_symlink_farm() {
    local tmp_dir output failed=0
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin" "$tmp_dir/client" "$tmp_dir/root"

    cat > "$tmp_dir/bin/sudo" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-u" ]]; then shift 2; fi
if [[ "\${1:-}" == "test" ]]; then
    if [[ "\${3:-}" == "$tmp_dir/client/Data/dbc.MPQ" ]]; then exit 1; fi
    [[ -r "\${3:-}" ]] && exit 0
    exit 1
fi
exec "\$@"
EOF
    chmod +x "$tmp_dir/bin/sudo"

    touch "$tmp_dir/client/dbc.MPQ" "$tmp_dir/client/terrain.MPQ" "$tmp_dir/client/patch.MPQ"
    mkdir -p "$tmp_dir/client/Interface"
    # Read-only client data (like a :ro mount): the self-symlink cannot be
    # created in place, so the farm under the install root is the only way.
    chmod a-w "$tmp_dir/client"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        PATH="$tmp_dir/bin:$PATH" \
        REPO_ROOT="$REPO_ROOT" \
        FARM_TEST_TMP="$tmp_dir" \
        bash -c '
            set -euo pipefail
            source "$REPO_ROOT/vmangos_setup.sh"
            INSTALLROOT="$FARM_TEST_TMP/root"
            CLIENT_DATA="$FARM_TEST_TMP/client"
            MANGOSOSUSER="mangos"
            STAGED="$FARM_TEST_TMP/root/client-data"

            prepare_extraction_root
            printf "ROOT1=%s\n" "$CLIENT_DATA_EXTRACT_ROOT"
            [ -L "$STAGED/dbc.MPQ" ] && printf "DBC_LINK=1\n"
            [ "$(readlink "$STAGED/dbc.MPQ")" = "$FARM_TEST_TMP/client/dbc.MPQ" ] && printf "DBC_TARGET=1\n"
            [ -L "$STAGED/Data" ] && [ "$(readlink "$STAGED/Data")" = "." ] && printf "DATA_LINK=1\n"
            [ -L "$STAGED/Interface" ] && printf "INTERFACE_LINK=1\n"

            # A resume re-enters preparation: the farm must be reused, not
            # rebuilt (the sentinel only survives if nothing rm -rf-ed it).
            touch "$STAGED/.sentinel"
            prepare_extraction_root
            printf "ROOT2=%s\n" "$CLIENT_DATA_EXTRACT_ROOT"
            [ -f "$STAGED/.sentinel" ] && printf "SENTINEL=1\n"
        ' 2>/dev/null
    )"
    chmod u+w "$tmp_dir/client"
    rm -rf "$tmp_dir"

    assert_equals "$tmp_dir/root/client-data" \
        "$(printf '%s\n' "$output" | sed -n 's/^ROOT1=//p')" \
        "read-only client data is staged as the symlink farm" || failed=1
    assert_equals "1" "$(printf '%s\n' "$output" | sed -n 's/^DBC_LINK=//p')" \
        "farm entries are symlinks, not copies" || failed=1
    assert_equals "1" "$(printf '%s\n' "$output" | sed -n 's/^DBC_TARGET=//p')" \
        "farm symlinks point at the read-only client data" || failed=1
    assert_equals "1" "$(printf '%s\n' "$output" | sed -n 's/^DATA_LINK=//p')" \
        "the farm provides the Data/ self-symlink the extractor needs" || failed=1
    assert_equals "1" "$(printf '%s\n' "$output" | sed -n 's/^INTERFACE_LINK=//p')" \
        "the Interface directory is part of the farm" || failed=1
    assert_equals "$tmp_dir/root/client-data" \
        "$(printf '%s\n' "$output" | sed -n 's/^ROOT2=//p')" \
        "a resumed install reuses the staged farm" || failed=1
    assert_equals "1" "$(printf '%s\n' "$output" | sed -n 's/^SENTINEL=//p')" \
        "reusing the farm does not rebuild it" || failed=1

    return "$failed"
}

# An interrupted vmap extraction leaves a partial Buildings dir; the resume
# must clear it (vmapextractor refuses polluted directories) instead of
# silently downgrading to a vmap-less install.
test_extraction_resume_clears_partial_vmaps() {
    local tmp_dir root client output failed=0
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    client="$tmp_dir/client-src"
    mkdir -p "$tmp_dir/bin" "$client" "$root/run/bin/Extractors" "$root/client-data" "$root/.install-checkpoints" "$root/Buildings"

    cat > "$tmp_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
if [[ "${1:-}" == "test" ]]; then
    [[ -r "${3:-}" ]] && exit 0
    exit 1
fi
exec "$@"
EOF
    cat > "$tmp_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$tmp_dir/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$tmp_dir/bin/sudo" "$tmp_dir/bin/id" "$tmp_dir/bin/chown"

    touch "$client/dbc.MPQ" "$client/terrain.MPQ" "$root/client-data/dbc.MPQ"
    # What the killed first attempt left behind.
    touch "$root/Buildings/partial-from-interrupted-run"

    cat > "$root/run/bin/Extractors/MapExtractor" <<'EOF'
#!/usr/bin/env bash
mkdir -p dbc maps
touch dbc/Map.dbc maps/0004331.map
exit 0
EOF
    cat > "$root/run/bin/Extractors/VMapExtractor" <<EOF
#!/usr/bin/env bash
printf 'vmapextractor:%s\n' "\$*" >> '$tmp_dir/capture'
mkdir -p Buildings
touch Buildings/fresh-output.wmo
exit 0
EOF
    cat > "$root/run/bin/Extractors/VMapAssembler" <<'EOF'
#!/usr/bin/env bash
mkdir -p vmaps
touch vmaps/000.vmtree
exit 0
EOF
    cat > "$root/run/bin/Extractors/MoveMapGenerator" <<'EOF'
#!/usr/bin/env bash
mkdir -p mmaps
touch mmaps/000.mmap
exit 0
EOF
    chmod +x "$root/run/bin/Extractors/"*

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        refresh_runtime_paths
        CLIENT_DATA="'"$client"'"
        MANGOSOSUSER="mangos"
        export SUDO_DENY="'"$client"'/dbc.MPQ"

        phase_data_extraction
    ' > "$tmp_dir/phase.out" 2>/dev/null
    output="$(cat "$tmp_dir/phase.out")"

    assert_equals "1" \
        "$(grep -c 'Clearing partial vmap extraction output' "$tmp_dir/phase.out" || true)" \
        "a partial Buildings dir from an earlier attempt is cleared with a warning" || failed=1
    assert_equals "1" \
        "$(grep -c '^vmapextractor:' "$tmp_dir/capture" 2>/dev/null || true)" \
        "vmapextractor re-runs on the resume" || failed=1
    assert_equals "0" \
        "$(test -e "$root/Buildings/partial-from-interrupted-run" && echo 1 || echo 0)" \
        "the stale partial Buildings content is gone" || failed=1
    assert_equals "1" \
        "$(test -e "$root/Buildings/fresh-output.wmo" && echo 1 || echo 0)" \
        "the re-run extraction produced fresh output" || failed=1
    assert_equals "1" \
        "$(grep -c 'phase=extraction event=done' "$tmp_dir/phase.out" || true)" \
        "extraction still completes" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_extraction_phase_invocations() {
    local tmp_dir output root client
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    client="$tmp_dir/client-src"
    mkdir -p "$tmp_dir/bin" "$client" "$root/run/bin/Extractors" "$root/client-data" "$root/.install-checkpoints"

    cat > "$tmp_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
if [[ "${1:-}" == "test" ]]; then
    if [[ "${3:-}" == "${SUDO_DENY:-__no_deny__}" ]]; then exit 1; fi
    [[ -r "${3:-}" ]] && exit 0
    exit 1
fi
exec "$@"
EOF
    # The phase ensures the service account on entry, so id/useradd must be
    # stubbed: real useradd would try to create a system user on the test box.
    cat > "$tmp_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "${FAKE_MISSING_USER:-mangos}" ]]; then exit 1; fi
exec /usr/bin/id "$@"
EOF
    cat > "$tmp_dir/bin/useradd" <<EOF
#!/usr/bin/env bash
printf 'useradd:%s\n' "\$*" >> '$tmp_dir/capture'
exit 0
EOF
    cat > "$tmp_dir/bin/chown" <<EOF
#!/usr/bin/env bash
printf 'chown:%s\n' "\$*" >> '$tmp_dir/capture'
exit 0
EOF
    chmod +x "$tmp_dir/bin/sudo" "$tmp_dir/bin/id" "$tmp_dir/bin/useradd" "$tmp_dir/bin/chown"

    touch "$client/dbc.MPQ" "$client/terrain.MPQ" "$root/client-data/dbc.MPQ"

    cat > "$root/run/bin/Extractors/MapExtractor" <<EOF
#!/usr/bin/env bash
printf 'mapextractor:%s\n' "\$*" >> '$tmp_dir/capture'
echo 'Extracted 733 DBC files'
mkdir -p dbc maps
touch dbc/Map.dbc maps/0004331.map
exit 0
EOF
    cat > "$root/run/bin/Extractors/VMapExtractor" <<EOF
#!/usr/bin/env bash
printf 'vmapextractor:%s\n' "\$*" >> '$tmp_dir/capture'
mkdir -p Buildings
touch Buildings/0001_0000.wmo
exit 0
EOF
    cat > "$root/run/bin/Extractors/VMapAssembler" <<EOF
#!/usr/bin/env bash
printf 'vmap_assembler:%s\n' "\$*" >> '$tmp_dir/capture'
if [[ "\${ASM_FAIL:-0}" == "1" ]]; then exit 1; fi
mkdir -p vmaps
touch vmaps/000.vmtree
exit 0
EOF
    cat > "$root/run/bin/Extractors/MoveMapGenerator" <<EOF
#!/usr/bin/env bash
printf 'MoveMapGen:%s\n' "\$*" >> '$tmp_dir/capture'
mkdir -p mmaps
touch mmaps/000.mmap
exit 0
EOF
    chmod +x "$root/run/bin/Extractors/"*

    # The phase's progress heartbeat is a background loop that inherits
    # stdout; capturing with $(...) would block on the open pipe, so the
    # run is redirected to a file instead. No pipefail here on purpose:
    # the phase (like production vmangos_setup.sh) runs under plain set -e
    # and inspects PIPESTATUS directly.
    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        refresh_runtime_paths
        CLIENT_DATA="'"$client"'"
        MANGOSOSUSER="mangos"
        export SUDO_DENY="'"$client"'/dbc.MPQ"

        phase_data_extraction

        export ASM_FAIL=1
        rm -f "'"$root"'/vmaps/000.vmtree"
        phase_data_extraction
    ' > "$tmp_dir/phase.out" 2>/dev/null
    output="$(cat "$tmp_dir/phase.out")"

    local capture failed=0
    capture="$(cat "$tmp_dir/capture" 2>/dev/null)"

    assert_equals "mapextractor:--silent -i $root/client-data" \
        "$(printf '%s\n' "$capture" | grep '^mapextractor:' | head -1)" \
        "mapextractor runs silent against the staged extraction root" || failed=1
    assert_equals "vmapextractor:--silent -d $root/client-data" \
        "$(printf '%s\n' "$capture" | grep '^vmapextractor:' | head -1)" \
        "vmapextractor runs silent with its -d input flag" || failed=1
    assert_equals "vmap_assembler:--silent $root/Buildings $root/vmaps" \
        "$(printf '%s\n' "$capture" | grep '^vmap_assembler:' | head -1)" \
        "vmap_assembler assembles Buildings into vmaps, silently" || failed=1
    assert_equals "MoveMapGen:--silent --offMeshInput offmesh.txt" \
        "$(printf '%s\n' "$capture" | grep '^MoveMapGen:')" \
        "MoveMapGen runs silent with the offmesh file" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$capture" | grep -c '^MoveMapGen:')" \
        "MoveMapGen is skipped when the assembler fails (no masked pipeline)" || failed=1
    assert_equals "2" \
        "$(printf '%s\n' "$capture" | grep -c '^chown:mangos:mangos '"$root"'/vmaps$')" \
        "the vmaps directory is handed to the service user before assembly" || failed=1
    assert_equals "2" \
        "$(printf '%s\n' "$output" | grep -c 'Using previously staged client data')" \
        "extraction phase prepares its root on demand (resume safety)" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$output" | grep -c 'Copying client data')" \
        "staged client data is reused instead of re-copied" || failed=1
    assert_equals "DATA_DONE" "$(cat "$root/.install-checkpoints/checkpoint")" \
        "extraction phase completes and checkpoints" || failed=1
    assert_equals "2" \
        "$(printf '%s\n' "$capture" | grep -c '^useradd:--system ')" \
        "the service account is ensured on every phase entry (resume safety)" || failed=1
    assert_equals "1" \
        "$(if [[ -L "$root/5875/dbc" && -L "$root/5875/maps" && -L "$root/5875/vmaps" && -L "$root/5875/mmaps" ]]; then echo 1; else echo 0; fi)" \
        "versioned 5875 data symlinks are created on success" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$output" | grep -c 'VMap assembler had issues')" \
        "assembler failure is reported, not masked" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$output" | grep -c 'Skipping movement map generation')" \
        "mmap step is skipped loudly when vmaps failed" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_extraction_failure_honesty() {
    local tmp_dir root client capture failed=0
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    client="$tmp_dir/client-src"
    mkdir -p "$tmp_dir/bin" "$client" "$root/run/bin/Extractors" "$root/client-data" "$root/.install-checkpoints"

    cat > "$tmp_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
if [[ "${1:-}" == "test" ]]; then
    [[ -r "${3:-}" ]] && exit 0
    exit 1
fi
exec "$@"
EOF
    cat > "$tmp_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "${FAKE_MISSING_USER:-mangos}" ]]; then exit 1; fi
exec /usr/bin/id "$@"
EOF
    cat > "$tmp_dir/bin/useradd" <<EOF
#!/usr/bin/env bash
printf 'useradd:%s\n' "\$*" >> '$tmp_dir/capture'
exit 0
EOF
    cat > "$tmp_dir/bin/chown" <<EOF
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$tmp_dir/bin/sudo" "$tmp_dir/bin/id" "$tmp_dir/bin/useradd" "$tmp_dir/bin/chown"

    touch "$client/dbc.MPQ" "$client/terrain.MPQ" "$root/client-data/dbc.MPQ"

    cat > "$root/run/bin/Extractors/MapExtractor" <<EOF
#!/usr/bin/env bash
printf 'mapextractor:%s\n' "\$*" >> '$tmp_dir/capture'
if [[ "\${MAPEXTRACT_FAIL:-0}" == "1" ]]; then exit 1; fi
mkdir -p dbc maps
touch dbc/Map.dbc maps/0004331.map
exit 0
EOF
    # Exits 0 but leaves Buildings/ empty: output-dir validation must catch it.
    cat > "$root/run/bin/Extractors/VMapExtractor" <<EOF
#!/usr/bin/env bash
printf 'vmapextractor:%s\n' "\$*" >> '$tmp_dir/capture'
mkdir -p Buildings
exit 0
EOF
    cat > "$root/run/bin/Extractors/VMapAssembler" <<EOF
#!/usr/bin/env bash
printf 'vmap_assembler:%s\n' "\$*" >> '$tmp_dir/capture'
mkdir -p vmaps
touch vmaps/000.vmtree
exit 0
EOF
    cat > "$root/run/bin/Extractors/MoveMapGenerator" <<EOF
#!/usr/bin/env bash
printf 'MoveMapGen:%s\n' "\$*" >> '$tmp_dir/capture'
mkdir -p mmaps
touch mmaps/000.mmap
exit 0
EOF
    chmod +x "$root/run/bin/Extractors/"*

    # Run under plain set -eu like production (the phase inspects PIPESTATUS
    # directly); output to a file, rc captured, so failing runs stay assertable.
    local run_rc
    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    CLIENT_DATA="" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        refresh_runtime_paths
        CLIENT_DATA=""
        MANGOSOSUSER="mangos"

        phase_data_extraction
    ' > "$tmp_dir/run1.out" 2>/dev/null || run_rc=$?
    assert_equals "1" "${run_rc:-0}" \
        "no client data aborts the extraction phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$(cat "$tmp_dir/run1.out")" | grep -c 'NO CLIENT DATA')" \
        "no-client-data stop is explained to the user" || failed=1
    if [ -f "$root/.install-checkpoints/checkpoint" ]; then
        assert_equals "absent" "present" \
            "no client data must not checkpoint DATA_DONE" || failed=1
    else
        echo "✓ no client data must not checkpoint DATA_DONE"
    fi

    run_rc=0
    MAPEXTRACT_FAIL=1 \
    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        refresh_runtime_paths
        CLIENT_DATA="'"$client"'"
        MANGOSOSUSER="mangos"

        phase_data_extraction
    ' > "$tmp_dir/run2.out" 2>/dev/null || run_rc=$?
    assert_equals "1" "${run_rc:-0}" \
        "mapextractor failure aborts the extraction phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$(cat "$tmp_dir/run2.out")" | grep -c 'Map extraction failed')" \
        "mapextractor failure is reported, not masked by tee" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$(cat "$tmp_dir/run2.out")" | grep -c 'DATA EXTRACTION FAILED')" \
        "failed extraction prints the failure block with manual commands" || failed=1
    if [ -f "$root/.install-checkpoints/checkpoint" ]; then
        assert_equals "absent" "present" \
            "failed extraction must not checkpoint DATA_DONE" || failed=1
    else
        echo "✓ failed extraction must not checkpoint DATA_DONE"
    fi

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        refresh_runtime_paths
        CLIENT_DATA="'"$client"'"
        MANGOSOSUSER="mangos"

        phase_data_extraction
    ' > "$tmp_dir/run3.out" 2>/dev/null
    assert_equals "1" \
        "$(printf '%s\n' "$(cat "$tmp_dir/run3.out")" | grep -c 'VMap extractor failed or produced no Buildings output')" \
        "vmapextractor success with empty Buildings output is caught" || failed=1
    assert_equals "DATA_DONE" "$(cat "$root/.install-checkpoints/checkpoint" 2>/dev/null)" \
        "gaps-only extraction (vmaps missing) still checkpoints and completes" || failed=1

    capture="$(cat "$tmp_dir/capture" 2>/dev/null)"
    assert_equals "2" \
        "$(printf '%s\n' "$capture" | grep -c '^useradd:--system ')" \
        "service account is ensured when the phase has client data" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$capture" | grep -c '^vmap_assembler:' )" \
        "assembler is skipped when Buildings validation failed" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_download_retry_honesty() {
    local tmp_dir rc
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    cat > "$tmp_dir/bin/wget" <<'EOF'
#!/usr/bin/env bash
out=""
for a in "$@"; do
    if [[ "$prev" == "-O" ]]; then out="$a"; fi
    prev="$a"
done
if [[ "${WGET_MODE:-fail}" == "fail" ]]; then
    : > "${out:-/dev/null}"
    exit 8
fi
if [[ "${WGET_MODE:-}" == "empty" ]]; then
    : > "${out:?}"
    exit 0
fi
printf 'database-bytes\n' > "${out:?}"
exit 0
EOF
    chmod +x "$tmp_dir/bin/wget"

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    VMANGOS_DOWNLOAD_RETRY_DELAY=0 \
    bash -c '
        set -euo pipefail
        source "$REPO_ROOT/vmangos_setup.sh"
        if download_with_retry "https://example.invalid/db.zip" out.zip; then
            printf "RESULT=pass\n"
        else
            printf "RESULT=fail\n"
        fi
        WGET_MODE=ok download_with_retry "https://example.invalid/db.zip" ok.zip && \
            printf "RESULT2=%s\n" "$(cat ok.zip)"
        WGET_MODE=empty download_with_retry "https://example.invalid/db.zip" empty.zip || \
            printf "RESULT3=failed-empty\n"
    ' > "$tmp_dir/test.out" 2>&1
    rc=$?

    local failed=0
    assert_equals "0" "$rc" "download helper survives both outcomes without set -e aborts" || failed=1
    assert_equals "fail" \
        "$(sed -n 's/^RESULT=//p' "$tmp_dir/test.out")" \
        "wget error fails the download (no tee masking)" || failed=1
    assert_equals "3" \
        "$(grep -c 'wget exited with status 8' "$tmp_dir/install.log" || true)" \
        "each failed attempt reports wget's status in the log" || failed=1
    assert_equals "3" \
        "$(grep -c 'Downloaded file is empty' "$tmp_dir/install.log" || true)" \
        "empty output file fails the download even when wget exits 0" || failed=1
    assert_equals "failed-empty" \
        "$(sed -n 's/^RESULT3=//p' "$tmp_dir/test.out")" \
        "empty-file download ultimately returns failure" || failed=1
    assert_equals "database-bytes" \
        "$(sed -n 's/^RESULT2=//p' "$tmp_dir/test.out")" \
        "successful download returns the populated file" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_world_db_url_resolution() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    cat > "$tmp_dir/bin/wget" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *api.github.com*)
        if [[ "${API_MODE:-ok}" == "ok" ]]; then
            printf '%s\n' '{"assets":[{"name":"db-abc123.zip","browser_download_url":"https://github.com/vmangos/core/releases/download/db_latest/db-abc123.zip"},{"name":"db-sqlite-abc123.zip","browser_download_url":"https://github.com/vmangos/core/releases/download/db_latest/db-sqlite-abc123.zip"}]}'
            exit 0
        fi
        ;;
esac
exit 1
EOF
    chmod +x "$tmp_dir/bin/wget"

    local output
    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        PATH="$tmp_dir/bin:$PATH" \
        REPO_ROOT="$REPO_ROOT" \
        bash -c '
            set -euo pipefail
            source "$REPO_ROOT/vmangos_setup.sh"
            resolve_world_db_urls
            printf "N=%s\n" "${#WORLD_DB_URLS[@]}"
            printf "U1=%s\n" "${WORLD_DB_URLS[0]:-none}"
            printf "U2=%s\n" "${WORLD_DB_URLS[1]:-none}"
            export API_MODE=down
            resolve_world_db_urls
            printf "D1=%s\n" "${WORLD_DB_URLS[0]:-none}"
            printf "D2=%s\n" "${WORLD_DB_URLS[1]:-none}"
        ' 2>/dev/null
    )"

    local failed=0
    assert_equals "2" "$(sed -n 's/^N=//p' <<<"$output")" \
        "resolver returns resolved URL plus fallback" || failed=1
    assert_equals "https://github.com/vmangos/core/releases/download/db_latest/db-abc123.zip" \
        "$(sed -n 's/^U1=//p' <<<"$output")" \
        "current db_latest asset is resolved from the GitHub API" || failed=1
    assert_equals "https://github.com/vmangos/core/releases/download/db_latest/db-810fef8.zip" \
        "$(sed -n 's/^U2=//p' <<<"$output")" \
        "known-good fallback URL is kept" || failed=1
    assert_equals "https://github.com/vmangos/core/releases/download/db_latest/db-810fef8.zip" \
        "$(sed -n 's/^D1=//p' <<<"$output")" \
        "fallback is used when the API is unreachable" || failed=1
    assert_equals "none" "$(sed -n 's/^D2=//p' <<<"$output")" \
        "no duplicate entries when only the fallback is available" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_config_phase_local_db_host() {
    local tmp_dir root
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$root/run/etc"

    cat > "$root/run/etc/realmd.conf.dist" <<'EOF'
LoginDatabaseInfo = "127.0.0.1;3306;mangos;mangos;realmd"
BindIP = "0.0.0.0"
EOF
    cat > "$root/run/etc/mangosd.conf.dist" <<'EOF'
LoginDatabase.Info = "127.0.0.1;3306;mangos;mangos;realmd"
WorldDatabase.Info = "127.0.0.1;3306;mangos;mangos;mangos"
CharacterDatabase.Info = "127.0.0.1;3306;mangos;mangos;characters"
LogsDatabase.Info = "127.0.0.1;3306;mangos;mangos;logs"
DataDir = "."
LogsDir = ""
HonorDir = ""
vmap.enableLOS = 1
BindIP = "0.0.0.0"
EOF

    INSTALL_LOG="$tmp_dir/install.log" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -euo pipefail
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        SERVERIP="10.0.5.5"
        MANGOSDBUSER="mangos"
        MANGOSDBPASS="sekrit"
        AUTHDB="auth"
        WORLDDB="world"
        CHARACTERDB="characters"
        LOGSDB="logs"
        VMANGOS_PROVISION_TARGET="vmangos_only"
        phase_config_setup
    ' > "$tmp_dir/test.out" 2>&1

    local failed=0
    assert_equals "LoginDatabaseInfo = \"127.0.0.1;3306;mangos;sekrit;auth\"" \
        "$(grep '^LoginDatabaseInfo' "$root/run/etc/realmd.conf")" \
        "realmd connects to the local database, not the LAN IP" || failed=1
    assert_equals "BindIP = \"10.0.5.5\"" \
        "$(grep '^BindIP' "$root/run/etc/realmd.conf")" \
        "realmd still binds the LAN IP for clients" || failed=1
    assert_equals "WorldDatabase.Info = \"127.0.0.1;3306;mangos;sekrit;world\"" \
        "$(grep '^WorldDatabase.Info' "$root/run/etc/mangosd.conf")" \
        "mangosd world database points at 127.0.0.1" || failed=1
    assert_equals "0" \
        "$(grep -c ';3306;.*10\.0\.5\.5' "$root/run/etc/mangosd.conf" "$root/run/etc/realmd.conf" | awk -F: '{s+=$2} END {print s}')" \
        "no database tuple keeps the LAN IP" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_marker_protocol_format() {
    local tmp_dir output failed=0
    tmp_dir="$(mktemp -d)"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        REPO_ROOT="$REPO_ROOT" \
        bash -c '
            set -euo pipefail
            source "$REPO_ROOT/vmangos_setup.sh"
            log_marker build start
            log_marker build progress "percent=42" "step=Compiling the core"
            log_marker build "done"
            log_marker build error "msg=it failed badly" "hint=fix the thing"
        ' 2>/dev/null
    )"
    rm -rf "$tmp_dir"

    assert_equals "@@VMANGOS v1 phase=build event=start" \
        "$(printf '%s\n' "$output" | sed -n 1p)" \
        "start marker is the protocol prefix plus phase and event" || failed=1
    assert_equals "@@VMANGOS v1 phase=build event=progress percent=42 step=\"Compiling the core\"" \
        "$(printf '%s\n' "$output" | sed -n 2p)" \
        "progress marker quotes values that contain spaces" || failed=1
    assert_equals "@@VMANGOS v1 phase=build event=done" \
        "$(printf '%s\n' "$output" | sed -n 3p)" \
        "done marker carries phase and event only" || failed=1
    assert_equals "@@VMANGOS v1 phase=build event=error msg=\"it failed badly\" hint=\"fix the thing\"" \
        "$(printf '%s\n' "$output" | sed -n 4p)" \
        "error marker carries msg and hint" || failed=1
    return "$failed"
}

test_prerequisites_markers() {
    local tmp_dir root failed=0 markers order
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$tmp_dir/bin" "$root/.install-checkpoints"

    cat > "$tmp_dir/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
if [[ "${APT_MODE:-ok}" == "fail" ]]; then exit 1; fi
exit 0
EOF
    cat > "$tmp_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$tmp_dir/bin/apt-get" "$tmp_dir/bin/id"

    # phase_prerequisites never toggles set -e, so the failing run can be
    # captured from inside the script (unlike phase_build, which re-enables
    # set -e inside its failure branch).
    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        MANGOSOSUSER="mangos"
        refresh_runtime_paths
        phase_prerequisites
        export APT_MODE=fail
        set +e
        phase_prerequisites
        rc=$?
        set -e
        printf "RC=%s\n" "$rc"
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "2" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=prerequisites event=start' || true)" \
        "every prerequisites run opens with a start marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=prerequisites event=done' || true)" \
        "prerequisites emits a done marker on success" || failed=1
    order="$(printf '%s\n' "$markers" | awk '
        /phase=prerequisites event=start/ && s == 0 { s = NR }
        /phase=prerequisites event=done/ && d == 0 { d = NR }
        END { if (s && d && s < d) print "ok"; else print "bad" }
    ')"
    assert_equals "ok" "$order" "prerequisites start marker precedes its done marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=prerequisites event=error' || true)" \
        "prerequisites failure emits an error marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep 'phase=prerequisites event=error' | grep -c 'msg="apt-get update failed"' || true)" \
        "prerequisites error marker names the failing step" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep 'phase=prerequisites event=error' | grep -c 'hint=' || true)" \
        "prerequisites error marker carries a hint" || failed=1
    assert_equals "1" "$(sed -n 's/^RC=//p' "$tmp_dir/phase.out")" \
        "prerequisites failure still returns 1" || failed=1
    assert_equals "0" \
        "$(grep -c '@@VMANGOS' "$tmp_dir/install.log" || true)" \
        "markers never enter the install log" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_build_markers() {
    local tmp_dir root failed=0 markers order
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$tmp_dir/bin" "$root/.install-checkpoints"

    cat > "$tmp_dir/bin/cmake" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$tmp_dir/bin/make" <<'EOF'
#!/usr/bin/env bash
if [[ "${MAKE_MODE:-ok}" == "fail" ]]; then exit 1; fi
if [[ "$1" == "install" ]]; then
    mkdir -p "$INSTALLROOT/run/etc"
    touch "$INSTALLROOT/run/etc/mangosd.conf.dist"
    exit 0
fi
printf '[  5%%] Building CXX object CMakeFiles/core.dir/a.cpp.o\n'
printf '[ 50%%] Linking CXX executable mangosd\n'
exit 0
EOF
    chmod +x "$tmp_dir/bin/cmake" "$tmp_dir/bin/make"

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        export INSTALLROOT
        refresh_runtime_paths
        phase_build
        printf "CHECKPOINT=%s\n" "$(get_checkpoint)"
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=start' || true)" \
        "build opens with a start marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=progress percent=33 step=Configure' || true)" \
        "build reports the Configure milestone" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=progress percent=66 step=Compile' || true)" \
        "build reports the Compile milestone" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=done' || true)" \
        "build closes with a done marker" || failed=1
    order="$(printf '%s\n' "$markers" | awk '
        /phase=build event=start/ && s == 0 { s = NR }
        /percent=33/ && a == 0 { a = NR }
        /percent=66/ && b == 0 { b = NR }
        /phase=build event=done/ && d == 0 { d = NR }
        END { if (s && a && b && d && s < a && a < b && b < d) print "ok"; else print "bad" }
    ')"
    assert_equals "ok" "$order" "build markers arrive in start, Configure, Compile, done order" || failed=1
    assert_equals "BUILD_DONE" "$(sed -n 's/^CHECKPOINT=//p' "$tmp_dir/phase.out")" \
        "build success checkpoints BUILD_DONE" || failed=1
    assert_equals "0" \
        "$(grep -c '@@VMANGOS' "$tmp_dir/install.log" || true)" \
        "build markers never enter the install log" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_build_failure_marker() {
    local tmp_dir root failed=0 markers run_rc
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$tmp_dir/bin" "$root/.install-checkpoints"

    cat > "$tmp_dir/bin/cmake" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$tmp_dir/bin/make" <<'EOF'
#!/usr/bin/env bash
if [[ "${MAKE_MODE:-ok}" == "fail" ]]; then exit 1; fi
exit 0
EOF
    chmod +x "$tmp_dir/bin/cmake" "$tmp_dir/bin/make"

    # The phase re-enables set -e inside its failure branch, so the failing
    # run is captured from the process exit code (suite convention).
    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        export INSTALLROOT
        export MAKE_MODE=fail
        refresh_runtime_paths
        phase_build
    ' > "$tmp_dir/phase.out" 2>/dev/null || run_rc=$?

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "1" "${run_rc:-0}" "build failure still exits 1" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=error' || true)" \
        "build failure emits an error marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep 'phase=build event=error' | grep -c 'msg="Compilation failed"' || true)" \
        "build error marker names the failing step" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep 'phase=build event=error' | grep -c 'hint=' || true)" \
        "build error marker carries a hint" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=done' || true)" \
        "no done marker when the build fails" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_extraction_no_client_data_marker() {
    local tmp_dir root failed=0 markers
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$root"

    INSTALL_LOG="$tmp_dir/install.log" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        refresh_runtime_paths
        CLIENT_DATA=""
        set +e
        phase_data_extraction
        rc=$?
        set -e
        printf "RC=%s\n" "$rc"
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=extraction event=start' || true)" \
        "extraction opens with a start marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=extraction event=error' || true)" \
        "missing client data emits an error marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep 'phase=extraction event=error' | grep -c 'msg="No client data found"' || true)" \
        "extraction error marker names the missing input" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep 'phase=extraction event=error' | grep -c 'hint=' || true)" \
        "extraction error marker carries a hint" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=extraction event=done' || true)" \
        "no done marker when extraction fails" || failed=1
    assert_equals "1" "$(sed -n 's/^RC=//p' "$tmp_dir/phase.out")" \
        "extraction failure still returns 1" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
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
    run_test "Installer: Extraction root" test_extraction_root_preparation
    run_test "Installer: Client data symlink farm" test_client_data_symlink_farm
    run_test "Installer: Database server provisioning" test_database_server_provisioning
    run_test "Installer: Extraction resume clears partial vmaps" test_extraction_resume_clears_partial_vmaps
    run_test "Installer: Extraction phase" test_extraction_phase_invocations
    run_test "Installer: Extraction failure honesty" test_extraction_failure_honesty
    run_test "Installer: Download retry" test_download_retry_honesty
    run_test "Installer: World DB URLs" test_world_db_url_resolution
    run_test "Installer: Config local DB host" test_config_phase_local_db_host
    run_test "Installer: Marker protocol format" test_marker_protocol_format
    run_test "Installer: Prerequisites markers" test_prerequisites_markers
    run_test "Installer: Build markers" test_build_markers
    run_test "Installer: Build failure marker" test_build_failure_marker
    run_test "Installer: Extraction no client data marker" test_extraction_no_client_data_marker

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
