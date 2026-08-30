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

            export SUDO_DENY="'"$tmp_dir"'/client-src/dbc.MPQ"
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
    cat > "$tmp_dir/bin/chown" <<EOF
#!/usr/bin/env bash
printf 'chown:%s\n' "\$*" >> '$tmp_dir/capture'
exit 0
EOF
    chmod +x "$tmp_dir/bin/sudo" "$tmp_dir/bin/chown"

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
    run_test "Installer: Extraction phase" test_extraction_phase_invocations
    run_test "Installer: Download retry" test_download_retry_honesty
    run_test "Installer: World DB URLs" test_world_db_url_resolution
    run_test "Installer: Config local DB host" test_config_phase_local_db_host

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
