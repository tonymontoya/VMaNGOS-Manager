#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091
#
# Test runner for VMANGOS Manager
#

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_DIR="$(cd "$TEST_DIR/.." && pwd)"
LIB_DIR="$MANAGER_DIR/lib"

# Test tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -t 1 ]]; then RED=''; GREEN=''; NC=''; fi

assert_equals() {
    local expected="$1" actual="$2" message="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        return 1
    fi
}

assert_true() {
    local condition="$1" message="${2:-}"
    if eval "$condition"; then
        echo -e "${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        return 1
    fi
}

assert_file_exists() {
    local file="$1" message="${2:-File exists: $file}"
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        return 1
    fi
}

run_test() {
    local name="$1" func="$2"
    local result=0
    echo ""
    echo "Running: $name"
    TESTS_RUN=$((TESTS_RUN + 1))
    if $func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        result=1
    fi
    return $result
}

create_test_config() {
    local config_file="$1"
    local install_root="${2:-/opt/mangos}"
    cat > "$config_file" << EOF
[database]
host = 127.0.0.1
port = 3306
user = mangos
password =
auth_db = auth
characters_db = characters
world_db = mangos
logs_db = logs

[server]
auth_service = auth
world_service = world
install_root = $install_root

[backup]
enabled = true
backup_dir = /tmp/vmangos-backups
retention_days = 7

[maintenance]
timezone = UTC
honor_command =
announce_command =
restart_warnings = 30,15,5,1
EOF
    chmod 600 "$config_file"
}

setup_status_mock_bin() {
    local mock_dir="$1"

    cat > "$mock_dir/systemctl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
    is-active)
        quiet=0
        if [[ "${2:-}" == "--quiet" ]]; then
            quiet=1
            service="${3:-}"
        else
            service="${2:-}"
        fi

        case "$service" in
            auth|world)
                [[ "$quiet" -eq 0 ]] && echo "active"
                exit 0
                ;;
            *)
                [[ "$quiet" -eq 0 ]] && echo "inactive"
                exit 3
                ;;
        esac
        ;;
    show)
        service="${4:-}"
        case "$service" in
            auth) echo "MainPID=111" ;;
            world) echo "MainPID=222" ;;
            *) echo "MainPID=0" ;;
        esac
        ;;
    start|stop)
        printf '%s %s\n' "$cmd" "${2:-}" >> "${STATUS_TEST_SYSTEMCTL_LOG:-/dev/null}"
        ;;
    kill)
        printf 'kill %s %s\n' "${4:-}" "${2:-}" >> "${STATUS_TEST_SYSTEMCTL_LOG:-/dev/null}"
        ;;
    *)
        ;;
esac
EOF

    cat > "$mock_dir/ps" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

pid="${2:-0}"
format="${4:-}"

case "$format" in
    etimes=)
        case "$pid" in
            111) echo "3600" ;;
            222) echo "7200" ;;
            *) echo "0" ;;
        esac
        ;;
    rss=)
        case "$pid" in
            111) echo "20480" ;;
            222) echo "524288" ;;
            *) echo "0" ;;
        esac
        ;;
    %cpu=)
        case "$pid" in
            111) echo "0.5" ;;
            222) echo "12.5" ;;
            *) echo "0.0" ;;
        esac
        ;;
    *)
        echo "0"
        ;;
esac
EOF

    cat > "$mock_dir/mysql" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

query=""
prev=""

for arg in "$@"; do
    if [[ "$prev" == "-e" ]]; then
        query="$arg"
        break
    fi
    prev="$arg"
done

if [[ "$query" == "SELECT 1" ]]; then
    echo "1"
    exit 0
fi

case "$query" in
    *"auth.account WHERE online = 1"*)
        if [[ "${STATUS_TEST_PLAYER_MODE:-auth}" == "fallback" ]]; then
            echo "query failed" >&2
            exit 1
        fi
        echo "4"
        ;;
    *"characters.characters WHERE online = 1"*)
        echo "7"
        ;;
    *)
        echo "0"
        ;;
esac
EOF

    cat > "$mock_dir/df" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'DFEOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/mock 2048000 512000 1536000 25% /opt/mangos
DFEOF
EOF

    cat > "$mock_dir/sleep" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF

    cat > "$mock_dir/journalctl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"

if [[ "$args" == *"--output short-iso"* ]]; then
    if [[ -n "${STATUS_TEST_EVENTS_FILE:-}" && -f "${STATUS_TEST_EVENTS_FILE:-}" ]]; then
        cat "${STATUS_TEST_EVENTS_FILE}"
    elif [[ "${STATUS_TEST_EVENTS_MODE:-default}" == "default" ]]; then
        cat <<'JOURNALEOF'
2026-04-13T10:15:00+00:00 host world[222]: World lag spike detected
2026-04-13T10:16:00+00:00 host auth[111]: Login queue stabilized
JOURNALEOF
    fi
    exit 0
fi

service=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-u" ]]; then
        service="$arg"
        break
    fi
    prev="$arg"
done

count=0
case "$service" in
    auth) count="${STATUS_TEST_AUTH_RESTARTS:-0}" ;;
    world) count="${STATUS_TEST_WORLD_RESTARTS:-0}" ;;
esac

i=0
while [[ "$i" -lt "$count" ]]; do
    echo "Scheduled restart job"
    i=$((i + 1))
done
EOF

    cat > "$mock_dir/top" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${STATUS_TEST_TOP_FILE:-}" && -f "${STATUS_TEST_TOP_FILE:-}" ]]; then
    cat "${STATUS_TEST_TOP_FILE}"
    exit 0
fi
cat <<'TOPEOF'
top - 10:10:10 up 1 day,  1:23,  1 user,  load average: 0.50, 0.40, 0.30
Tasks: 100 total,   1 running, 99 sleeping,   0 stopped,   0 zombie
%Cpu(s): 12.5 us,  5.0 sy,  0.0 ni, 82.5 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
TOPEOF
EOF

    cat > "$mock_dir/getconf" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "_NPROCESSORS_ONLN" ]]; then
    echo "${STATUS_TEST_CPU_CORES:-8}"
fi
EOF

    cat > "$mock_dir/iostat" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${STATUS_TEST_IOSTAT_MODE:-present}" == "absent" ]]; then
    exit 127
fi

if [[ -n "${STATUS_TEST_IOSTAT_FILE:-}" && -f "${STATUS_TEST_IOSTAT_FILE:-}" ]]; then
    cat "${STATUS_TEST_IOSTAT_FILE}"
    exit 0
fi

cat <<'IOSTATEOF'
Linux 6.8.0 (mockhost)

Device            r/s     rkB/s   rrqm/s  %rrqm  r_await  rareq-sz     w/s     wkB/s   wrqm/s  %wrqm  w_await  wareq-sz     aqu-sz  %util
mock              1.50    24.00     0.00   0.00     0.40     16.00    2.50    40.00     0.00   0.00     0.90     16.00       0.01   35.50

Device            r/s     rkB/s   rrqm/s  %rrqm  r_await  rareq-sz     w/s     wkB/s   wrqm/s  %wrqm  w_await  wareq-sz     aqu-sz  %util
mock              3.25    52.00     0.00   0.00     0.55     16.00    4.75    76.00     0.00   0.00     1.10     16.00       0.02   61.25
IOSTATEOF
EOF

    chmod +x "$mock_dir/systemctl" "$mock_dir/ps" "$mock_dir/mysql" "$mock_dir/df" "$mock_dir/sleep" "$mock_dir/journalctl" "$mock_dir/top" "$mock_dir/getconf" "$mock_dir/iostat"
}

setup_status_proc_root() {
    local proc_root="$1"
    mkdir -p "$proc_root"

    cat > "$proc_root/meminfo" << 'EOF'
MemTotal:       8192000 kB
MemFree:        1024000 kB
MemAvailable:   4096000 kB
Buffers:         256000 kB
Cached:         1024000 kB
EOF

    cat > "$proc_root/loadavg" << 'EOF'
0.50 0.40 0.30 1/100 12345
EOF
}

setup_logs_mock_bin() {
    local mock_dir="$1"

    cat > "$mock_dir/logrotate" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${LOGS_TEST_LOGROTATE_LOG:-/dev/null}"
exit "${LOGS_TEST_LOGROTATE_EXIT:-0}"
EOF

    chmod +x "$mock_dir/logrotate"
}

setup_dashboard_mock_python() {
    local mock_python="$1"

    cat > "$mock_python" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${DASHBOARD_TEST_LOG:-/dev/null}"

if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    venv_dir="${3:-}"
    mkdir -p "$venv_dir/bin"
    cp "$0" "$venv_dir/bin/python3"
    chmod +x "$venv_dir/bin/python3"
    exit 0
fi

if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then
    exit 0
fi

if [[ "${1:-}" == "-c" ]]; then
    exit 0
fi

printf '%s\n' "$*" > "${DASHBOARD_TEST_RUN_ARGS:-/dev/null}"
EOF

    chmod +x "$mock_python"
}

setup_config_detect_mock_bin() {
    local mock_dir="$1"

    cat > "$mock_dir/systemctl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
    list-unit-files)
        if [[ -f "${VMANGOS_DETECT_SYSTEMCTL_UNITS_FILE:-}" ]]; then
            cat "$VMANGOS_DETECT_SYSTEMCTL_UNITS_FILE"
        fi
        ;;
    show)
        unit="${@: -1}"
        if [[ -n "${VMANGOS_DETECT_SYSTEMCTL_SHOW_DIR:-}" && -f "${VMANGOS_DETECT_SYSTEMCTL_SHOW_DIR}/${unit}" ]]; then
            cat "${VMANGOS_DETECT_SYSTEMCTL_SHOW_DIR}/${unit}"
        fi
        ;;
    *)
        ;;
esac
EOF

    chmod +x "$mock_dir/systemctl"
}

# ============================================================================
# ORIGINAL TESTS
# ============================================================================

test_common_json() {
    # shellcheck source=../lib/common.sh
    source "$LIB_DIR/common.sh"
    SKIP_ROOT_INIT=1
    local all_passed=0
    assert_equals 'hello' "$(json_escape 'hello')" "json_escape: plain text" || all_passed=1
    assert_equals 'hello\"world' "$(json_escape 'hello"world')" "json_escape: quotes" || all_passed=1
    assert_equals 'hello\\world' "$(json_escape 'hello\world')" "json_escape: backslash" || all_passed=1
    return $all_passed
}

test_config_loading() {
    # shellcheck source=../lib/config.sh
    source "$LIB_DIR/config.sh"
    SKIP_ROOT_INIT=1
    local temp_config; temp_config=$(mktemp)
    chmod 600 "$temp_config"
    cat > "$temp_config" << 'EOF'
[database]
host = testhost
port = 3307
user = testuser

[server]
install_root = /test/path
EOF
    local all_passed=0
    assert_equals "testhost" "$(ini_read "$temp_config" "database" "host")" "ini_read: host" || all_passed=1
    assert_equals "3307" "$(ini_read "$temp_config" "database" "port")" "ini_read: port" || all_passed=1
    rm -f "$temp_config"
    return $all_passed
}

test_config_resolve_manager_root() {
    # shellcheck source=../lib/config.sh
    source "$LIB_DIR/config.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir config_file manager_root
    temp_dir=$(mktemp -d)
    mkdir -p "$temp_dir/custom-manager/config"
    config_file="$temp_dir/custom-manager/config/manager.conf"
    printf '%s\n' '[database]' > "$config_file"
    chmod 600 "$config_file"

    manager_root=$(config_resolve_manager_root "$config_file")
    assert_equals "$temp_dir/custom-manager" "$manager_root" "config_resolve_manager_root derives manager root from config path" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_config_create() {
    # shellcheck source=../lib/config.sh
    source "$LIB_DIR/config.sh"
    SKIP_ROOT_INIT=1
    local temp_dir; temp_dir=$(mktemp -d)
    local config_file="$temp_dir/test.conf"
    config_create "$config_file" 2>/dev/null
    local all_passed=0
    assert_file_exists "$config_file" "config_create: creates file" || all_passed=1
    local perms; perms=$(get_file_permissions "$config_file")
    assert_equals "600" "$perms" "config_create: permissions are 600" || all_passed=1
    rm -rf "$temp_dir"
    return $all_passed
}

test_config_detect_installer_layout() {
    local all_passed=0
    local temp_dir mock_dir show_dir units_file install_root output
    temp_dir=$(mktemp -d)
    mock_dir="$temp_dir/mockbin"
    show_dir="$temp_dir/systemctl-show"
    units_file="$temp_dir/units.txt"
    install_root="$temp_dir/opt/mangos"

    mkdir -p "$mock_dir" "$show_dir" "$install_root/run/etc"
    setup_config_detect_mock_bin "$mock_dir"

    cat > "$install_root/run/etc/realmd.conf" << EOF
LoginDatabaseInfo = "10.0.1.6;3306;mangos;secret;auth"
EOF

    cat > "$install_root/run/etc/mangosd.conf" << EOF
LoginDatabase.Info = "10.0.1.6;3306;mangos;secret;auth"
WorldDatabase.Info = "10.0.1.6;3306;mangos;secret;world"
CharacterDatabase.Info = "10.0.1.6;3306;mangos;secret;characters"
LogsDatabase.Info = "10.0.1.6;3306;mangos;secret;logs"
EOF

    cat > "$units_file" << 'EOF'
auth.service enabled
world.service enabled
EOF

    cat > "$show_dir/auth.service" << EOF
Id=auth.service
ExecStart={ path=$install_root/run/bin/realmd ; argv[]=$install_root/run/bin/realmd ; }
EOF

    cat > "$show_dir/world.service" << EOF
Id=world.service
ExecStart={ path=$install_root/run/bin/mangosd ; argv[]=$install_root/run/bin/mangosd ; }
EOF

    output=$(PATH="$mock_dir:$PATH" \
        VMANGOS_DETECT_SEARCH_ROOTS="$temp_dir/opt" \
        VMANGOS_DETECT_SYSTEMCTL_UNITS_FILE="$units_file" \
        VMANGOS_DETECT_SYSTEMCTL_SHOW_DIR="$show_dir" \
        bash "$MANAGER_DIR/bin/vmangos-manager" config detect 2>/dev/null)

    assert_true "[[ \$output == *'Candidates found: 1'* ]]" "config detect finds installer-layout candidate" || all_passed=1
    assert_true "[[ \$output == *\"Selected install root: $install_root\"* ]]" "config detect selects installer-layout root" || all_passed=1
    assert_true "[[ \$output == *'Services: auth=auth, world=world'* ]]" "config detect keeps default installer service names" || all_passed=1
    assert_true "[[ \$output == *'host = 10.0.1.6'* && \$output == *'world_db = world'* ]]" "config detect emits parsed DB settings in proposed config" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_config_detect_custom_path_json() {
    local all_passed=0
    local temp_dir mock_dir show_dir units_file install_root output compact_output
    temp_dir=$(mktemp -d)
    mock_dir="$temp_dir/mockbin"
    show_dir="$temp_dir/systemctl-show"
    units_file="$temp_dir/units.txt"
    install_root="$temp_dir/custom/vmangos-live"

    mkdir -p "$mock_dir" "$show_dir" "$install_root/run/etc"
    setup_config_detect_mock_bin "$mock_dir"

    cat > "$install_root/run/etc/realmd.conf" << EOF
LoginDatabaseInfo = "192.168.50.10;3307;vmuser;secret;auth_custom"
EOF

    cat > "$install_root/run/etc/mangosd.conf" << EOF
LoginDatabase.Info = "192.168.50.10;3307;vmuser;secret;auth_custom"
WorldDatabase.Info = "192.168.50.10;3307;vmuser;secret;world_custom"
CharacterDatabase.Info = "192.168.50.10;3307;vmuser;secret;chars_custom"
LogsDatabase.Info = "192.168.50.10;3307;vmuser;secret;logs_custom"
EOF

    cat > "$units_file" << 'EOF'
vmangos-authd.service enabled
vmangos-worldd.service enabled
EOF

    cat > "$show_dir/vmangos-authd.service" << EOF
Id=vmangos-authd.service
ExecStart={ path=$install_root/run/bin/realmd ; argv[]=$install_root/run/bin/realmd ; }
EOF

    cat > "$show_dir/vmangos-worldd.service" << EOF
Id=vmangos-worldd.service
ExecStart={ path=$install_root/run/bin/mangosd ; argv[]=$install_root/run/bin/mangosd ; }
EOF

    output=$(PATH="$mock_dir:$PATH" \
        VMANGOS_DETECT_SEARCH_ROOTS="$temp_dir/custom" \
        VMANGOS_DETECT_SYSTEMCTL_UNITS_FILE="$units_file" \
        VMANGOS_DETECT_SYSTEMCTL_SHOW_DIR="$show_dir" \
        bash "$MANAGER_DIR/bin/vmangos-manager" config detect --format json 2>/dev/null)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *\"\\\"selected_install_root\\\":\\\"$install_root\\\"\"* ]]" "config detect json selects custom install root" || all_passed=1
    assert_true "[[ \$compact_output == *'\"auth\":\"vmangos-authd\"'* && \$compact_output == *'\"world\":\"vmangos-worldd\"'* ]]" "config detect json keeps custom systemd service names" || all_passed=1
    assert_true "[[ \$compact_output == *'\"auth_db\":\"auth_custom\"'* && \$compact_output == *'\"world_db\":\"world_custom\"'* ]]" "config detect json keeps custom DB names" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_config_detect_reports_multiple_candidates() {
    local all_passed=0
    local temp_dir mock_dir show_dir units_file root_one root_two output compact_output
    temp_dir=$(mktemp -d)
    mock_dir="$temp_dir/mockbin"
    show_dir="$temp_dir/systemctl-show"
    units_file="$temp_dir/units.txt"
    root_one="$temp_dir/alpha"
    root_two="$temp_dir/bravo"

    mkdir -p "$mock_dir" "$show_dir" "$root_one/run/etc" "$root_two/run/etc"
    setup_config_detect_mock_bin "$mock_dir"
    : > "$units_file"

    cat > "$root_one/run/etc/realmd.conf" << 'EOF'
LoginDatabaseInfo = "127.0.0.1;3306;mangos;secret;auth"
EOF
    cat > "$root_one/run/etc/mangosd.conf" << 'EOF'
WorldDatabase.Info = "127.0.0.1;3306;mangos;secret;world"
CharacterDatabase.Info = "127.0.0.1;3306;mangos;secret;characters"
LogsDatabase.Info = "127.0.0.1;3306;mangos;secret;logs"
EOF

    cat > "$root_two/run/etc/realmd.conf" << 'EOF'
LoginDatabaseInfo = "127.0.0.1;3306;mangos;secret;auth"
EOF
    cat > "$root_two/run/etc/mangosd.conf" << 'EOF'
WorldDatabase.Info = "127.0.0.1;3306;mangos;secret;world"
CharacterDatabase.Info = "127.0.0.1;3306;mangos;secret;characters"
LogsDatabase.Info = "127.0.0.1;3306;mangos;secret;logs"
EOF

    output=$(PATH="$mock_dir:$PATH" \
        VMANGOS_DETECT_SEARCH_ROOTS="$temp_dir" \
        VMANGOS_DETECT_SYSTEMCTL_UNITS_FILE="$units_file" \
        VMANGOS_DETECT_SYSTEMCTL_SHOW_DIR="$show_dir" \
        bash "$MANAGER_DIR/bin/vmangos-manager" config detect --format json 2>/dev/null)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'\"candidate_count\":2'* ]]" "config detect json reports multiple candidates" || all_passed=1
    assert_true "[[ \$compact_output == *'\"multiple_candidates\":true'* ]]" "config detect json marks multiple candidate discovery" || all_passed=1
    assert_true "[[ \$compact_output == *'\"ambiguous\":true'* && \$compact_output == *'\"selected_install_root\":null'* ]]" "config detect json leaves selection empty on tied candidates" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_cli_parsing() {
    local all_passed=0
    assert_file_exists "$MANAGER_DIR/bin/vmangos-manager" "CLI binary exists" || all_passed=1
    local output
    # shellcheck disable=SC2034
    output=$(bash "$MANAGER_DIR/bin/vmangos-manager" --help 2>&1) || true
    assert_true "[[ \$output == *'VMANGOS Manager'* ]]" "CLI --help shows app name" || all_passed=1
    assert_true "[[ \$output == *'server'* ]]" "CLI --help lists server command" || all_passed=1
    assert_true "[[ \$output == *'logs [status|rotate|test-config]'* ]]" "CLI --help lists logs command" || all_passed=1
    assert_true "[[ \$output == *'account'* ]]" "CLI --help lists account command" || all_passed=1
    assert_true "[[ \$output == *'dashboard [--refresh SECONDS] [--theme dark|light] [--bootstrap]'* ]]" "CLI --help lists dashboard command" || all_passed=1
    assert_true "[[ \$output == *'update'* ]]" "CLI --help lists update command" || all_passed=1
    assert_true "[[ \$output == *'schedule [honor|restart|list|cancel|simulate]'* ]]" "CLI --help lists schedule command" || all_passed=1
    assert_true "[[ \$output == *'update [check|inspect|plan|apply]'* ]]" "CLI --help lists update inspect command" || all_passed=1
    assert_true "[[ \$output == *'config [create|validate|show|detect]'* ]]" "CLI --help lists config detect command" || all_passed=1
    return $all_passed
}

test_account_validation() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0

    if validate_username "Player01"; then
        echo -e "${GREEN}✓${NC} validate_username accepts alphanumeric usernames"
    else
        echo -e "${RED}✗${NC} validate_username rejected valid username"
        all_passed=1
    fi

    if ! validate_username "bad-user"; then
        echo -e "${GREEN}✓${NC} validate_username rejects non-alphanumeric usernames"
    else
        echo -e "${RED}✗${NC} validate_username accepted invalid username"
        all_passed=1
    fi

    if validate_gm_level "3" && ! validate_gm_level "4"; then
        echo -e "${GREEN}✓${NC} validate_gm_level enforces 0-3"
    else
        echo -e "${RED}✗${NC} validate_gm_level failed expected bounds"
        all_passed=1
    fi

    if validate_duration "7d" && ! validate_duration "0h"; then
        echo -e "${GREEN}✓${NC} validate_duration enforces positive unit-suffixed values"
    else
        echo -e "${RED}✗${NC} validate_duration failed expected bounds"
        all_passed=1
    fi

    if validate_ban_reason "Bad Actor" && ! validate_ban_reason "Bad-Actor"; then
        echo -e "${GREEN}✓${NC} validate_ban_reason enforces alnum plus spaces"
    else
        echo -e "${RED}✗${NC} validate_ban_reason failed expected bounds"
        all_passed=1
    fi

    return $all_passed
}

test_account_hash_known_vector() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local result expected

    expected="D04E6342FE6CB5FAE54C6182F885778D0AEFE4BFCDDC6B5C7DF7DC25FF6E3C2D|46FD48476D925C4422DD1761C299C79FD6C92B5243E4F3C6C62576C0DABD8260"
    result=$(hash_password "VMANGOS" "4EVER" "D04E6342FE6CB5FAE54C6182F885778D0AEFE4BFCDDC6B5C7DF7DC25FF6E3C2D")

    assert_equals "$expected" "$result" "hash_password matches VMANGOS SRP verifier vector" || all_passed=1
    return $all_passed
}

test_account_password_file_checks() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir password_file result
    temp_dir=$(mktemp -d)
    password_file="$temp_dir/password.txt"

    printf '%s\n' 'Secret7' > "$password_file"
    chmod 600 "$password_file"
    result=$(get_password_from_file "$password_file")
    assert_equals "Secret7" "$result" "get_password_from_file reads valid 600 file" || all_passed=1

    chmod 644 "$password_file"
    if ! get_password_from_file "$password_file" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} get_password_from_file rejects mode 644"
    else
        echo -e "${RED}✗${NC} get_password_from_file accepted mode 644"
        all_passed=1
    fi

    printf '%s\n' 'short' > "$password_file"
    chmod 600 "$password_file"
    if ! get_password_from_file "$password_file" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} get_password_from_file rejects short passwords"
    else
        echo -e "${RED}✗${NC} get_password_from_file accepted short password"
        all_passed=1
    fi

    rm -rf "$temp_dir"
    return $all_passed
}

test_account_password_file_wrong_owner_rejected() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir password_file
    temp_dir=$(mktemp -d)
    password_file="$temp_dir/password.txt"
    printf '%s\n' 'Secret7' > "$password_file"

    account_get_file_owner_uid() { echo "12345"; }
    account_get_current_uid() { echo "1000"; }
    get_file_permissions() { echo "600"; }

    if ! get_password_from_file "$password_file" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} get_password_from_file rejects wrong ownership"
    else
        echo -e "${RED}✗${NC} get_password_from_file accepted wrong ownership"
        all_passed=1
    fi

    rm -rf "$temp_dir"
    return $all_passed
}

test_account_password_file_accepts_sudo_owner() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir password_file result
    temp_dir=$(mktemp -d)
    password_file="$temp_dir/password.txt"
    printf '%s\n' 'Secret7' > "$password_file"

    account_get_file_owner_uid() { echo "1000"; }
    account_get_current_uid() { echo "0"; }
    account_get_sudo_uid() { echo "1000"; }
    get_file_permissions() { echo "600"; }

    result=$(get_password_from_file "$password_file")
    assert_equals "Secret7" "$result" "get_password_from_file accepts invoking sudo user ownership" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_account_password_env_clears_variable() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_file result
    temp_file=$(mktemp)

    export VMANGOS_PASSWORD="Secret7"
    get_password_from_env > "$temp_file"
    result=$(cat "$temp_file")
    assert_equals "Secret7" "$result" "get_password_from_env reads VMANGOS_PASSWORD" || all_passed=1
    assert_true "[[ -z \${VMANGOS_PASSWORD+x} ]]" "get_password_from_env unsets VMANGOS_PASSWORD after read" || all_passed=1

    rm -f "$temp_file"
    return $all_passed
}

test_account_create_blocks_injection() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local mysql_called=0

    account_mysql_query() { mysql_called=1; echo "1"; }
    account_mysql_exec() { mysql_called=1; return 0; }

    if ! account_create "bad'user" "env" "" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} account_create rejects SQL-injection username before DB access"
    else
        echo -e "${RED}✗${NC} account_create accepted invalid username"
        all_passed=1
    fi
    assert_equals "0" "$mysql_called" "account_create does not hit DB for invalid username" || all_passed=1

    return $all_passed
}

test_account_operations_generate_expected_queries() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local exec_query="" resolve_calls=0 output_file output

    CONFIG_FILE="/tmp/test-manager.conf"
    ACCOUNT_CONFIG_LOADED=""
    ACCOUNT_AUTH_DB=""
    output_file=$(mktemp)

    config_load() {
        CONFIG_DATABASE_HOST="127.0.0.1"
        CONFIG_DATABASE_PORT="3306"
        CONFIG_DATABASE_USER="mangos"
        CONFIG_DATABASE_PASSWORD="secret"
        CONFIG_DATABASE_AUTH_DB="auth"
        return 0
    }

    account_resolve_account_id() {
        if [[ "$resolve_calls" -eq 0 ]]; then
            resolve_calls=1
            printf '\n'
        else
            printf '42\n'
        fi
    }
    account_acquire_password() { printf 'Secret7\n'; }
    hash_password() { printf 'SALT64|VERIFIER64\n'; }
    account_mysql_exec() { exec_query="$2"; return 0; }

    account_create "TestUser" "env" "" > "$output_file" 2>&1
    output=$(cat "$output_file")
    assert_equals "auth" "$ACCOUNT_AUTH_DB" "account_create loads auth DB config in parent shell" || all_passed=1
    assert_true "[[ \$exec_query == *'INSERT INTO'* && \$exec_query == *'account'* ]]" "account_create writes auth.account insert" || all_passed=1
    assert_true "[[ \$exec_query == *'LAST_INSERT_ID()'* && \$exec_query == *'INSERT IGNORE INTO'* && \$exec_query == *'realmcharacters'* ]]" "account_create syncs realmcharacters from inserted account id" || all_passed=1
    assert_true "[[ \$output == *'AUDIT account.create'* ]]" "account_create emits audit log" || all_passed=1

    account_resolve_account_id() { printf '42\n'; }
    account_mysql_exec() { exec_query="$2"; return 0; }
    account_setgm "TestUser" "2" > "$output_file" 2>&1
    output=$(cat "$output_file")
    assert_true "[[ \$exec_query == *'account_access'* && \$exec_query == *'VALUES (42, 2, -1)'* ]]" "account_setgm writes global account_access row" || all_passed=1
    assert_true "[[ \$output == *'AUDIT account.setgm'* ]]" "account_setgm emits audit log" || all_passed=1

    account_get_default_realm_id() { printf '7\n'; }
    account_mysql_exec() { exec_query="$2"; return 0; }
    account_ban "TestUser" "1h" "Bad Actor" > "$output_file" 2>&1
    output=$(cat "$output_file")
    assert_true "[[ \$exec_query == *'account_banned'* && \$exec_query == *'UNIX_TIMESTAMP() + 3600'* && \$exec_query == *', 7);'* ]]" "account_ban inserts timed ban with resolved realm" || all_passed=1
    assert_true "[[ \$output == *'AUDIT account.ban'* ]]" "account_ban emits audit log" || all_passed=1

    account_mysql_exec() { exec_query="$2"; return 0; }
    account_unban "TestUser" > "$output_file" 2>&1
    output=$(cat "$output_file")
    assert_true "[[ \$exec_query == *'active'* && \$exec_query == *'= 0'* ]]" "account_unban clears active bans" || all_passed=1
    assert_true "[[ \$output == *'AUDIT account.unban'* ]]" "account_unban emits audit log" || all_passed=1

    account_mysql_exec() { exec_query="$2"; return 0; }
    account_password "TestUser" "env" "/unused" > "$output_file" 2>&1 <<<''
    output=$(cat "$output_file")
    assert_true "[[ \$exec_query == *\"VERIFIER64\"* && \$exec_query == *\"SALT64\"* ]]" "account_password writes verifier update query" || all_passed=1
    assert_true "[[ \$output == *'AUDIT account.password'* ]]" "account_password emits audit log" || all_passed=1
    rm -f "$output_file"

    return $all_passed
}

test_account_password_env_not_forwarded_to_python() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local env_seen_file output_file output

    ACCOUNT_CONFIG_LOADED=1
    ACCOUNT_AUTH_DB="auth"
    env_seen_file=$(mktemp)
    output_file=$(mktemp)

    account_resolve_account_id() { printf '42\n'; }
    account_mysql_exec() { return 0; }
    export VMANGOS_PASSWORD="Secret7"

    python3() {
        printf '%s' "${VMANGOS_PASSWORD-UNSET}" > "$env_seen_file"
        cat >/dev/null
        printf 'SALT64|VERIFIER64\n'
    }

    account_password "TestUser" "env" "" > "$output_file" 2>&1
    output=$(cat "$output_file")
    assert_true "[[ $(cat "$env_seen_file") == 'UNSET' ]]" "account_password does not pass VMANGOS_PASSWORD to hashing subprocess env" || all_passed=1
    assert_true "[[ \$output == *'AUDIT account.password'* ]]" "account_password still completes via env mode" || all_passed=1
    unset VMANGOS_PASSWORD
    unset -f python3
    rm -f "$env_seen_file" "$output_file"

    return $all_passed
}

test_account_list_json_output() {
    # shellcheck source=../lib/account.sh
    source "$LIB_DIR/account.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output compact_output

    ACCOUNT_CONFIG_LOADED=1
    ACCOUNT_AUTH_DB="auth"
    OUTPUT_FORMAT="json"
    account_mysql_query() {
        printf '42\tTESTUSER\t2\t1\t0\n'
        printf '43\tOTHER\t0\t0\t1\n'
    }

    output=$(account_list false)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"accounts\":[{\"id\":42,\"username\":\"TESTUSER\",\"gm_level\":2,\"online\":true,\"banned\":false}'* ]]" "account_list outputs JSON account objects" || all_passed=1
    assert_true "[[ \$compact_output == *'\"id\":43,\"username\":\"OTHER\",\"gm_level\":0,\"online\":false,\"banned\":true'* ]]" "account_list JSON includes banned status" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_cli_account_rejects_positional_password() {
    local all_passed=0
    local output

    output=$(bash "$MANAGER_DIR/bin/vmangos-manager" account create testuser secret 2>&1 || true)
    assert_true "[[ \$output == *'accepts only a username as a positional argument'* ]]" "CLI create rejects positional password" || all_passed=1

    output=$(bash "$MANAGER_DIR/bin/vmangos-manager" account password testuser secret 2>&1 || true)
    assert_true "[[ \$output == *'accepts only a username as a positional argument'* ]]" "CLI password rejects positional password" || all_passed=1

    return $all_passed
}

test_update_check_text_output() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output

    OUTPUT_FORMAT="text"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/srv/mangos"
        return 0
    }
    update_find_repo_root() { printf '/tmp/vmangos-manager\n'; }
    update_git() {
        local args="$*"
        case "$args" in
            *"rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/main\n' ;;
            *"rev-parse --abbrev-ref HEAD"*) printf 'main\n' ;;
            *"fetch --quiet origin"*) return 0 ;;
            *"rev-parse origin/main^{commit}"*) printf '2222222222222222222222222222222222222222\n' ;;
            *"rev-parse HEAD"*) printf '1111111111111111111111111111111111111111\n' ;;
            *"rev-parse origin/main"*) printf '2222222222222222222222222222222222222222\n' ;;
            *"rev-list --count HEAD..origin/main"*) printf '2\n' ;;
            *"status --porcelain"*) return 0 ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_check)
    assert_true "[[ \$output == *'VMANGOS Manager Update Check'* ]]" "update_check text prints header" || all_passed=1
    assert_true "[[ \$output == *'Commits behind: 2'* ]]" "update_check text prints behind count" || all_passed=1
    assert_true "[[ \$output == *'Status: update available'* ]]" "update_check text prints update state" || all_passed=1
    assert_true "[[ \$output == *'git checkout main'* ]]" "update_check text includes manual branch step" || all_passed=1
    assert_true "[[ \$output == *'sudo make install PREFIX=/srv/mangos/manager'* ]]" "update_check text includes non-atomic install instruction" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_check_json_output() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output compact_output

    OUTPUT_FORMAT="json"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        return 0
    }
    update_find_repo_root() { printf '/repo/root\n'; }
    update_git() {
        local args="$*"
        case "$args" in
            *"rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/main\n' ;;
            *"rev-parse --abbrev-ref HEAD"*) printf 'main\n' ;;
            *"fetch --quiet origin"*) return 0 ;;
            *"rev-parse origin/main^{commit}"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"rev-parse HEAD"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
            *"rev-parse origin/main"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"rev-list --count HEAD..origin/main"*) printf '3\n' ;;
            *"status --porcelain"*) printf ' M README.md\n' ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_check)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"success\":true'* ]]" "update_check json reports success" || all_passed=1
    assert_true "[[ \$compact_output == *'\"commits_behind\":3'* ]]" "update_check json reports behind count" || all_passed=1
    assert_true "[[ \$compact_output == *'\"update_available\":true'* ]]" "update_check json reports update availability" || all_passed=1
    assert_true "[[ \$compact_output == *'\"worktree_dirty\":true'* ]]" "update_check json reports dirty worktree" || all_passed=1
    assert_true "[[ \$compact_output == *'\"install_target\":\"/opt/mangos/manager\"'* ]]" "update_check json includes install target" || all_passed=1
    assert_true "[[ \$compact_output == *'\"instructions\":[\"cd/repo/root\"'* ]]" "update_check json includes manual instructions" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_check_prefers_configured_source_repo() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output

    OUTPUT_FORMAT="text"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        return 0
    }
    config_resolve_manager_root() { printf '/opt/mangos/manager\n'; }
    update_find_repo_root() {
        echo "manager fallback should not be used" >&2
        return 1
    }
    update_git() {
        local args="$*"
        case "$args" in
            *"/opt/mangos/source rev-parse --show-toplevel"*) printf '/opt/mangos/source\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"/opt/mangos/source fetch --quiet origin"*) return 0 ;;
            *"/opt/mangos/source rev-parse origin/development^{commit}"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-parse HEAD"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
            *"/opt/mangos/source rev-parse origin/development"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-list --count HEAD..origin/development"*) printf '1\n' ;;
            *"/opt/mangos/source rev-list --count origin/development..HEAD"*) printf '0\n' ;;
            *"/opt/mangos/source status --porcelain"*) return 0 ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_check)
    assert_true "[[ \$output == *'VMANGOS Core Update Check'* ]]" "update_check uses configured source repo when available" || all_passed=1
    assert_true "[[ \$output == *'Source repo: /opt/mangos/source'* ]]" "update_check source mode reports source repo" || all_passed=1
    assert_true "[[ \$output == *'vmangos-manager update plan'* ]]" "update_check source mode points to update plan" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_check_requires_git_repo() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output

    OUTPUT_FORMAT="json"
    update_find_repo_root() { return 1; }

    output=$(update_check 2>/dev/null || true)
    assert_true "[[ \$output == *'\"code\":\"NOT_A_GIT_REPO\"'* ]]" "update_check errors cleanly when no git repo is available" || all_passed=1
    assert_true "[[ \$output == *'VMANGOS_MANAGER_REPO'* ]]" "update_check error suggests explicit repo path" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_check_reports_unsafe_source_repo() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output compact_output

    OUTPUT_FORMAT="json"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        return 0
    }
    update_git() {
        local args="$*"
        case "$args" in
            *"/opt/mangos/source rev-parse --show-toplevel"*)
                printf "fatal: detected dubious ownership in repository at '/opt/mangos/source'\n" >&2
                return 128
                ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_check 2>/dev/null || true)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"code\":\"SOURCE_REPO_UNSAFE\"'* ]]" "update_check reports Git safe.directory protection explicitly" || all_passed=1
    assert_true "[[ \$compact_output == *'safe.directory'* && \$compact_output == *'/opt/mangos/source'* ]]" "update_check suggests safe.directory remediation" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_plan_text_output() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output

    OUTPUT_FORMAT="text"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/srv/mangos"
        return 0
    }
    config_resolve_manager_root() { printf '/srv/mangos/manager\n'; }
    update_git() {
        local args="$*"
        case "$args" in
            *"/srv/mangos/source rev-parse --show-toplevel"*) printf '/srv/mangos/source\n' ;;
            *"/srv/mangos/source rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"/srv/mangos/source rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"/srv/mangos/source fetch --quiet origin"*) return 0 ;;
            *"/srv/mangos/source rev-parse origin/development^{commit}"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/srv/mangos/source rev-parse HEAD"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
            *"/srv/mangos/source rev-parse origin/development"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/srv/mangos/source rev-list --count HEAD..origin/development"*) printf '4\n' ;;
            *"/srv/mangos/source rev-list --count origin/development..HEAD"*) printf '0\n' ;;
            *"/srv/mangos/source status --porcelain"*) return 0 ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }
    update_nproc() { printf '6\n'; }

    output=$(update_plan)
    assert_true "[[ \$output == *'VMANGOS Core Update Plan'* ]]" "update_plan text prints header" || all_passed=1
    assert_true "[[ \$output == *'Source repo: /srv/mangos/source'* ]]" "update_plan text shows source repo" || all_passed=1
    assert_true "[[ \$output == *'Tracking: origin/development'* ]]" "update_plan text shows tracking ref" || all_passed=1
    assert_true "[[ \$output == *'Commits behind: 4'* ]]" "update_plan text reports behind count" || all_passed=1
    assert_true "[[ \$output == *'vmangos-manager backup now --verify'* ]]" "update_plan text includes backup-first step" || all_passed=1
    assert_true "[[ \$output == *'cmake -S /srv/mangos/source -B /srv/mangos/build'* ]]" "update_plan text includes cmake step" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_plan_json_output() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output compact_output

    OUTPUT_FORMAT="json"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        return 0
    }
    config_resolve_manager_root() { printf '/opt/mangos/manager\n'; }
    update_git() {
        local args="$*"
        case "$args" in
            *"/opt/mangos/source rev-parse --show-toplevel"*) printf '/opt/mangos/source\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"/opt/mangos/source fetch --quiet origin"*) return 0 ;;
            *"/opt/mangos/source rev-parse origin/development^{commit}"*) printf 'dddddddddddddddddddddddddddddddddddddddd\n' ;;
            *"/opt/mangos/source rev-parse HEAD"*) printf 'cccccccccccccccccccccccccccccccccccccccc\n' ;;
            *"/opt/mangos/source rev-parse origin/development"*) printf 'dddddddddddddddddddddddddddddddddddddddd\n' ;;
            *"/opt/mangos/source rev-list --count HEAD..origin/development"*) printf '0\n' ;;
            *"/opt/mangos/source rev-list --count origin/development..HEAD"*) printf '1\n' ;;
            *"/opt/mangos/source status --porcelain"*) printf ' M src/game/Main.cpp\n' ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }
    update_nproc() { printf '8\n'; }

    output=$(update_plan)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"success\":true'* ]]" "update_plan json reports success" || all_passed=1
    assert_true "[[ \$compact_output == *'\"source_repo\":\"/opt/mangos/source\"'* ]]" "update_plan json includes source repo" || all_passed=1
    assert_true "[[ \$compact_output == *'\"commits_ahead\":1'* ]]" "update_plan json reports ahead count" || all_passed=1
    assert_true "[[ \$compact_output == *'\"worktree_dirty\":true'* ]]" "update_plan json reports dirty state" || all_passed=1
    assert_true "[[ \$compact_output == *'\"backup_required\":true'* ]]" "update_plan json requires backup" || all_passed=1
    assert_true "[[ \$compact_output == *'\"steps\":[\"vmangos-managerbackupnow--verify\"'* ]]" "update_plan json includes steps" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_apply_runs_backup_and_rebuild_workflow() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output call_log_file pulled=0
    call_log_file=$(mktemp)

    OUTPUT_FORMAT="text"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        return 0
    }
    config_resolve_manager_root() { printf '/opt/mangos/manager\n'; }
    acquire_lock() { printf 'lock|\n' >> "$call_log_file"; }
    release_lock() { printf 'unlock|\n' >> "$call_log_file"; }
    backup_now() { printf 'backup|\n' >> "$call_log_file"; }
    server_stop() { printf 'stop|\n' >> "$call_log_file"; }
    server_start() { printf 'start|\n' >> "$call_log_file"; }
    update_run_cmake() { printf 'cmake|\n' >> "$call_log_file"; }
    update_run_make_build() { printf 'makebuild|\n' >> "$call_log_file"; }
    update_run_make_install() { printf 'makeinstall|\n' >> "$call_log_file"; }
    update_post_apply_verify() { printf 'verify|\n' >> "$call_log_file"; }
    server_status() { printf 'status|\n' >> "$call_log_file"; }
    update_nproc() { printf '4\n'; }
    update_git() {
        local args="$*"
        case "$args" in
            *"/opt/mangos/source rev-parse --show-toplevel"*) printf '/opt/mangos/source\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"/opt/mangos/source fetch --quiet origin"*) return 0 ;;
            *"/opt/mangos/source rev-parse origin/development^{commit}"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-parse origin/development"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-list --count HEAD..origin/development"*) printf '2\n' ;;
            *"/opt/mangos/source rev-list --count origin/development..HEAD"*) printf '0\n' ;;
            *"/opt/mangos/source status --porcelain"*) return 0 ;;
            *"/opt/mangos/source pull --ff-only origin development"*) pulled=1; printf 'pull|\n' >> "$call_log_file"; return 0 ;;
            *"/opt/mangos/source rev-parse HEAD"*)
                if [[ "$pulled" -eq 1 ]]; then
                    printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
                else
                    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
                fi
                ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_apply true)
    assert_true "[[ \$(tr -d '\\n' < \"$call_log_file\") == 'backup|lock|stop|pull|cmake|makebuild|makeinstall|start|verify|unlock|status|' ]]" "update_apply runs backup/build/install workflow in order" || all_passed=1
    assert_true "[[ \$output == *'Applying VMANGOS Core Update'* ]]" "update_apply prints section header" || all_passed=1
    assert_true "[[ \$output == *'✓ Update applied successfully'* ]]" "update_apply reports success" || all_passed=1

    rm -f "$call_log_file"
    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_apply_rejects_dirty_source_tree() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output call_log_file
    call_log_file=$(mktemp)

    OUTPUT_FORMAT="text"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        return 0
    }
    config_resolve_manager_root() { printf '/opt/mangos/manager\n'; }
    backup_now() { printf 'backup|\n' >> "$call_log_file"; }
    update_git() {
        local args="$*"
        case "$args" in
            *"/opt/mangos/source rev-parse --show-toplevel"*) printf '/opt/mangos/source\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"/opt/mangos/source fetch --quiet origin"*) return 0 ;;
            *"/opt/mangos/source rev-parse origin/development^{commit}"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-parse HEAD"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
            *"/opt/mangos/source rev-parse origin/development"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-list --count HEAD..origin/development"*) printf '1\n' ;;
            *"/opt/mangos/source rev-list --count origin/development..HEAD"*) printf '0\n' ;;
            *"/opt/mangos/source status --porcelain"*) printf ' M src/game/Main.cpp\n' ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_apply true 2>&1 || true)
    assert_true "[[ \$output == *'Refusing to apply update with local uncommitted changes'* ]]" "update_apply rejects dirty source tree" || all_passed=1
    assert_true "[[ ! -s \"$call_log_file\" ]]" "update_apply does not start backup when source tree is dirty" || all_passed=1

    rm -f "$call_log_file"
    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_inspect_reports_supported_db_migrations() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output compact_output

    OUTPUT_FORMAT="json"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_DATABASE_HOST="127.0.0.1"
        CONFIG_DATABASE_PORT="3306"
        CONFIG_DATABASE_USER="mangos"
        CONFIG_DATABASE_PASSWORD="secret"
        CONFIG_DATABASE_AUTH_DB="auth"
        CONFIG_DATABASE_WORLD_DB="world"
        CONFIG_DATABASE_LOGS_DB="logs"
        return 0
    }
    update_list_current_migration_files() { return 0; }
    update_mysql_query() {
        local database="$1"
        local query="$2"
        if [[ "$query" == "SHOW TABLES LIKE 'migrations';" ]]; then
            printf 'migrations\n'
            return 0
        fi
        case "$database" in
            auth) printf '20260410094340\n' ;;
            world) printf '20260412145522\n' ;;
            logs) printf '20221008210304\n' ;;
        esac
    }
    update_git() {
        local args="$*"
        case "$args" in
            *"/opt/mangos/source rev-parse --show-toplevel"*) printf '/opt/mangos/source\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"/opt/mangos/source fetch --quiet origin"*) return 0 ;;
            *"/opt/mangos/source rev-parse origin/development^{commit}"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-parse HEAD"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
            *"/opt/mangos/source rev-parse origin/development"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"/opt/mangos/source rev-list --count HEAD..origin/development"*) printf '2\n' ;;
            *"/opt/mangos/source rev-list --count origin/development..HEAD"*) printf '0\n' ;;
            *"/opt/mangos/source status --porcelain"*) return 0 ;;
            *"/opt/mangos/source diff --name-status --find-renames HEAD..origin/development -- sql"*)
                printf 'A\tsql/migrations/20260420000000_world.sql\n'
                printf 'A\tsql/migrations/20260420010000_logon.sql\n'
                ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_inspect)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"db_assessment\":\"schema_migrations_pending\"'* ]]" "update_inspect reports pending supported DB migrations" || all_passed=1
    assert_true "[[ \$compact_output == *'\"db_automation_supported\":true'* ]]" "update_inspect marks supported DB automation" || all_passed=1
    assert_true "[[ \$compact_output == *'\"role\":\"world\"'* && \$compact_output == *'\"id\":\"20260420000000\"'* ]]" "update_inspect includes pending world migration" || all_passed=1
    assert_true "[[ \$compact_output == *'\"role\":\"auth\"'* && \$compact_output == *'\"id\":\"20260420010000\"'* ]]" "update_inspect includes pending auth migration" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_plan_include_db_reports_manual_review() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output compact_output

    OUTPUT_FORMAT="json"
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_DATABASE_HOST="127.0.0.1"
        CONFIG_DATABASE_PORT="3306"
        CONFIG_DATABASE_USER="mangos"
        CONFIG_DATABASE_PASSWORD="secret"
        CONFIG_DATABASE_AUTH_DB="auth"
        CONFIG_DATABASE_WORLD_DB="world"
        CONFIG_DATABASE_LOGS_DB="logs"
        return 0
    }
    update_nproc() { printf '4\n'; }
    update_list_current_migration_files() { return 0; }
    update_mysql_query() {
        local query="$2"
        if [[ "$query" == "SHOW TABLES LIKE 'migrations';" ]]; then
            printf 'migrations\n'
        fi
    }
    update_git() {
        local args="$*"
        case "$args" in
            *"/opt/mangos/source rev-parse --show-toplevel"*) printf '/opt/mangos/source\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"/opt/mangos/source rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"/opt/mangos/source fetch --quiet origin"*) return 0 ;;
            *"/opt/mangos/source rev-parse origin/development^{commit}"*) printf 'dddddddddddddddddddddddddddddddddddddddd\n' ;;
            *"/opt/mangos/source rev-parse HEAD"*) printf 'cccccccccccccccccccccccccccccccccccccccc\n' ;;
            *"/opt/mangos/source rev-parse origin/development"*) printf 'dddddddddddddddddddddddddddddddddddddddd\n' ;;
            *"/opt/mangos/source rev-list --count HEAD..origin/development"*) printf '1\n' ;;
            *"/opt/mangos/source rev-list --count origin/development..HEAD"*) printf '0\n' ;;
            *"/opt/mangos/source status --porcelain"*) return 0 ;;
            *"/opt/mangos/source diff --name-status --find-renames HEAD..origin/development -- sql"*)
                printf 'A\tsql/custom/repack/Custom-START_ON_GM_ISLAND.sql\n'
                ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_plan true)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"db_assessment\":\"manual_review_required\"'* ]]" "update_plan --include-db reports manual review state" || all_passed=1
    assert_true "[[ \$compact_output == *'\"db_automation_supported\":false'* ]]" "update_plan --include-db marks manual DB automation unsupported" || all_passed=1
    assert_true "[[ \$compact_output == *'Custom-START_ON_GM_ISLAND.sql'* ]]" "update_plan --include-db reports manual SQL path" || all_passed=1

    OUTPUT_FORMAT="text"
    return $all_passed
}

test_update_apply_include_db_runs_migrations() {
    # shellcheck source=../lib/update.sh
    source "$LIB_DIR/update.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output call_log_file pulled=0 repo_root migration_path
    call_log_file=$(mktemp)
    repo_root=$(mktemp -d)
    migration_path="$repo_root/sql/migrations/20260420000000_world.sql"
    mkdir -p "$repo_root/sql/migrations"
    printf '%s\n' '-- migration' > "$migration_path"

    OUTPUT_FORMAT="text"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_DATABASE_HOST="127.0.0.1"
        CONFIG_DATABASE_PORT="3306"
        CONFIG_DATABASE_USER="mangos"
        CONFIG_DATABASE_PASSWORD="secret"
        CONFIG_DATABASE_AUTH_DB="auth"
        CONFIG_DATABASE_WORLD_DB="world"
        CONFIG_DATABASE_LOGS_DB="logs"
        return 0
    }
    acquire_lock() { printf 'lock|\n' >> "$call_log_file"; }
    release_lock() { printf 'unlock|\n' >> "$call_log_file"; }
    backup_now() { printf 'backup|\n' >> "$call_log_file"; }
    server_stop() { printf 'stop|\n' >> "$call_log_file"; }
    server_start() { printf 'start|\n' >> "$call_log_file"; }
    update_run_cmake() { printf 'cmake|\n' >> "$call_log_file"; }
    update_run_make_build() { printf 'makebuild|\n' >> "$call_log_file"; }
    update_run_make_install() { printf 'makeinstall|\n' >> "$call_log_file"; }
    update_post_apply_verify() { printf 'verify|\n' >> "$call_log_file"; }
    server_status() { printf 'status|\n' >> "$call_log_file"; }
    update_nproc() { printf '4\n'; }
    update_list_current_migration_files() {
        if [[ "$pulled" -eq 1 ]]; then
            printf 'sql/migrations/20260420000000_world.sql\n'
        fi
    }
    update_mysql_query() {
        local database="$1"
        local query="$2"
        if [[ "$query" == "SHOW TABLES LIKE 'migrations';" ]]; then
            printf 'migrations\n'
            return 0
        fi
        case "$database" in
            auth) printf '20260410094340\n' ;;
            world) printf '20260412145522\n' ;;
            logs) printf '20221008210304\n' ;;
        esac
    }
    update_mysql_exec_file() {
        local database="$1"
        local sql_file="$2"
        printf 'db:%s:%s|\n' "$database" "$(basename "$sql_file")" >> "$call_log_file"
    }
    update_git() {
        local args="$*"
        case "$args" in
            *"$repo_root rev-parse --show-toplevel"*) printf '%s\n' "$repo_root" ;;
            *"$repo_root rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf 'origin/development\n' ;;
            *"$repo_root rev-parse --abbrev-ref HEAD"*) printf 'development\n' ;;
            *"$repo_root fetch --quiet origin"*) return 0 ;;
            *"$repo_root rev-parse origin/development^{commit}"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"$repo_root rev-parse origin/development"*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
            *"$repo_root rev-list --count HEAD..origin/development"*) printf '1\n' ;;
            *"$repo_root rev-list --count origin/development..HEAD"*) printf '0\n' ;;
            *"$repo_root status --porcelain"*) return 0 ;;
            *"$repo_root diff --name-status --find-renames HEAD..origin/development -- sql"*)
                printf 'A\tsql/migrations/20260420000000_world.sql\n'
                ;;
            *"$repo_root pull --ff-only origin development"*)
                pulled=1
                printf 'pull|\n' >> "$call_log_file"
                return 0
                ;;
            *"$repo_root rev-parse HEAD"*)
                if [[ "$pulled" -eq 1 ]]; then
                    printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
                else
                    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
                fi
                ;;
            *)
                echo "unexpected git args: $args" >&2
                return 1
                ;;
        esac
    }

    output=$(update_apply true true)
    assert_true "[[ \$(tr -d '\\n' < \"$call_log_file\") == 'backup|lock|stop|pull|db:world:20260420000000_world.sql|cmake|makebuild|makeinstall|start|verify|unlock|status|' ]]" "update_apply --include-db runs migration before build/install" || all_passed=1
    assert_true "[[ \$output == *'Applying world migration 20260420000000 to world'* ]]" "update_apply --include-db logs world migration application" || all_passed=1

    rm -f "$call_log_file"
    rm -rf "$repo_root"
    OUTPUT_FORMAT="text"
    return $all_passed
}

test_make_install_and_uninstall_targets() {
    local all_passed=0
    local temp_dir install_root

    temp_dir=$(mktemp -d)
    install_root="$temp_dir/opt/mangos/manager"
    mkdir -p "$install_root/config"
    printf '%s\n' '[database]' > "$install_root/config/manager.conf"

    make -C "$MANAGER_DIR" install DESTDIR="$temp_dir" PREFIX=/opt/mangos/manager >/dev/null

    assert_file_exists "$install_root/bin/vmangos-manager" "make install copies binary" || all_passed=1
    assert_file_exists "$install_root/lib/update.sh" "make install copies update module" || all_passed=1
    assert_file_exists "$install_root/lib/dashboard.sh" "make install copies dashboard shell module" || all_passed=1
    assert_file_exists "$install_root/lib/dashboard.py" "make install copies dashboard python app" || all_passed=1
    assert_file_exists "$install_root/dashboard-requirements.txt" "make install copies dashboard requirements" || all_passed=1
    assert_file_exists "$install_root/tests/run_tests.sh" "make install copies tests" || all_passed=1

    make -C "$MANAGER_DIR" uninstall DESTDIR="$temp_dir" PREFIX=/opt/mangos/manager >/dev/null

    assert_true "[[ ! -e \"$install_root/bin/vmangos-manager\" ]]" "make uninstall removes binary" || all_passed=1
    assert_true "[[ ! -e \"$install_root/lib/update.sh\" ]]" "make uninstall removes library files" || all_passed=1
    assert_true "[[ ! -e \"$install_root/lib/dashboard.py\" ]]" "make uninstall removes dashboard python app" || all_passed=1
    assert_true "[[ ! -e \"$install_root/dashboard-requirements.txt\" ]]" "make uninstall removes dashboard requirements" || all_passed=1
    assert_true "[[ -f \"$install_root/config/manager.conf\" ]]" "make uninstall preserves config files" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_dashboard_bootstrap_and_run() {
    # shellcheck source=../lib/dashboard.sh
    source "$LIB_DIR/dashboard.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir config_file mock_python manager_bin log_file run_args_file output
    temp_dir=$(mktemp -d)
    config_file="$temp_dir/manager.conf"
    mock_python="$temp_dir/mock-python3"
    manager_bin="$temp_dir/vmangos-manager"
    log_file="$temp_dir/dashboard.log"
    run_args_file="$temp_dir/dashboard.run"

    create_test_config "$config_file"
    setup_dashboard_mock_python "$mock_python"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$manager_bin"
    chmod +x "$manager_bin"

    CONFIG_FILE="$config_file"
    output=$(DASHBOARD_TEST_LOG="$log_file" \
        DASHBOARD_TEST_RUN_ARGS="$run_args_file" \
        VMANGOS_DASHBOARD_VENV_DIR="$temp_dir/.venv-dashboard" \
        VMANGOS_DASHBOARD_BOOTSTRAP_PYTHON="$mock_python" \
        dashboard_run "$manager_bin" 3 light true 2>&1)

    assert_true "[[ \$(cat \"$log_file\") == *'-m venv $temp_dir/.venv-dashboard'* ]]" "dashboard bootstrap creates virtual environment" || all_passed=1
    assert_true "[[ \$(cat \"$log_file\") == *'-m pip install -r '*'dashboard-requirements.txt'* ]]" "dashboard bootstrap installs requirements with pip" || all_passed=1
    assert_true "[[ ! -e \"$run_args_file\" ]]" "dashboard --bootstrap exits after dependency install" || all_passed=1
    assert_true "[[ \$output == *'Dashboard dependencies installed'* ]]" "dashboard bootstrap reports dependency install" || all_passed=1

    DASHBOARD_TEST_LOG="$log_file" \
    DASHBOARD_TEST_RUN_ARGS="$run_args_file" \
    VMANGOS_DASHBOARD_VENV_DIR="$temp_dir/.venv-dashboard" \
    dashboard_run "$manager_bin" 3 light false >/dev/null 2>&1
    assert_true "[[ \$(cat \"$run_args_file\") == *'--manager-bin $manager_bin --config $config_file --refresh 3 --theme light'* ]]" "dashboard run launches python app with parsed arguments" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_dashboard_snapshot_json_aggregates_backend() {
    local all_passed=0
    local temp_dir config_file mock_manager output compact_output
    temp_dir=$(mktemp -d)
    config_file="$temp_dir/manager.conf"
    mock_manager="$temp_dir/mock-manager"

    create_test_config "$config_file"

    cat > "$mock_manager" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"

if [[ "$args" == *"server status"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"services":{"auth":{"service":"auth","state":"active","running":true,"pid":111,"uptime_seconds":3600,"uptime_human":"1h 0m","memory_mb":32,"cpu_percent":0.2,"health":"healthy","restart_count_1h":0,"crash_loop_detected":false},"world":{"service":"world","state":"active","running":true,"pid":222,"uptime_seconds":7200,"uptime_human":"2h 0m","memory_mb":512,"cpu_percent":11.5,"health":"healthy","restart_count_1h":0,"crash_loop_detected":false}},"checks":{"database_connectivity":{"ok":true,"message":"ok"},"disk_space":{"ok":true,"path":"/opt/mangos","filesystem":"/dev/mock","total_kb":2000000,"used_kb":500000,"available_kb":1500000,"used_percent":25,"status":"ok"}},"players":{"online":1,"query_ok":true,"source":"auth.account.online"},"host":{"cpu":{"usage_percent":12.5,"status":"ok","cores":8},"memory":{"total_kb":8192000,"used_kb":4096000,"available_kb":4096000,"used_percent":50.0,"status":"ok"},"load":{"load_1":0.50,"load_5":0.40,"load_15":0.30,"status":"ok"}},"storage_io":{"available":true,"device":"mock","source":"/dev/mock","read_ops_per_sec":1.25,"write_ops_per_sec":2.75,"read_kbps":32.0,"write_kbps":48.0,"await_ms":0.8,"util_percent":42.0,"status":"ok"},"alerts":{"status":"healthy","active":[],"recent_events":[{"timestamp":"2026-04-13T21:55:00+00:00","service":"world","message":"World stable","raw":"2026-04-13T21:55:00+00:00 host world[222]: World stable"}]}},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"logs status"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"status":"healthy","log_root":"/opt/mangos/logs","config":{"path":"/etc/logrotate.d/vmangos","present":true,"in_sync":true},"logs":{"active_files":4,"active_size_bytes":2048,"rotated_files":2,"rotated_size_bytes":1024,"sensitive_files":2,"sensitive_permissions_ok":true},"disk":{"path":"/opt/mangos/logs","ok":true,"total_kb":2000000,"used_kb":500000,"available_kb":1500000,"used_percent":25,"required_free_kb":512000},"policy":{"copytruncate":true,"retention_days":30,"sensitive_retention_days":90,"max_size":"100M","min_size":"1M"}},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"account list --online"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"accounts":[{"id":7,"username":"PLAYERONE","gm_level":0,"online":true,"banned":false}]},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"account list"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"accounts":[{"id":7,"username":"PLAYERONE","gm_level":0,"online":true,"banned":false},{"id":8,"username":"GMADMIN","gm_level":3,"online":false,"banned":false}]},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"schedule list"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"schedules":[{"id":"20260413220000-1111","job_type":"restart","schedule_type":"weekly","time":"04:00","day":"Sun","timezone":"UTC","warnings":"30,15,5,1","announce_message":"Weekly maintenance","next_run":"Sun 2026-04-19 04:00:00 UTC"}]},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"update check"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"repo_root":"/opt/mangos/source","branch":"development","remote_ref":"origin/development","local_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","remote_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commits_behind":2,"update_available":true,"worktree_dirty":false,"install_target":"/opt/mangos"},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"update inspect"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"target":"vmangos-core","source_repo":"/opt/mangos/source","branch":"development","remote_ref":"origin/development","local_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","remote_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commits_behind":2,"commits_ahead":0,"worktree_dirty":false,"db_assessment":"schema_migrations_pending","db_automation_supported":true,"pending_migrations":[{"source":"git","role":"world","database":"world","id":"20260420000000","path":"sql/migrations/20260420000000_world.sql"}],"manual_review":[]},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"backup list --format json"* ]]; then
    cat <<'JSON'
[{"timestamp":"2026-04-13T21:30:00+00:00","file":"backup-20260413-213000.tar.gz","size_bytes":52428800,"created_by":"manager","databases":["auth","characters","mangos","logs"]}]
JSON
    exit 0
fi

if [[ "$args" == *"config validate --format json"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"valid":true},"error":null}
JSON
    exit 0
fi

if [[ "$args" == *"config show --format json"* ]]; then
    cat <<'JSON'
{"success":true,"timestamp":"2026-04-13T22:00:00+00:00","data":{"content":"[database]\nhost = 127.0.0.1\nport = 3306\nuser = mangos\nauth_db = auth\ncharacters_db = characters\nworld_db = mangos\nlogs_db = logs\n\n[server]\nauth_service = auth\nworld_service = world\ninstall_root = /opt/mangos\n\n[backup]\nbackup_dir = /tmp/vmangos-backups\n"},"error":null}
JSON
    exit 0
fi

echo "unexpected command: $args" >&2
exit 1
EOF

    chmod +x "$mock_manager"

    output=$(python3 "$MANAGER_DIR/lib/dashboard.py" --manager-bin "$mock_manager" --config "$config_file" --snapshot-json)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'\"server\":{\"ok\":true'* ]]" "dashboard snapshot records server payload" || all_passed=1
    assert_true "[[ \$compact_output == *'\"logs\":{\"ok\":true'* ]]" "dashboard snapshot records logs payload" || all_passed=1
    assert_true "[[ \$compact_output == *'\"schedule_list\":{\"ok\":true'* && \$compact_output == *'\"id\":\"20260413220000-1111\"'* ]]" "dashboard snapshot records schedule payload" || all_passed=1
    assert_true "[[ \$compact_output == *'\"update_check\":{\"ok\":true'* && \$compact_output == *'\"commits_behind\":2'* ]]" "dashboard snapshot records update check payload" || all_passed=1
    assert_true "[[ \$compact_output == *'\"update_inspect\":{\"ok\":true'* && \$compact_output == *'\"db_assessment\":\"schema_migrations_pending\"'* ]]" "dashboard snapshot records update inspect payload" || all_passed=1
    assert_true "[[ \$compact_output == *'\"players\":[{\"id\":7,\"username\":\"PLAYERONE\"'* ]]" "dashboard snapshot flattens online player list" || all_passed=1
    assert_true "[[ \$compact_output == *'\"all_accounts\":[{\"id\":7,\"username\":\"PLAYERONE\"'* ]]" "dashboard snapshot includes full account listing" || all_passed=1
    assert_true "[[ \$compact_output == *'\"schedules\":[{\"id\":\"20260413220000-1111\"'* ]]" "dashboard snapshot flattens scheduled job list" || all_passed=1
    assert_true "[[ \$compact_output == *'\"backups\":{\"entries\":[{\"timestamp\":\"2026-04-13T21:30:00+00:00\",\"file\":\"backup-20260413-213000.tar.gz\"'* ]]" "dashboard snapshot includes backup entries" || all_passed=1
    assert_true "[[ \$compact_output == *'\"summary\":{\"count\":1,\"backup_dir\":\"/tmp/vmangos-backups\",\"latest_file\":\"backup-20260413-213000.tar.gz\"'* ]]" "dashboard snapshot summarizes backup metadata" || all_passed=1
    assert_true "[[ \$compact_output == *'\"config_validate\":{\"ok\":true'* ]]" "dashboard snapshot includes config validation result" || all_passed=1
    assert_true "[[ \$compact_output == *'\"config_summary\":{\"install_root\":\"/opt/mangos\",\"auth_service\":\"auth\",\"world_service\":\"world\"'* ]]" "dashboard snapshot includes parsed config summary" || all_passed=1
    assert_true "[[ \$compact_output == *'\"captured_at\":\"'* ]]" "dashboard snapshot includes capture timestamp" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_dashboard_action_request_builder() {
    local all_passed=0 output compact_output

    output=$(python3 - "$MANAGER_DIR/lib/dashboard.py" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("dashboard_module", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

snapshot = {
    "all_accounts": [
        {"id": 8, "username": "GMADMIN", "gm_level": 3, "online": False, "banned": False}
    ],
    "schedules": [
        {"id": "20260413220000-1111", "job_type": "restart", "schedule_type": "weekly", "time": "04:00", "day": "Sun", "timezone": "UTC"}
    ],
    "backups": {
        "entries": [
            {"timestamp": "2026-04-13T21:30:00+00:00", "file": "backup-20260413-213000.tar.gz"}
        ],
        "summary": {"backup_dir": "/tmp/vmangos-backups"},
    },
}

payload = {
    "create": module.build_dashboard_action_request(
        snapshot,
        "",
        "",
        "",
        "account_create",
        {"username": "PLAYERTWO", "password": "Secret12", "confirm_password": "Secret12"},
    ),
    "setgm": module.build_dashboard_action_request(
        snapshot,
        "8",
        "",
        "",
        "account_setgm",
        {"gm_level": "2"},
    ),
    "restore": module.build_dashboard_action_request(
        snapshot,
        "",
        "backup-20260413-213000.tar.gz",
        "",
        "backup_restore_dry_run",
        {},
    ),
    "weekly": module.build_dashboard_action_request(
        snapshot,
        "",
        "",
        "",
        "backup_schedule_weekly",
        {"schedule": "Sun 04:00"},
    ),
    "logs_rotate": module.build_dashboard_action_request(snapshot, "", "", "", "logs_rotate", {}),
    "honor": module.build_dashboard_action_request(
        snapshot,
        "",
        "",
        "",
        "schedule_honor_create",
        {"schedule_type": "weekly", "day": "Sun", "time": "06:00", "timezone": "UTC"},
    ),
    "restart_job": module.build_dashboard_action_request(
        snapshot,
        "",
        "",
        "",
        "schedule_restart_create",
        {"schedule_type": "weekly", "day": "Sun", "time": "04:00", "timezone": "UTC", "warnings": "30,15,5,1", "announce": "Weekly maintenance"},
    ),
    "cancel": module.build_dashboard_action_request(snapshot, "", "", "20260413220000-1111", "schedule_cancel", {}),
    "config": module.build_dashboard_action_request(snapshot, "", "", "", "config_validate", {}),
    "bad_ban": module.build_dashboard_action_request(
        snapshot,
        "8",
        "",
        "",
        "account_ban",
        {"duration": "soon", "reason": "Bad!"},
    ),
}

print(json.dumps(payload, sort_keys=True))
PY
)

    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'\"create\":{\"command\":[\"account\",\"create\",\"PLAYERTWO\",\"--password-env\"]'* && \$compact_output == *'\"VMANGOS_PASSWORD\":\"Secret12\"'* ]]" "dashboard action builder creates password-env account requests" || all_passed=1
    assert_true "[[ \$compact_output == *'\"setgm\":{\"command\":[\"account\",\"setgm\",\"GMADMIN\",\"2\"]'* ]]" "dashboard action builder targets selected account for GM updates" || all_passed=1
    assert_true "[[ \$compact_output == *'\"restore\":{\"command\":[\"backup\",\"restore\",\"/tmp/vmangos-backups/backup-20260413-213000.tar.gz\",\"--dry-run\"]'* ]]" "dashboard action builder resolves restore dry-run path from backup selection" || all_passed=1
    assert_true "[[ \$compact_output == *'\"weekly\":{\"command\":[\"backup\",\"schedule\",\"--weekly\",\"Sun04:00\"]'* ]]" "dashboard action builder emits weekly backup schedule commands" || all_passed=1
    assert_true "[[ \$compact_output == *'\"logs_rotate\":{\"command\":[\"logs\",\"rotate\"]'* && \$compact_output == *'\"view\":\"operations\"'* ]]" "dashboard action builder exposes logs rotate in the operations view" || all_passed=1
    assert_true "[[ \$compact_output == *'\"honor\":{\"command\":[\"schedule\",\"honor\",\"--time\",\"06:00\",\"--weekly\",\"Sun\",\"--timezone\",\"UTC\"]'* ]]" "dashboard action builder emits honor schedule commands" || all_passed=1
    assert_true "[[ \$compact_output == *'\"restart_job\":{\"command\":[\"schedule\",\"restart\",\"--time\",\"04:00\",\"--weekly\",\"Sun\",\"--timezone\",\"UTC\",\"--warnings\",\"30,15,5,1\",\"--announce\",\"Weeklymaintenance\"]'* ]]" "dashboard action builder emits restart schedule commands" || all_passed=1
    assert_true "[[ \$compact_output == *'\"cancel\":{\"command\":[\"schedule\",\"cancel\",\"20260413220000-1111\"]'* && \$compact_output == *'\"view\":\"operations\"'* ]]" "dashboard action builder exposes schedule cancellation in the operations view" || all_passed=1
    assert_true "[[ \$compact_output == *'\"config\":{\"command\":[\"config\",\"validate\"]'* && \$compact_output == *'\"view\":\"config\"'* ]]" "dashboard action builder exposes config validation as a workflow action" || all_passed=1
    assert_true "[[ \$compact_output == *'\"bad_ban\":{\"error\":\"accountbanskipped:durationmustuseformslike30m,12h,or7d\"'* ]]" "dashboard action builder validates account ban input before dispatch" || all_passed=1

    return $all_passed
}

test_dashboard_render_helpers() {
    local all_passed=0 output compact_output

    output=$(python3 - "$MANAGER_DIR/lib/dashboard.py" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("dashboard_module", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

snapshot = {
    "captured_at": "2026-04-13T21:45:00+00:00",
    "players": [{"id": 8, "username": "PLAYERONE", "gm_level": 1, "online": True, "banned": False}],
    "backups": {"summary": {"count": 3}},
    "logs": {
        "ok": True,
        "data": {
            "status": "healthy",
            "config": {"present": True, "in_sync": True},
            "logs": {"active_files": 4, "rotated_files": 2, "sensitive_permissions_ok": True},
            "disk": {"used_percent": 18, "available_kb": 2097152},
            "policy": {"max_size": "100M", "min_size": "1M"},
        },
    },
    "update_check": {
        "ok": True,
        "data": {
            "branch": "development",
            "remote_ref": "origin/development",
            "commits_behind": 2,
            "update_available": True,
            "worktree_dirty": False,
            "local_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "remote_commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        },
    },
    "update_inspect": {
        "ok": True,
        "data": {
            "db_assessment": "schema_migrations_pending",
            "db_automation_supported": True,
            "pending_migrations": [{"id": "20260420000000"}],
            "manual_review": [],
        },
    },
    "server": {
        "ok": True,
        "data": {
            "services": {
                "auth": {"health": "active"},
                "world": {"health": "warning"},
            }
        },
    },
}

payload = {
    "banner": module.render_action_banner("accounts", snapshot, "backup completed", "success", 2),
    "sidebar": module.render_sidebar("operations", "backup completed", snapshot, 2),
    "player": module.render_player_details(snapshot["players"][0], len(snapshot["players"])),
    "empty_player": module.render_player_details(None, 0),
    "logs": module.render_logs_panel(snapshot),
    "update": module.render_update_panel(snapshot, {"warning": "Supported DB migrations are pending.", "steps": ["vmangos-manager backup now --verify", "vmangos-manager server stop --graceful"]}),
    "schedule": module.render_schedule_details(
        {"id": "20260413220000-1111", "job_type": "restart", "schedule_type": "weekly", "time": "04:00", "day": "Sun", "timezone": "UTC", "warnings": "30,15,5,1", "announce_message": "Weekly maintenance", "next_run": "Sun 2026-04-19 04:00:00 UTC"},
        1,
        "logs rotate completed",
        "success",
    ),
}

print(json.dumps(payload, sort_keys=True))
PY
)

    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'READY'* && \$compact_output == *'Accounts'* && \$compact_output == *'commanddeck'* && \$compact_output == *'refresh[/]2s'* ]]" "dashboard action banner exposes tone, view, interval, and command-deck framing" || all_passed=1
    assert_true "[[ \$compact_output == *'VMaNGOSManager'* && \$compact_output == *'RealmPulse'* && \$compact_output == *'Players[/]1online'* && \$compact_output == *'Backups[/]3known'* && \$compact_output == *'ActiveHotkeys'* && \$compact_output == *'l[/]rotatelogs'* && \$compact_output == *'P[/]updateplan'* ]]" "dashboard sidebar exposes live pulse summary, operator framing, and operations keys" || all_passed=1
    assert_true "[[ \$compact_output == *'Selected[/][bold#2dd4bf]PLAYERONE'* && \$compact_output == *'Operatormove[/]switchto[bold#f59e0b]Accounts[/]forpassword,GM,andbanactions.'* ]]" "dashboard player details emphasize the selected player workflow" || all_passed=1
    assert_true "[[ \$compact_output == *'Snapshot[/]noactiveplayerrowselected'* && \$compact_output == *'chooseaplayerrowwhensomeonelogsin.'* ]]" "dashboard empty player state explains next operator step" || all_passed=1
    assert_true "[[ \$compact_output == *'LogsHealth'* && \$compact_output == *'Rotationhygiene,retention,andstoragepressure.'* && \$compact_output == *'Retention[/]max=100Mmin=1M'* ]]" "dashboard logs panel summarizes health and retention" || all_passed=1
    assert_true "[[ \$compact_output == *'UpdateState'* && \$compact_output == *'database-impactawareness.'* && \$compact_output == *'Assessment[/][bold#f59e0b]schemamigrationspending'* && \$compact_output == *'Next[/]vmangos-managerbackupnow--verify'* ]]" "dashboard update panel surfaces DB-aware update state and plan steps" || all_passed=1
    assert_true "[[ \$compact_output == *'JobDetails'* && \$compact_output == *'logsrotatecompleted'* && \$compact_output == *'cancelselectedjob'* ]]" "dashboard schedule details include module-local result context" || all_passed=1

    return $all_passed
}

test_server_player_count_fallback() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0

    DB_HOST="127.0.0.1"
    DB_PORT="3306"
    DB_USER="mangos"
    DB_PASS=""
    AUTH_DB="auth"
    CONFIG_DATABASE_CHARACTERS_DB="characters"

    mysql() {
        local args="$*"
        if [[ "$args" == *"auth.account WHERE online = 1"* ]]; then
            return 1
        fi
        if [[ "$args" == *"characters.characters WHERE online = 1"* ]]; then
            echo "3"
            return 0
        fi
        echo "1"
    }

    local result
    result=$(get_online_player_count_result)
    assert_equals "3|characters.characters.online" "$result" "player count falls back to characters schema query" || all_passed=1

    return $all_passed
}

test_server_validate_interval() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0

    if server_validate_interval "2"; then
        echo -e "${GREEN}✓${NC} watch interval accepts positive integer"
    else
        echo -e "${RED}✗${NC} watch interval rejected valid integer"
        all_passed=1
    fi

    if ! server_validate_interval "0"; then
        echo -e "${GREEN}✓${NC} watch interval rejects zero"
    else
        echo -e "${RED}✗${NC} watch interval accepted zero"
        all_passed=1
    fi

    if ! server_validate_interval "abc"; then
        echo -e "${GREEN}✓${NC} watch interval rejects non-numeric values"
    else
        echo -e "${RED}✗${NC} watch interval accepted non-numeric value"
        all_passed=1
    fi

    return $all_passed
}

test_server_start_fails_when_database_unreachable() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output install_root service_start_called=0
    install_root=$(mktemp -d)

    mkdir -p "$install_root/run/etc"
    : > "$install_root/run/etc/mangosd.conf"
    : > "$install_root/run/etc/realmd.conf"

    AUTH_SERVICE="auth"
    WORLD_SERVICE="world"
    INSTALL_ROOT="$install_root"
    SERVER_CONFIG_LOADED=1

    server_load_config() { return 0; }
    db_check_connection() { return 1; }
    service_start() { service_start_called=1; return 0; }

    output=$(server_start false 30 2>&1 || true)
    assert_true "[[ \$output == *'Database connectivity check failed'* ]]" "server_start reports DB preflight failure" || all_passed=1
    assert_true "[[ \$output == *'Pre-flight checks failed'* ]]" "server_start exits cleanly when DB is unreachable" || all_passed=1
    assert_equals "0" "$service_start_called" "server_start does not start services after DB preflight failure" || all_passed=1

    rm -rf "$install_root"
    return $all_passed
}

test_server_start_orders_services() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local order_file order
    order_file=$(mktemp)

    AUTH_SERVICE="auth"
    WORLD_SERVICE="world"
    SERVER_CONFIG_LOADED=1

    server_load_config() { return 0; }
    preflight_check() { return 0; }
    service_active() { return 1; }
    service_start() {
        echo "$1" >> "$order_file"
        return 0
    }

    server_start false >/dev/null 2>&1
    order=$(paste -sd, "$order_file")
    assert_equals "auth,world" "$order" "server_start starts auth before world" || all_passed=1

    rm -f "$order_file"
    return $all_passed
}

test_server_restart_passes_timeout_to_stop_and_start() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local call_log
    call_log=$(mktemp)

    server_stop() { printf 'stop:%s:%s:%s\n' "$1" "$2" "$3" >> "$call_log"; }
    server_start() { printf 'start:%s:%s\n' "$1" "$2" >> "$call_log"; }
    sleep() { :; }

    server_restart 45 >/dev/null 2>&1

    assert_equals $'stop:true:false:45\nstart:true:45' "$(cat "$call_log")" "server_restart passes timeout through stop/start workflow" || all_passed=1

    rm -f "$call_log"
    return $all_passed
}

test_server_stop_orders_services() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local order_file order
    order_file=$(mktemp)

    AUTH_SERVICE="auth"
    WORLD_SERVICE="world"
    SERVER_CONFIG_LOADED=1

    server_load_config() { return 0; }
    service_active() { return 0; }
    systemctl() {
        if [[ "$1" == "stop" ]]; then
            echo "$2" >> "$order_file"
        fi
        return 0
    }

    server_stop false false >/dev/null 2>&1
    order=$(paste -sd, "$order_file")
    assert_equals "world,auth" "$order" "server_stop stops world before auth" || all_passed=1

    rm -f "$order_file"
    return $all_passed
}

test_server_stop_respects_timeout_without_force() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output systemctl_log
    systemctl_log=$(mktemp)

    AUTH_SERVICE="auth"
    WORLD_SERVICE="world"
    SERVER_CONFIG_LOADED=1

    server_load_config() { return 0; }
    service_active() {
        case "$1" in
            world) return 0 ;;
            auth) return 1 ;;
            *) return 1 ;;
        esac
    }
    systemctl() {
        printf '%s %s\n' "$1" "${2:-}" >> "$systemctl_log"
        return 0
    }
    sleep() { :; }

    output=$(server_stop true false 2 2>&1 || true)
    assert_true "[[ \$output == *'World service did not stop within 2s'* ]]" "server_stop reports graceful timeout expiry" || all_passed=1
    assert_equals "stop world" "$(head -n 1 "$systemctl_log")" "server_stop requests world stop before aborting on timeout" || all_passed=1

    rm -f "$systemctl_log"
    return $all_passed
}

test_server_crash_loop_detection() {
    # shellcheck source=../lib/server.sh
    source "$LIB_DIR/server.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local restart_count

    journalctl() {
        cat <<'EOF'
Scheduled restart job
Scheduled restart job
Scheduled restart job
EOF
    }

    restart_count=$(server_get_restart_count_1h world)
    assert_equals "3" "$restart_count" "server_get_restart_count_1h counts recent scheduled restart jobs" || all_passed=1

    if server_is_crash_loop_detected world; then
        echo -e "${GREEN}✓${NC} server crash-loop detection trips at threshold"
    else
        echo -e "${RED}✗${NC} server crash-loop detection missed threshold"
        all_passed=1
    fi

    return $all_passed
}

test_cli_status_json_with_mocks() {
    local all_passed=0
    local temp_dir mock_dir proc_root config_file output compact_output
    temp_dir=$(mktemp -d)
    mock_dir="$temp_dir/mockbin"
    proc_root="$temp_dir/proc"
    mkdir -p "$mock_dir"
    config_file="$temp_dir/manager.conf"

    create_test_config "$config_file"
    setup_status_mock_bin "$mock_dir"
    setup_status_proc_root "$proc_root"

    output=$(PATH="$mock_dir:$PATH" MANAGER_CONFIG="$config_file" VMANGOS_PROC_ROOT="$proc_root" bash "$MANAGER_DIR/bin/vmangos-manager" server status --format json 2>/dev/null)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'\"success\":true'* ]]" "CLI status json reports success" || all_passed=1
    assert_true "[[ \$compact_output == *'\"database_connectivity\":{\"ok\":true'* ]]" "CLI status json includes DB connectivity check" || all_passed=1
    assert_true "[[ \$compact_output == *'\"source\":\"auth.account.online\"'* ]]" "CLI status json records primary player-count source" || all_passed=1
    assert_true "[[ \$compact_output == *'\"available_kb\":1536000'* ]]" "CLI status json includes disk availability" || all_passed=1
    assert_true "[[ \$compact_output == *'\"health\":\"healthy\"'* ]]" "CLI status json includes service health labels" || all_passed=1
    assert_true "[[ \$compact_output == *'\"restart_count_1h\":0'* ]]" "CLI status json includes restart count field" || all_passed=1
    assert_true "[[ \$compact_output == *'\"cpu\":{\"usage_percent\":17.5,\"status\":\"ok\",\"cores\":8}'* ]]" "CLI status json includes host CPU metrics" || all_passed=1
    assert_true "[[ \$compact_output == *'\"memory\":{\"total_kb\":8192000,\"used_kb\":4096000,\"available_kb\":4096000,\"used_percent\":50.0,\"status\":\"ok\"}'* ]]" "CLI status json includes host memory metrics" || all_passed=1
    assert_true "[[ \$compact_output == *'\"storage_io\":{\"available\":true,\"device\":\"mock\"'* && \$compact_output == *'\"util_percent\":61.25'* ]]" "CLI status json includes disk I/O metrics when iostat is available" || all_passed=1
    assert_true "[[ \$compact_output == *'\"alerts\":{\"status\":\"healthy\",\"active\":[]'* ]]" "CLI status json includes healthy alert summary" || all_passed=1
    assert_true "[[ \$compact_output == *'\"recent_events\":[{\"timestamp\":\"2026-04-13T10:15:00+00:00\",\"service\":\"world\"'* ]]" "CLI status json includes recent events feed" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_cli_status_json_degrades_without_iostat_and_raises_alerts() {
    local all_passed=0
    local temp_dir mock_dir proc_root config_file events_file top_file output compact_output
    temp_dir=$(mktemp -d)
    mock_dir="$temp_dir/mockbin"
    proc_root="$temp_dir/proc"
    mkdir -p "$mock_dir" "$proc_root"
    config_file="$temp_dir/manager.conf"
    events_file="$temp_dir/events.log"
    top_file="$temp_dir/top.txt"

    create_test_config "$config_file"
    setup_status_mock_bin "$mock_dir"

    cat > "$proc_root/meminfo" << 'EOF'
MemTotal:       1000000 kB
MemFree:          20000 kB
MemAvailable:     50000 kB
Buffers:          10000 kB
Cached:           20000 kB
EOF

    cat > "$proc_root/loadavg" << 'EOF'
9.50 8.00 7.00 2/100 12345
EOF

    cat > "$top_file" << 'EOF'
top - 10:10:10 up 1 day,  1:23,  1 user,  load average: 9.50, 8.00, 7.00
Tasks: 100 total,   1 running, 99 sleeping,   0 stopped,   0 zombie
%Cpu(s): 70.0 us, 25.0 sy,  0.0 ni, 5.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
EOF

    cat > "$events_file" << 'EOF'
2026-04-13T11:01:00+00:00 host world[222]: High latency detected
EOF

    output=$(PATH="$mock_dir:$PATH" \
        MANAGER_CONFIG="$config_file" \
        VMANGOS_PROC_ROOT="$proc_root" \
        STATUS_TEST_TOP_FILE="$top_file" \
        STATUS_TEST_CPU_CORES="4" \
        STATUS_TEST_IOSTAT_MODE="absent" \
        STATUS_TEST_EVENTS_FILE="$events_file" \
        bash "$MANAGER_DIR/bin/vmangos-manager" server status --format json 2>/dev/null)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'\"storage_io\":{\"available\":false'* && \$compact_output == *'\"status\":\"unavailable\"'* ]]" "CLI status json degrades cleanly when iostat is unavailable" || all_passed=1
    assert_true "[[ \$compact_output == *'\"alerts\":{\"status\":\"critical\"'* ]]" "CLI status json raises critical overall alert state for stressed host metrics" || all_passed=1
    assert_true "[[ \$compact_output == *'\"source\":\"host.cpu\"'* && \$compact_output == *'\"source\":\"host.memory\"'* && \$compact_output == *'\"source\":\"host.load\"'* ]]" "CLI status json emits threshold-derived alerts" || all_passed=1
    assert_true "[[ \$compact_output == *'\"recent_events\":[{\"timestamp\":\"2026-04-13T11:01:00+00:00\",\"service\":\"world\",\"message\":\"Highlatencydetected\"'* ]]" "CLI status json keeps recent events when alerts are present" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_cli_status_watch_single_iteration() {
    local all_passed=0
    local temp_dir mock_dir config_file output
    temp_dir=$(mktemp -d)
    mock_dir="$temp_dir/mockbin"
    mkdir -p "$mock_dir"
    config_file="$temp_dir/manager.conf"

    create_test_config "$config_file"
    setup_status_mock_bin "$mock_dir"

    output=$(PATH="$mock_dir:$PATH" MANAGER_CONFIG="$config_file" STATUS_TEST_PLAYER_MODE="fallback" STATUS_WATCH_MAX_ITERATIONS=1 bash "$MANAGER_DIR/bin/vmangos-manager" server status --watch --interval 1 2>/dev/null)

    assert_true "[[ \$output == *'VMANGOS Server Status Watch'* ]]" "watch mode prints watch header" || all_passed=1
    assert_true "[[ \$output == *'Press Ctrl+C to stop'* ]]" "watch mode prints interrupt guidance" || all_passed=1
    assert_true "[[ \$output == *'health: healthy'* ]]" "watch mode prints service health details" || all_passed=1
    assert_true "[[ \$output == *'Source: characters.characters.online'* ]]" "watch mode reports fallback player-count source" || all_passed=1
    assert_true "[[ \$output == *'Stopped status watch.'* ]]" "watch mode exits cleanly after test iteration" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_cli_status_watch_rejects_json() {
    local all_passed=0
    local output

    output=$(bash "$MANAGER_DIR/bin/vmangos-manager" server status --watch --format json 2>&1 || true)
    assert_true "[[ \$output == *'watch mode only supports text output'* ]]" "watch mode rejects json format" || all_passed=1

    return $all_passed
}

test_logs_render_config_includes_issue17_policy() {
    # shellcheck source=../lib/logs.sh
    source "$LIB_DIR/logs.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir config_file install_root output
    temp_dir=$(mktemp -d)
    install_root="$temp_dir/install"
    config_file="$temp_dir/manager.conf"

    create_test_config "$config_file" "$install_root"
    CONFIG_FILE="$config_file"
    LOGS_CONFIG_LOADED=""

    output=$(logs_render_logrotate_config)
    assert_true "[[ \$output == *'$install_root/logs/mangosd/Server.log'* && \$output == *'$install_root/logs/mangosd/Bg.log'* ]]" "logs config targets mangosd logs under configured install root" || all_passed=1
    assert_true "[[ \$output == *'$install_root/logs/realmd/*.log'* && \$output == *'$install_root/logs/honor/*.log'* ]]" "logs config targets realmd and honor logs" || all_passed=1
    assert_true "[[ \$output == *'copytruncate'* ]]" "logs config documents copytruncate strategy" || all_passed=1
    assert_true "[[ \$output == *'rotate 30'* && \$output == *'rotate 90'* ]]" "logs config includes standard and sensitive retention policies" || all_passed=1
    assert_true "[[ \$output == *'gm_critical.log'* && \$output == *'Anticheat.log'* ]]" "logs config includes sensitive log stanza" || all_passed=1
    assert_equals "1" "$(printf '%s' "$output" | grep -c 'Anticheat.log')" "logs config avoids duplicate Anticheat entries" || all_passed=1
    assert_equals "1" "$(printf '%s' "$output" | grep -c 'gm_critical.log')" "logs config avoids duplicate gm_critical entries" || all_passed=1
    assert_true "[[ \$output == *'su mangos mangos'* ]]" "logs config uses expected ownership for logrotate" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_logs_status_json_reports_counts_and_permission_drift() {
    # shellcheck source=../lib/logs.sh
    source "$LIB_DIR/logs.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir config_file install_root output compact_output
    temp_dir=$(mktemp -d)
    install_root="$temp_dir/install"
    config_file="$temp_dir/manager.conf"

    create_test_config "$config_file" "$install_root"
    mkdir -p "$install_root/logs/mangosd"
    printf '%s\n' 'server' > "$install_root/logs/mangosd/Server.log"
    printf '%s\n' 'anti' > "$install_root/logs/mangosd/Anticheat.log"
    printf '%s\n' 'gm' > "$install_root/logs/mangosd/gm_critical.log"
    printf '%s\n' 'rotated' > "$install_root/logs/mangosd/Server.log-20260413-1.gz"
    chmod 644 "$install_root/logs/mangosd/Anticheat.log" "$install_root/logs/mangosd/gm_critical.log"

    CONFIG_FILE="$config_file"
    LOGS_ROTATE_CONFIG_PATH="$temp_dir/vmangos.logrotate"
    LOGS_CONFIG_LOADED=""
    logs_install_config >/dev/null

    output=$(logs_status_json)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"success\":true'* ]]" "logs status json reports success" || all_passed=1
    assert_true "[[ \$compact_output == *'\"present\":true'* && \$compact_output == *'\"in_sync\":true'* ]]" "logs status json reports installed in-sync config" || all_passed=1
    assert_true "[[ \$compact_output == *'\"active_files\":3'* ]]" "logs status json counts active log files" || all_passed=1
    assert_true "[[ \$compact_output == *'\"rotated_files\":1'* ]]" "logs status json counts rotated log files" || all_passed=1
    assert_true "[[ \$compact_output == *'\"sensitive_permissions_ok\":false'* ]]" "logs status json reports sensitive permission drift" || all_passed=1
    assert_true "[[ \$compact_output == *'\"status\":\"degraded\"'* ]]" "logs status json degrades health when sensitive permissions are loose" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_logs_rotate_force_runs_logrotate_and_hardens_permissions() {
    # shellcheck source=../lib/logs.sh
    source "$LIB_DIR/logs.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir config_file install_root mock_dir command_log output perms
    temp_dir=$(mktemp -d)
    install_root="$temp_dir/install"
    config_file="$temp_dir/manager.conf"
    mock_dir="$temp_dir/mockbin"
    command_log="$temp_dir/logrotate.log"

    create_test_config "$config_file" "$install_root"
    mkdir -p "$install_root/logs/mangosd"
    printf '%s\n' 'anti' > "$install_root/logs/mangosd/Anticheat.log"
    printf '%s\n' 'gm' > "$install_root/logs/mangosd/gm_critical.log"
    chmod 644 "$install_root/logs/mangosd/Anticheat.log" "$install_root/logs/mangosd/gm_critical.log"
    mkdir -p "$mock_dir"
    setup_logs_mock_bin "$mock_dir"

    CONFIG_FILE="$config_file"
    LOGS_ROTATE_CONFIG_PATH="$temp_dir/vmangos.logrotate"
    LOGS_ROTATE_STATE_PATH="$temp_dir/logrotate.state"
    LOGS_CONFIG_LOADED=""

    output=$(PATH="$mock_dir:$PATH" LOGROTATE_BIN="$mock_dir/logrotate" LOGS_TEST_LOGROTATE_LOG="$command_log" logs_rotate true 2>&1)
    perms=$(get_file_permissions "$install_root/logs/mangosd/Anticheat.log")

    assert_file_exists "$LOGS_ROTATE_CONFIG_PATH" "logs rotate installs logrotate config" || all_passed=1
    assert_equals "600" "$perms" "logs rotate hardens sensitive log permissions before rotation" || all_passed=1
    assert_true "[[ \$(cat \"$command_log\") == *'-f'* && \$(cat \"$command_log\") == *'-s $temp_dir/logrotate.state'* && \$(cat \"$command_log\") == *'$temp_dir/vmangos.logrotate'* ]]" "logs rotate invokes logrotate with force flag and configured state file" || all_passed=1
    assert_true "[[ \$output == *'Log rotation completed using'* ]]" "logs rotate reports completion" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_logs_test_config_runs_debug_validation() {
    # shellcheck source=../lib/logs.sh
    source "$LIB_DIR/logs.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir config_file install_root mock_dir command_log output
    temp_dir=$(mktemp -d)
    install_root="$temp_dir/install"
    config_file="$temp_dir/manager.conf"
    mock_dir="$temp_dir/mockbin"
    command_log="$temp_dir/logrotate.log"

    create_test_config "$config_file" "$install_root"
    mkdir -p "$install_root/logs/mangosd" "$mock_dir"
    setup_logs_mock_bin "$mock_dir"

    CONFIG_FILE="$config_file"
    LOGS_ROTATE_CONFIG_PATH="$temp_dir/vmangos.logrotate"
    LOGS_CONFIG_LOADED=""

    output=$(PATH="$mock_dir:$PATH" LOGROTATE_BIN="$mock_dir/logrotate" LOGS_TEST_LOGROTATE_LOG="$command_log" logs_test_config 2>&1)

    assert_true "[[ \$(cat \"$command_log\") == *'-d'* && \$(cat \"$command_log\") != *'-f'* ]]" "logs test-config runs logrotate in debug mode" || all_passed=1
    assert_true "[[ \$output == *'Logrotate configuration is valid'* ]]" "logs test-config reports successful validation" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_cli_logs_status_json_with_generated_config() {
    local all_passed=0
    local temp_dir config_file install_root mock_dir output compact_output
    temp_dir=$(mktemp -d)
    install_root="$temp_dir/install"
    config_file="$temp_dir/manager.conf"
    mock_dir="$temp_dir/mockbin"

    create_test_config "$config_file" "$install_root"
    mkdir -p "$install_root/logs/mangosd" "$mock_dir"
    printf '%s\n' 'server' > "$install_root/logs/mangosd/Server.log"
    printf '%s\n' 'anti' > "$install_root/logs/mangosd/Anticheat.log"
    chmod 600 "$install_root/logs/mangosd/Anticheat.log"
    setup_logs_mock_bin "$mock_dir"

    PATH="$mock_dir:$PATH" \
    MANAGER_CONFIG="$config_file" \
    VMANGOS_LOGROTATE_CONFIG_PATH="$temp_dir/vmangos.logrotate" \
    LOGROTATE_BIN="$mock_dir/logrotate" \
    bash "$MANAGER_DIR/bin/vmangos-manager" logs test-config >/dev/null 2>&1

    output=$(PATH="$mock_dir:$PATH" MANAGER_CONFIG="$config_file" VMANGOS_LOGROTATE_CONFIG_PATH="$temp_dir/vmangos.logrotate" bash "$MANAGER_DIR/bin/vmangos-manager" logs status --format json 2>/dev/null)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'\"success\":true'* ]]" "CLI logs status json reports success" || all_passed=1
    assert_true "[[ \$compact_output == *'\"present\":true'* && \$compact_output == *'\"in_sync\":true'* ]]" "CLI logs status json reports generated config state" || all_passed=1
    assert_true "[[ \$compact_output == *'\"active_files\":2'* ]]" "CLI logs status json reports active log count" || all_passed=1
    assert_true "[[ \$compact_output == *'\"status\":\"healthy\"'* ]]" "CLI logs status json reports healthy status when config and permissions are correct" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_schedule_honor_requires_backend_command() {
    # shellcheck source=../lib/schedule.sh
    source "$LIB_DIR/schedule.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local output temp_root
    temp_root=$(mktemp -d)

    CONFIG_FILE="$temp_root/config/manager.conf"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_MAINTENANCE_TIMEZONE="UTC"
        CONFIG_MAINTENANCE_HONOR_COMMAND=""
        CONFIG_MAINTENANCE_ANNOUNCE_COMMAND=""
        CONFIG_MAINTENANCE_RESTART_WARNINGS="30,15,5,1"
        return 0
    }
    server_load_config() { return 0; }
    config_resolve_manager_root() { printf '%s/manager\n' "$temp_root"; }

    output=$(schedule_honor daily "06:00" "UTC" 2>&1 || true)
    assert_true "[[ \$output == *'Honor scheduling requires maintenance.honor_command'* ]]" "schedule honor fails closed without configured backend command" || all_passed=1

    rm -rf "$temp_root"
    return $all_passed
}

test_schedule_honor_creates_timer_and_metadata() {
    # shellcheck source=../lib/schedule.sh
    source "$LIB_DIR/schedule.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_root unit_root systemctl_log metadata_file service_file timer_file output
    temp_root=$(mktemp -d)
    unit_root="$temp_root/systemd"
    systemctl_log="$temp_root/systemctl.log"
    mkdir -p "$unit_root"

    CONFIG_FILE="$temp_root/config/manager.conf"
    SCHEDULE_UNIT_DIR="$unit_root"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_MAINTENANCE_TIMEZONE="UTC"
        CONFIG_MAINTENANCE_HONOR_COMMAND="/bin/true"
        CONFIG_MAINTENANCE_ANNOUNCE_COMMAND=""
        CONFIG_MAINTENANCE_RESTART_WARNINGS="30,15,5,1"
        return 0
    }
    server_load_config() { return 0; }
    config_resolve_manager_root() { printf '%s/manager\n' "$temp_root"; }
    schedule_systemctl() {
        printf '%s\n' "$*" >> "$systemctl_log"
        return 0
    }

    output=$(schedule_honor daily "06:00" "UTC")
    metadata_file=$(find "$temp_root/manager/state/schedules" -name '*.conf' | head -n 1)
    service_file=$(find "$unit_root" -name 'vmangos-schedule-*.service' ! -name '*warning*' | head -n 1)
    timer_file=$(find "$unit_root" -name 'vmangos-schedule-*.timer' ! -name '*warning*' | head -n 1)

    assert_file_exists "$metadata_file" "schedule honor writes metadata file" || all_passed=1
    assert_file_exists "$service_file" "schedule honor writes main service unit" || all_passed=1
    assert_file_exists "$timer_file" "schedule honor writes main timer unit" || all_passed=1
    assert_true "[[ \$(cat \"$timer_file\") == *'OnCalendar=*-*-* 06:00:00 UTC'* ]]" "schedule honor writes expected OnCalendar expression" || all_passed=1
    assert_true "[[ \$(cat \"$metadata_file\") == *'job_type = honor'* ]]" "schedule honor metadata records job type" || all_passed=1
    assert_true "[[ \$output == *'Scheduled honor job'* ]]" "schedule honor reports created job id" || all_passed=1

    rm -rf "$temp_root"
    return $all_passed
}

test_schedule_restart_creates_warning_timers() {
    # shellcheck source=../lib/schedule.sh
    source "$LIB_DIR/schedule.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_root unit_root warning_timer metadata_file
    temp_root=$(mktemp -d)
    unit_root="$temp_root/systemd"
    mkdir -p "$unit_root"

    CONFIG_FILE="$temp_root/config/manager.conf"
    SCHEDULE_UNIT_DIR="$unit_root"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_MAINTENANCE_TIMEZONE="UTC"
        CONFIG_MAINTENANCE_HONOR_COMMAND="/bin/true"
        CONFIG_MAINTENANCE_ANNOUNCE_COMMAND=""
        CONFIG_MAINTENANCE_RESTART_WARNINGS="30,15,5,1"
        return 0
    }
    server_load_config() { return 0; }
    config_resolve_manager_root() { printf '%s/manager\n' "$temp_root"; }
    schedule_systemctl() { return 0; }

    schedule_restart_create weekly "Sun 04:00" "UTC" "30,15,5,1" "Weekly maintenance" >/dev/null

    metadata_file=$(find "$temp_root/manager/state/schedules" -name '*.conf' | head -n 1)
    warning_timer="$unit_root/$(basename "$(find "$unit_root" -name '*warning-30.timer' | head -n 1)")"

    assert_file_exists "$metadata_file" "schedule restart writes metadata file" || all_passed=1
    assert_equals "4" "$(find "$unit_root" -name '*warning-*.timer' | wc -l | awk '{print $1}')" "schedule restart creates one warning timer per configured warning" || all_passed=1
    assert_true "[[ \$(cat \"$warning_timer\") == *'OnCalendar=Sun *-*-* 03:30:00 UTC'* ]]" "schedule restart warning timer uses shifted OnCalendar" || all_passed=1
    assert_true "[[ \$(cat \"$metadata_file\") == *'warnings = 30,15,5,1'* ]]" "schedule restart metadata records warning intervals" || all_passed=1
    assert_true "[[ \$(cat \"$metadata_file\") == *'announce_message = Weekly maintenance'* ]]" "schedule restart metadata records announcement message" || all_passed=1

    rm -rf "$temp_root"
    return $all_passed
}

test_schedule_list_json_includes_timezone() {
    # shellcheck source=../lib/schedule.sh
    source "$LIB_DIR/schedule.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_root unit_root output compact_output
    temp_root=$(mktemp -d)
    unit_root="$temp_root/systemd"
    mkdir -p "$unit_root"

    CONFIG_FILE="$temp_root/config/manager.conf"
    SCHEDULE_UNIT_DIR="$unit_root"
    OUTPUT_FORMAT="text"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_MAINTENANCE_TIMEZONE="UTC"
        CONFIG_MAINTENANCE_HONOR_COMMAND="/bin/true"
        CONFIG_MAINTENANCE_ANNOUNCE_COMMAND=""
        CONFIG_MAINTENANCE_RESTART_WARNINGS="30,15,5,1"
        return 0
    }
    server_load_config() { return 0; }
    config_resolve_manager_root() { printf '%s/manager\n' "$temp_root"; }
    schedule_systemctl() {
        case "$1" in
            show)
                printf 'NextElapseUSecRealtime=Sun 2026-04-19 04:00:00 UTC\n'
                ;;
            *)
                return 0
                ;;
        esac
    }

    schedule_restart_create weekly "Sun 04:00" "UTC" "30,15,5,1" "Weekly maintenance" >/dev/null
    OUTPUT_FORMAT="json"
    output=$(schedule_list)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')
    assert_true "[[ \$compact_output == *'\"job_type\":\"restart\"'* ]]" "schedule list json includes restart job type" || all_passed=1
    assert_true "[[ \$compact_output == *'\"timezone\":\"UTC\"'* ]]" "schedule list json includes timezone field" || all_passed=1
    assert_true "[[ \$compact_output == *'\"next_run\":\"Sun2026-04-1904:00:00UTC\"'* ]]" "schedule list json includes next-run timer metadata" || all_passed=1

    rm -rf "$temp_root"
    OUTPUT_FORMAT="text"
    return $all_passed
}

test_schedule_cancel_removes_timer_and_metadata() {
    # shellcheck source=../lib/schedule.sh
    source "$LIB_DIR/schedule.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_root unit_root job_id metadata_file systemctl_log
    temp_root=$(mktemp -d)
    unit_root="$temp_root/systemd"
    systemctl_log="$temp_root/systemctl.log"
    mkdir -p "$unit_root"

    CONFIG_FILE="$temp_root/config/manager.conf"
    SCHEDULE_UNIT_DIR="$unit_root"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_MAINTENANCE_TIMEZONE="UTC"
        CONFIG_MAINTENANCE_HONOR_COMMAND="/bin/true"
        CONFIG_MAINTENANCE_ANNOUNCE_COMMAND=""
        CONFIG_MAINTENANCE_RESTART_WARNINGS="30,15,5,1"
        return 0
    }
    server_load_config() { return 0; }
    config_resolve_manager_root() { printf '%s/manager\n' "$temp_root"; }
    schedule_systemctl() {
        printf '%s\n' "$*" >> "$systemctl_log"
        return 0
    }

    schedule_restart_create daily "04:00" "UTC" "15,5" "Daily restart" >/dev/null
    metadata_file=$(find "$temp_root/manager/state/schedules" -name '*.conf' | head -n 1)
    job_id=$(basename "$metadata_file" .conf)

    schedule_cancel "$job_id" >/dev/null

    assert_true "[[ ! -f \"$metadata_file\" ]]" "schedule cancel removes metadata file" || all_passed=1
    assert_equals "0" "$(find "$unit_root" -type f | wc -l | awk '{print $1}')" "schedule cancel removes generated unit files" || all_passed=1
    assert_true "[[ \$(cat \"$systemctl_log\") == *'disable vmangos-schedule-'* ]]" "schedule cancel disables timer units before removal" || all_passed=1

    rm -rf "$temp_root"
    return $all_passed
}

test_schedule_warns_on_overlap() {
    # shellcheck source=../lib/schedule.sh
    source "$LIB_DIR/schedule.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_root unit_root output
    temp_root=$(mktemp -d)
    unit_root="$temp_root/systemd"
    mkdir -p "$unit_root"

    CONFIG_FILE="$temp_root/config/manager.conf"
    SCHEDULE_UNIT_DIR="$unit_root"
    check_root() { :; }
    config_load() {
        CONFIG_SERVER_INSTALL_ROOT="/opt/mangos"
        CONFIG_MAINTENANCE_TIMEZONE="UTC"
        CONFIG_MAINTENANCE_HONOR_COMMAND="/bin/true"
        CONFIG_MAINTENANCE_ANNOUNCE_COMMAND=""
        CONFIG_MAINTENANCE_RESTART_WARNINGS="30,15,5,1"
        return 0
    }
    server_load_config() { return 0; }
    config_resolve_manager_root() { printf '%s/manager\n' "$temp_root"; }
    schedule_systemctl() { return 0; }

    schedule_restart_create daily "04:00" "UTC" "15,5" "First restart" >/dev/null
    output=$(schedule_restart_create daily "04:10" "UTC" "15,5" "Second restart" 2>&1)
    assert_true "[[ \$output == *'Potential schedule conflict'* ]]" "schedule restart warns on overlapping schedules" || all_passed=1

    rm -rf "$temp_root"
    return $all_passed
}

# ============================================================================
# BACKUP TESTS
# ============================================================================

test_backup_metadata_generation() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1
    
    local all_passed=0
    local temp_dir; temp_dir=$(mktemp -d)
    
    # Create mock metadata
    local metadata_file="$temp_dir/test_backup.json"
    cat > "$metadata_file" << 'JSONEOF'
{
  "timestamp": "2026-04-13T10:00:00+00:00",
  "file": "vmangos_backup_20260413_100000.sql.gz",
  "basename": "vmangos_backup_20260413_100000",
  "size_bytes": 104857600,
  "checksum_sha256": "aabbccdd11223344556677889900aabbccdd11223344556677889900aabbccdd",
  "databases": ["auth","characters","world","logs"]
}
JSONEOF

    # Test metadata structure
    local timestamp
    timestamp=$(metadata_json_get "$metadata_file" "timestamp")
    assert_equals "2026-04-13T10:00:00+00:00" "$timestamp" "metadata: timestamp field"
    
    local size
    size=$(metadata_json_get "$metadata_file" "size_bytes")
    assert_equals "104857600" "$size" "metadata: size_bytes field"
    
    local db_count
    db_count=$(metadata_json_array_count "$metadata_file" "databases")
    assert_equals "4" "$db_count" "metadata: databases count"
    
    rm -rf "$temp_dir"
    return $all_passed
}

test_backup_schedule_parsing() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1
    
    local all_passed=0
    
    # Test valid daily format
    if schedule_parse_daily "04:00" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} schedule_parse_daily accepts valid 04:00"
    else
        echo -e "${RED}✗${NC} schedule_parse_daily rejected valid 04:00"
        all_passed=1
    fi
    
    # Test invalid daily format
    if ! schedule_parse_daily "25:00" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} schedule_parse_daily rejects invalid 25:00"
    else
        echo -e "${RED}✗${NC} schedule_parse_daily accepted invalid 25:00"
        all_passed=1
    fi
    
    # Test valid weekly format
    if schedule_parse_weekly "Sun 04:00" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} schedule_parse_weekly accepts valid 'Sun 04:00'"
    else
        echo -e "${RED}✗${NC} schedule_parse_weekly rejected valid 'Sun 04:00'"
        all_passed=1
    fi
    
    # Test invalid day
    if ! schedule_parse_weekly "Someday 04:00" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} schedule_parse_weekly rejects invalid day"
    else
        echo -e "${RED}✗${NC} schedule_parse_weekly accepted invalid day"
        all_passed=1
    fi
    
    return $all_passed
}

test_backup_filename_generation() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1
    
    local all_passed=0
    
    local filename
    filename=$(backup_generate_filename)
    
    # Check format: vmangos_backup_YYYYMMDD_HHMMSS
    if [[ "$filename" =~ ^vmangos_backup_[0-9]{8}_[0-9]{6}$ ]]; then
        echo -e "${GREEN}✓${NC} backup_generate_filename produces valid format"
    else
        echo -e "${RED}✗${NC} backup_generate_filename invalid format: $filename"
        all_passed=1
    fi
    
    return $all_passed
}

test_backup_service_unit_generation() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local service_content timer_content

    service_content=$(backup_service_unit_content "VMANGOS Daily Backup" "/opt/mangos/manager/bin/vmangos-manager")
    timer_content=$(backup_timer_unit_content "Run VMANGOS backup daily at 04:00" "*-*-* 04:00:00")

    assert_true "[[ \$service_content == *'ExecStart=/opt/mangos/manager/bin/vmangos-manager backup now --verify'* ]]" "service unit contains resolved ExecStart" || all_passed=1
    assert_true "[[ \$service_content != *'MANAGER_BIN'* ]]" "service unit does not contain unresolved MANAGER_BIN token" || all_passed=1
    assert_true "[[ \$timer_content == *'OnCalendar=*-*-* 04:00:00'* ]]" "timer unit contains expected OnCalendar value" || all_passed=1

    return $all_passed
}

test_backup_resolve_manager_bin_from_config_path() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir config_file expected_bin resolved_bin
    temp_dir=$(mktemp -d)
    mkdir -p "$temp_dir/custom-manager/config" "$temp_dir/custom-manager/bin"
    config_file="$temp_dir/custom-manager/config/manager.conf"
    expected_bin="$temp_dir/custom-manager/bin/vmangos-manager"
    printf '%s\n' '[database]' > "$config_file"
    chmod 600 "$config_file"
    printf '%s\n' '#!/usr/bin/env bash' > "$expected_bin"
    chmod +x "$expected_bin"

    CONFIG_FILE="$config_file"
    MANAGER_BIN=""
    resolved_bin=$(backup_resolve_manager_bin)
    assert_equals "$expected_bin" "$resolved_bin" "backup_resolve_manager_bin follows manager root inferred from config path" || all_passed=1

    rm -rf "$temp_dir"
    return $all_passed
}

test_backup_clean_age_retention() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir
    temp_dir=$(mktemp -d)

    BACKUP_CONFIG_LOADED=1
    BACKUP_DIR="$temp_dir"
    BACKUP_RETENTION_DAYS=30

    cat > "$temp_dir/old.json" << 'EOF'
{"timestamp":"2026-01-01T00:00:00+00:00","basename":"old"}
EOF
    cat > "$temp_dir/recent.json" << 'EOF'
{"timestamp":"2026-04-10T00:00:00+00:00","basename":"recent"}
EOF
    : > "$temp_dir/old.sql.gz"
    : > "$temp_dir/recent.sql.gz"

    backup_clean >/dev/null

    assert_true "[[ ! -f \"$temp_dir/old.json\" && ! -f \"$temp_dir/old.sql.gz\" ]]" "age-based cleanup removes old backup artifacts" || all_passed=1
    assert_true "[[ -f \"$temp_dir/recent.json\" && -f \"$temp_dir/recent.sql.gz\" ]]" "age-based cleanup preserves recent backup artifacts" || all_passed=1

    rm -rf "$temp_dir"
    BACKUP_CONFIG_LOADED=""
    BACKUP_DIR=""
    BACKUP_RETENTION_DAYS=""

    return $all_passed
}

test_backup_verify_requires_metadata() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
        SKIP_ROOT_INIT=1

        local all_passed=0
        local temp_dir dump_file
        temp_dir=$(mktemp -d)
        dump_file="$temp_dir/test.sql.gz"

        printf '%s\n' '-- MySQL dump 10.13' | gzip > "$dump_file"

        if ! backup_verify "$dump_file" 1 >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} backup_verify fails closed when metadata is missing"
        else
                echo -e "${RED}✗${NC} backup_verify accepted a dump without metadata"
                all_passed=1
        fi

        rm -rf "$temp_dir"
        return $all_passed
}

test_backup_verify_level2_db_scoped_tables() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
        SKIP_ROOT_INIT=1

        local all_passed=0
        local temp_dir dump_file metadata_file checksum
        temp_dir=$(mktemp -d)
        dump_file="$temp_dir/test.sql.gz"
        metadata_file="$temp_dir/test.json"

        cat > "$temp_dir/test.sql" <<'EOF'
    -- MariaDB dump 10.19
-- Current Database: `auth`
CREATE TABLE `account` (
    `id` int
);
CREATE TABLE `account_banned` (
    `id` int
);
CREATE TABLE `realmcharacters` (
    `id` int
);
-- Current Database: `characters`
CREATE TABLE `characters` (
    `id` int
);
CREATE TABLE `character_inventory` (
    `id` int
);
CREATE TABLE `character_homebind` (
    `id` int
);
-- Current Database: `mangos`
CREATE TABLE `creature` (
    `id` int
);
CREATE TABLE `gameobject` (
    `id` int
);
CREATE TABLE `item_template` (
    `id` int
);
CREATE TABLE `quest_template` (
    `id` int
);
-- Current Database: `logs`
CREATE TABLE `logs_player` (
    `id` int
);
EOF

        gzip -c "$temp_dir/test.sql" > "$dump_file"
        checksum=$(sha256_file "$dump_file")
        cat > "$metadata_file" << EOF
{"checksum_sha256":"$checksum"}
EOF

        AUTH_DB="auth"
        CONFIG_DATABASE_CHARACTERS_DB="characters"
        CONFIG_DATABASE_WORLD_DB="mangos"
        CONFIG_DATABASE_LOGS_DB="logs"

        if verify_level_2 "$dump_file" >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} verify_level_2 validates required tables within the correct database sections"
        else
                echo -e "${RED}✗${NC} verify_level_2 failed on a valid multi-database dump"
                all_passed=1
        fi

        rm -rf "$temp_dir"
        return $all_passed
}

test_backup_restore_dry_run_non_mutating() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir dump_file metadata_file checksum output
    local stop_called=0 start_called=0 verify_called=0
    temp_dir=$(mktemp -d)
    dump_file="$temp_dir/test.sql.gz"
    metadata_file="$temp_dir/test.json"

    printf '%s\n' '-- MySQL dump 10.13' | gzip > "$dump_file"
    checksum=$(sha256_file "$dump_file")
    cat > "$metadata_file" << EOF
{"timestamp":"2026-04-13T10:00:00+00:00","size_bytes":1,"databases":["auth"],"checksum_sha256":"$checksum"}
EOF

    BACKUP_CONFIG_LOADED=1
    SERVER_CONFIG_LOADED=1
    BACKUP_DATABASES=("auth" "characters")

    server_stop() { stop_called=1; }
    server_start() { start_called=1; }
    backup_verify() { verify_called=1; }

    output=$(backup_restore "$dump_file" true 2>/dev/null)

    assert_equals "0" "$stop_called" "restore dry-run does not stop services" || all_passed=1
    assert_equals "0" "$start_called" "restore dry-run does not start services" || all_passed=1
    assert_equals "0" "$verify_called" "restore dry-run does not run verification" || all_passed=1
    assert_true "[[ \$output == *'RESTORE DRY-RUN'* ]]" "restore dry-run prints plan output" || all_passed=1

    rm -rf "$temp_dir"
    BACKUP_CONFIG_LOADED=""
    SERVER_CONFIG_LOADED=""

    return $all_passed
}

test_backup_verify_loads_config_for_level2() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    local temp_dir dump_file metadata_file checksum
    local backup_loaded=0 server_loaded=0
    temp_dir=$(mktemp -d)
    dump_file="$temp_dir/test.sql.gz"
    metadata_file="$temp_dir/test.json"

    printf '%s\n' '-- MariaDB dump 10.19' | gzip > "$dump_file"
    checksum=$(sha256_file "$dump_file")
    cat > "$metadata_file" << EOF
{"checksum_sha256":"$checksum"}
EOF

    backup_load_config() {
        backup_loaded=1
        BACKUP_CONFIG_LOADED=1
        CONFIG_DATABASE_AUTH_DB="auth"
        CONFIG_DATABASE_CHARACTERS_DB="characters"
        CONFIG_DATABASE_WORLD_DB="world"
        CONFIG_DATABASE_LOGS_DB="logs"
        return 0
    }

    server_load_config() {
        server_loaded=1
        SERVER_CONFIG_LOADED=1
        AUTH_DB="auth"
        return 0
    }

    verify_level_1() {
        return 0
    }

    verify_level_2() {
        [[ "$backup_loaded" -eq 1 && "$server_loaded" -eq 1 && "$AUTH_DB" == "auth" && "$CONFIG_DATABASE_WORLD_DB" == "world" ]]
    }

    if backup_verify "$dump_file" 2 >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} backup_verify loads config before Level 2 verification"
    else
        echo -e "${RED}✗${NC} backup_verify did not load config before Level 2 verification"
        all_passed=1
    fi

    rm -rf "$temp_dir"
    BACKUP_CONFIG_LOADED=""
    SERVER_CONFIG_LOADED=""

    return $all_passed
}

test_backup_restore_requires_explicit_credentials() {
    # shellcheck source=../lib/backup.sh
    source "$LIB_DIR/backup.sh"
    SKIP_ROOT_INIT=1

    local all_passed=0
    unset MYSQL_RESTORE_DEFAULTS_FILE MYSQL_RESTORE_PASSWORD MYSQL_RESTORE_USER MYSQL_ROOT_PASSWORD

    DB_HOST="127.0.0.1"
    DB_PORT="3306"

    if ! backup_restore_defaults_file >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} restore defaults helper rejects missing privileged credentials"
    else
        echo -e "${RED}✗${NC} restore defaults helper accepted missing privileged credentials"
        all_passed=1
    fi

    return $all_passed
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo "========================================"
    echo "VMANGOS Manager Test Suite"
    echo "========================================"
    
    run_test "Common: JSON utilities" test_common_json
    run_test "Config: Loading" test_config_loading
    run_test "Config: Manager root resolution" test_config_resolve_manager_root
    run_test "Config: Creation" test_config_create
    run_test "Config: Detect installer layout" test_config_detect_installer_layout
    run_test "Config: Detect custom path JSON" test_config_detect_custom_path_json
    run_test "Config: Detect multiple candidates" test_config_detect_reports_multiple_candidates
    run_test "CLI: Parsing" test_cli_parsing
    run_test "Account: Validation" test_account_validation
    run_test "Account: Hash vector" test_account_hash_known_vector
    run_test "Account: Password file checks" test_account_password_file_checks
    run_test "Account: Wrong owner rejected" test_account_password_file_wrong_owner_rejected
    run_test "Account: Sudo owner accepted" test_account_password_file_accepts_sudo_owner
    run_test "Account: Password env handling" test_account_password_env_clears_variable
    run_test "Account: Injection blocked" test_account_create_blocks_injection
    run_test "Account: Operation queries" test_account_operations_generate_expected_queries
    run_test "Account: Env not forwarded" test_account_password_env_not_forwarded_to_python
    run_test "Account: List JSON" test_account_list_json_output
    run_test "CLI: Account rejects positional password" test_cli_account_rejects_positional_password
    run_test "Update: Text output" test_update_check_text_output
    run_test "Update: JSON output" test_update_check_json_output
    run_test "Update: Source repo preferred" test_update_check_prefers_configured_source_repo
    run_test "Update: Missing repo" test_update_check_requires_git_repo
    run_test "Update: Unsafe source repo" test_update_check_reports_unsafe_source_repo
    run_test "Update: Plan text output" test_update_plan_text_output
    run_test "Update: Plan JSON output" test_update_plan_json_output
    run_test "Update: Apply workflow" test_update_apply_runs_backup_and_rebuild_workflow
    run_test "Update: Apply rejects dirty tree" test_update_apply_rejects_dirty_source_tree
    run_test "Packaging: Install and uninstall" test_make_install_and_uninstall_targets
    run_test "Dashboard: Bootstrap and launch" test_dashboard_bootstrap_and_run
    run_test "Dashboard: Snapshot aggregation" test_dashboard_snapshot_json_aggregates_backend
    run_test "Dashboard: Action requests" test_dashboard_action_request_builder
    run_test "Dashboard: Render helpers" test_dashboard_render_helpers
    run_test "Server: Player count fallback" test_server_player_count_fallback
    run_test "Server: Interval validation" test_server_validate_interval
    run_test "Server: Start fails on DB preflight" test_server_start_fails_when_database_unreachable
    run_test "Server: Start order" test_server_start_orders_services
    run_test "Server: Restart timeout wiring" test_server_restart_passes_timeout_to_stop_and_start
    run_test "Server: Stop order" test_server_stop_orders_services
    run_test "Server: Graceful stop timeout" test_server_stop_respects_timeout_without_force
    run_test "Server: Crash loop detection" test_server_crash_loop_detection
    run_test "CLI: Status JSON" test_cli_status_json_with_mocks
    run_test "CLI: Status JSON alerts/iostat fallback" test_cli_status_json_degrades_without_iostat_and_raises_alerts
    run_test "CLI: Status watch" test_cli_status_watch_single_iteration
    run_test "CLI: Watch rejects JSON" test_cli_status_watch_rejects_json
    run_test "Logs: Config rendering" test_logs_render_config_includes_issue17_policy
    run_test "Logs: Status JSON" test_logs_status_json_reports_counts_and_permission_drift
    run_test "Logs: Rotate force" test_logs_rotate_force_runs_logrotate_and_hardens_permissions
    run_test "Logs: Test config" test_logs_test_config_runs_debug_validation
    run_test "CLI: Logs status JSON" test_cli_logs_status_json_with_generated_config
    run_test "Schedule: Honor requires backend" test_schedule_honor_requires_backend_command
    run_test "Schedule: Honor create" test_schedule_honor_creates_timer_and_metadata
    run_test "Schedule: Restart warnings" test_schedule_restart_creates_warning_timers
    run_test "Schedule: List JSON" test_schedule_list_json_includes_timezone
    run_test "Schedule: Cancel" test_schedule_cancel_removes_timer_and_metadata
    run_test "Schedule: Conflict warning" test_schedule_warns_on_overlap
    run_test "Backup: Metadata generation" test_backup_metadata_generation
    run_test "Backup: Schedule parsing" test_backup_schedule_parsing
    run_test "Backup: Filename generation" test_backup_filename_generation
    run_test "Backup: Service unit generation" test_backup_service_unit_generation
    run_test "Backup: Manager bin resolution" test_backup_resolve_manager_bin_from_config_path
    run_test "Backup: Age retention cleanup" test_backup_clean_age_retention
    run_test "Backup: Metadata required for verify" test_backup_verify_requires_metadata
    run_test "Backup: Level 2 DB-aware verify" test_backup_verify_level2_db_scoped_tables
    run_test "Backup: Verify loads config for Level 2" test_backup_verify_loads_config_for_level2
    run_test "Backup: Restore dry-run non-mutating" test_backup_restore_dry_run_non_mutating
    run_test "Backup: Restore requires explicit creds" test_backup_restore_requires_explicit_credentials
    
    echo ""
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo "Total:  $TESTS_RUN"
    echo -e "${GREEN}Passed:${NC} $TESTS_PASSED"
    echo -e "${RED}Failed:${NC} $TESTS_FAILED"
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

main "$@"
