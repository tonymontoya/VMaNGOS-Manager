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
            log_marker database warn "msg=CREATE DATABASE failed for world"
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
    assert_equals "@@VMANGOS v1 phase=database event=warn msg=\"CREATE DATABASE failed for world\"" \
        "$(printf '%s\n' "$output" | sed -n 5p)" \
        "warn marker uses the same protocol as error markers" || failed=1
    return "$failed"
}

test_marker_helper_contracts() {
    local tmp_dir output failed=0
    tmp_dir="$(mktemp -d)"

    output="$(
        INSTALL_LOG="$tmp_dir/install.log" \
        REPO_ROOT="$REPO_ROOT" \
        bash -c '
            set -euo pipefail
            source "$REPO_ROOT/vmangos_setup.sh"
            set +e
            fail_marker build "it failed badly" "fix the thing"
            printf "FAIL_RC=%s\n" "$?"
            warn_marker database "CREATE DATABASE failed for world"
            printf "WARN_RC=%s\n" "$?"
            set -e
        ' 2>/dev/null
    )"
    rm -rf "$tmp_dir"

    assert_equals '@@VMANGOS v1 phase=build event=error msg="it failed badly" hint="fix the thing"' \
        "$(printf '%s\n' "$output" | sed -n 1p)" \
        "fail_marker emits the phase error marker" || failed=1
    assert_equals "1" "$(printf '%s\n' "$output" | sed -n 's/^FAIL_RC=//p')" \
        "fail_marker returns non-zero so guarded paths still fail" || failed=1
    assert_equals '@@VMANGOS v1 phase=database event=warn msg="CREATE DATABASE failed for world"' \
        "$(printf '%s\n' "$output" | sed -n 3p)" \
        "warn_marker emits the phase warn marker" || failed=1
    assert_equals "0" "$(printf '%s\n' "$output" | sed -n 's/^WARN_RC=//p')" \
        "warn_marker returns zero so the install continues" || failed=1
    return "$failed"
}

test_database_phase_markers() {
    local tmp_dir root failed=0 markers order
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$tmp_dir/bin" "$root/.install-checkpoints"

    cat > "$tmp_dir/bin/mysql" <<'EOF'
#!/usr/bin/env bash
sql="$*"
if [[ "${MYSQL_MODE:-ok}" == "flush-fail" && "$sql" == *"FLUSH PRIVILEGES"* ]]; then
    printf 'mysql: flush denied\n' >&2
    exit 1
fi
if [[ "${MYSQL_MODE:-ok}" == "create-fail" && "$sql" == *"CREATE DATABASE"*world* ]]; then
    printf 'mysql: create denied\n' >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$tmp_dir/bin/mysql"

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        MANGOSOSUSER="mangos"
        MANGOSDBUSER="mangos"
        MANGOSDBPASS="sekrit"
        SQLADMINIP="127.0.0.1"
        AUTHDB="auth"
        WORLDDB="world"
        CHARACTERDB="characters"
        LOGSDB="logs"
        refresh_runtime_paths

        phase_database_setup
        printf "HAPPY=%s\n" "$(get_checkpoint)"

        export MYSQL_MODE=create-fail
        phase_database_setup
        printf "CREATE_FAIL=%s\n" "$(get_checkpoint)"

        export MYSQL_MODE=flush-fail
        set +e
        phase_database_setup
        rc=$?
        set -e
        printf "FLUSH_RC=%s\n" "$rc"
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "DATABASE_DONE" "$(sed -n 's/^HAPPY=//p' "$tmp_dir/phase.out")" \
        "database phase checkpoints on success" || failed=1
    assert_equals "DATABASE_DONE" "$(sed -n 's/^CREATE_FAIL=//p' "$tmp_dir/phase.out")" \
        "a swallowed CREATE failure still finishes the phase" || failed=1
    assert_equals "1" "$(sed -n 's/^FLUSH_RC=//p' "$tmp_dir/phase.out")" \
        "a FLUSH failure fails the phase" || failed=1
    assert_equals "3" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=database event=start' || true)" \
        "every database run opens with a start marker" || failed=1
    assert_equals "2" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=database event=done' || true)" \
        "database emits done on success and on a warn-only run" || failed=1
    assert_equals '1' \
        "$(printf '%s\n' "$markers" | grep -c 'phase=database event=warn msg="CREATE DATABASE failed for world"' || true)" \
        "the swallowed CREATE failure leaves a warn marker" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=database event=error msg="Failed to apply database grants"' || true)" \
        "the FLUSH failure leaves an error marker" || failed=1
    order="$(printf '%s\n' "$markers" | awk '
        /event=warn/ { w = NR }
        /event=done/ && w && !d { d = NR }
        END { if (w && d && w < d) print "ok"; else print "bad" }
    ')"
    assert_equals "ok" "$order" "the warn marker precedes its run's done marker" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_source_phase_guards() {
    local tmp_dir failed=0 markers
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"
    touch "$tmp_dir/blocker"

    INSTALL_LOG="$tmp_dir/install.log" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        set +e
        INSTALLROOT="'"$tmp_dir"'/blocker/root"
        phase_source_download
        printf "MKDIR_RC=%s\n" "$?"
        set -e
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "1" "$(sed -n 's/^MKDIR_RC=//p' "$tmp_dir/phase.out")" \
        "an uncreatable install root fails the source phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c "event=error msg=\"Failed to create the installation directory" || true)" \
        "the mkdir death path emits the source error marker" || failed=1
    assert_equals "1" "$(printf '%s\n' "$markers" | grep -c 'hint=' || true)" \
        "the source guard marker carries a hint" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=source event=done' || true)" \
        "the failed source run never emits done" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_build_phase_directory_guards() {
    local tmp_dir root failed=0 markers
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$tmp_dir/bin" "$root"
    touch "$root/build"

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        set +e
        phase_build
        rc=$?
        set -e
        printf "BUILD_RC=%s\n" "$rc"
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "1" "$(sed -n 's/^BUILD_RC=//p' "$tmp_dir/phase.out")" \
        "an occupied build directory path fails the build phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=error msg="Failed to create the build directory"' || true)" \
        "the mkdir death path emits the build error marker" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=build event=done' || true)" \
        "the failed build run never emits done" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_db_import_entry_guard() {
    local tmp_dir failed=0 markers
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    INSTALL_LOG="$tmp_dir/install.log" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$tmp_dir"'/vanished"
        set +e
        phase_database_import
        rc=$?
        set -e
        printf "RC=%s\n" "$rc"
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "1" "$(sed -n 's/^RC=//p' "$tmp_dir/phase.out")" \
        "a missing install root fails the db-import phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c "event=error msg=\"Failed to enter the installation directory" || true)" \
        "the cd death path emits the db-import error marker" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_config_phase_manager_provision_guards() {
    local tmp_dir root failed=0 markers
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$tmp_dir/bin" "$root/run/etc" "$root/manager/config"

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

    # Scenario A: the manager config write fails (cat stubbed to fail), so the
    # heredoc death path emits the config error marker before anything else.
    cat > "$tmp_dir/bin/cat" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$tmp_dir/bin/cat"

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        SERVERIP="10.0.5.5"
        MANGOSDBUSER="mangos"
        MANGOSDBPASS="sekrit"
        MANGOSOSUSER="mangos"
        AUTHDB="auth"
        WORLDDB="world"
        CHARACTERDB="characters"
        LOGSDB="logs"
        VMANGOS_PROVISION_TARGET="vmangos_manager"
        set +e
        phase_config_setup
        rc=$?
        set -e
        printf "HEREDOC_RC=%s\n" "$rc"
    ' > "$tmp_dir/phase-a.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase-a.out" || true)"

    assert_equals "1" "$(sed -n 's/^HEREDOC_RC=//p' "$tmp_dir/phase-a.out")" \
        "a failing manager config write fails the config phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=config event=error msg="Failed to write the manager configuration"' || true)" \
        "the heredoc death path emits the config error marker" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=config event=done' || true)" \
        "the failed config run never emits done" || failed=1

    # Scenario B: the config write succeeds but the backups directory path is
    # occupied by a file, so the later mkdir death path fails the phase after
    # the password file was written (proving the happy path ran that far).
    rm -f "$tmp_dir/bin/cat"
    touch "$root/backups"

    INSTALL_LOG="$tmp_dir/install.log" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        SERVERIP="10.0.5.5"
        MANGOSDBUSER="mangos"
        MANGOSDBPASS="sekrit"
        MANGOSOSUSER="mangos"
        AUTHDB="auth"
        WORLDDB="world"
        CHARACTERDB="characters"
        LOGSDB="logs"
        VMANGOS_PROVISION_TARGET="vmangos_manager"
        set +e
        phase_config_setup
        rc=$?
        set -e
        printf "BACKUPS_RC=%s\n" "$rc"
    ' > "$tmp_dir/phase-b.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase-b.out" || true)"

    assert_equals "1" "$(sed -n 's/^BACKUPS_RC=//p' "$tmp_dir/phase-b.out")" \
        "an occupied backups path fails the config phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=config event=error msg="Failed to create the backups directory"' || true)" \
        "the mkdir death path emits the config error marker" || failed=1
    assert_equals "ok" \
        "$(test -f "$root/manager/config/manager.conf" && printf ok || printf missing)" \
        "the manager config was written before the phase failed" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_services_phase_unit_write_guard() {
    local tmp_dir root failed=0 markers
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    mkdir -p "$tmp_dir/bin" "$root"

    # The unit-file write is forced to fail for any user (root included) by
    # stubbing cat; the phase must die at its first guarded write.
    cat > "$tmp_dir/bin/cat" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$tmp_dir/bin/cat"

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        MANGOSOSUSER="mangos"
        set +e
        phase_service_setup
        rc=$?
        set -e
        printf "RC=%s\n" "$rc"
    ' > "$tmp_dir/phase.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase.out" || true)"

    assert_equals "1" "$(sed -n 's/^RC=//p' "$tmp_dir/phase.out")" \
        "a failing unit-file write fails the services phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=services event=error msg="Failed to write the auth service unit"' || true)" \
        "the service-file death path emits the services error marker" || failed=1
    assert_equals "0" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=services event=done' || true)" \
        "the failed services run never emits done" || failed=1

    rm -rf "$tmp_dir"
    return "$failed"
}

test_extraction_phase_chown_guards() {
    local tmp_dir root client failed=0 markers
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    client="$tmp_dir/client-src"
    mkdir -p "$tmp_dir/bin" "$root/.install-checkpoints" "$client"
    touch "$client/dbc.MPQ"

    cat > "$tmp_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
if [[ "${1:-}" == "test" ]]; then
    [[ "${SUDO_READ:-deny}" == "allow" ]] && exit 0
    exit 1
fi
exec "$@"
EOF
    cat > "$tmp_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$tmp_dir/bin/sudo" "$tmp_dir/bin/id"

    # Scenario A: client data is unreadable by the service user, so the
    # staging copy runs and its chown (stubbed to fail) is guarded.
    cat > "$tmp_dir/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$tmp_dir/bin/chown"

    INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        CLIENT_DATA="'"$client"'"
        MANGOSOSUSER="mangos"
        set +e
        phase_data_extraction
        rc=$?
        set -e
        printf "STAGE_RC=%s\n" "$rc"
    ' > "$tmp_dir/phase-a.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase-a.out" || true)"

    assert_equals "1" "$(sed -n 's/^STAGE_RC=//p' "$tmp_dir/phase-a.out")" \
        "a failing staging chown fails the extraction phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=extraction event=error msg="Failed to hand the staged client data to mangos"' || true)" \
        "the staging chown death path emits the extraction error marker" || failed=1
    assert_equals "ok" \
        "$(test -d "$root/client-data" && printf ok || printf missing)" \
        "client data staging began before the failure" || failed=1

    # Scenario B: client data is readable, so the phase proceeds past staging
    # and dies at the guarded installation-wide chown.
    SUDO_READ=allow INSTALL_LOG="$tmp_dir/install.log" \
    PATH="$tmp_dir/bin:$PATH" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        set -eu
        source "$REPO_ROOT/vmangos_setup.sh"
        INSTALLROOT="'"$root"'"
        CLIENT_DATA="'"$client"'"
        MANGOSOSUSER="mangos"
        set +e
        phase_data_extraction
        rc=$?
        set -e
        printf "MAIN_RC=%s\n" "$rc"
    ' > "$tmp_dir/phase-b.out" 2>/dev/null

    markers="$(grep '^@@VMANGOS v1 ' "$tmp_dir/phase-b.out" || true)"

    assert_equals "1" "$(sed -n 's/^MAIN_RC=//p' "$tmp_dir/phase-b.out")" \
        "a failing installation chown fails the extraction phase" || failed=1
    assert_equals "1" \
        "$(printf '%s\n' "$markers" | grep -c 'phase=extraction event=error msg="Failed to hand the installation directory to mangos"' || true)" \
        "the installation chown death path emits the extraction error marker" || failed=1

    rm -rf "$tmp_dir"
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
    run_test "Installer: Extraction phase" test_extraction_phase_invocations
    run_test "Installer: Extraction failure honesty" test_extraction_failure_honesty
    run_test "Installer: Download retry" test_download_retry_honesty
    run_test "Installer: World DB URLs" test_world_db_url_resolution
    run_test "Installer: Config local DB host" test_config_phase_local_db_host
    run_test "Installer: Marker protocol format" test_marker_protocol_format
    run_test "Installer: Marker helper contracts" test_marker_helper_contracts
    run_test "Installer: Database phase markers" test_database_phase_markers
    run_test "Installer: Prerequisites markers" test_prerequisites_markers
    run_test "Installer: Build markers" test_build_markers
    run_test "Installer: Build failure marker" test_build_failure_marker
    run_test "Installer: Extraction no client data marker" test_extraction_no_client_data_marker
    run_test "Installer: Source phase guards" test_source_phase_guards
    run_test "Installer: Build directory guards" test_build_phase_directory_guards
    run_test "Installer: db-import entry guard" test_db_import_entry_guard
    run_test "Installer: Config manager provision guards" test_config_phase_manager_provision_guards
    run_test "Installer: Services unit write guard" test_services_phase_unit_write_guard
    run_test "Installer: Extraction chown guards" test_extraction_phase_chown_guards

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
