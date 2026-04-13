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
    cat > "$config_file" << 'EOF'
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
install_root = /opt/mangos

[backup]
enabled = true
backup_dir = /tmp/vmangos-backups
retention_days = 7
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

    chmod +x "$mock_dir/systemctl" "$mock_dir/ps" "$mock_dir/mysql" "$mock_dir/df" "$mock_dir/sleep"
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

test_cli_parsing() {
    local all_passed=0
    assert_file_exists "$MANAGER_DIR/bin/vmangos-manager" "CLI binary exists" || all_passed=1
    local output
    # shellcheck disable=SC2034
    output=$(bash "$MANAGER_DIR/bin/vmangos-manager" --help 2>&1) || true
    assert_true "[[ \$output == *'VMANGOS Manager'* ]]" "CLI --help shows app name" || all_passed=1
    assert_true "[[ \$output == *'server'* ]]" "CLI --help lists server command" || all_passed=1
    assert_true "[[ \$output == *'account'* ]]" "CLI --help lists account command" || all_passed=1
    assert_true "[[ \$output == *'update'* ]]" "CLI --help lists update command" || all_passed=1
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
    assert_file_exists "$install_root/tests/run_tests.sh" "make install copies tests" || all_passed=1

    make -C "$MANAGER_DIR" uninstall DESTDIR="$temp_dir" PREFIX=/opt/mangos/manager >/dev/null

    assert_true "[[ ! -e \"$install_root/bin/vmangos-manager\" ]]" "make uninstall removes binary" || all_passed=1
    assert_true "[[ ! -e \"$install_root/lib/update.sh\" ]]" "make uninstall removes library files" || all_passed=1
    assert_true "[[ -f \"$install_root/config/manager.conf\" ]]" "make uninstall preserves config files" || all_passed=1

    rm -rf "$temp_dir"
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

test_cli_status_json_with_mocks() {
    local all_passed=0
    local temp_dir mock_dir config_file output compact_output
    temp_dir=$(mktemp -d)
    mock_dir="$temp_dir/mockbin"
    mkdir -p "$mock_dir"
    config_file="$temp_dir/manager.conf"

    create_test_config "$config_file"
    setup_status_mock_bin "$mock_dir"

    output=$(PATH="$mock_dir:$PATH" MANAGER_CONFIG="$config_file" bash "$MANAGER_DIR/bin/vmangos-manager" server status --format json 2>/dev/null)
    compact_output=$(printf '%s' "$output" | tr -d '[:space:]')

    assert_true "[[ \$compact_output == *'\"success\":true'* ]]" "CLI status json reports success" || all_passed=1
    assert_true "[[ \$compact_output == *'\"database_connectivity\":{\"ok\":true'* ]]" "CLI status json includes DB connectivity check" || all_passed=1
    assert_true "[[ \$compact_output == *'\"source\":\"auth.account.online\"'* ]]" "CLI status json records primary player-count source" || all_passed=1
    assert_true "[[ \$compact_output == *'\"available_kb\":1536000'* ]]" "CLI status json includes disk availability" || all_passed=1

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
    run_test "Update: Missing repo" test_update_check_requires_git_repo
    run_test "Packaging: Install and uninstall" test_make_install_and_uninstall_targets
    run_test "Server: Player count fallback" test_server_player_count_fallback
    run_test "Server: Interval validation" test_server_validate_interval
    run_test "Server: Start order" test_server_start_orders_services
    run_test "Server: Stop order" test_server_stop_orders_services
    run_test "CLI: Status JSON" test_cli_status_json_with_mocks
    run_test "CLI: Status watch" test_cli_status_watch_single_iteration
    run_test "CLI: Watch rejects JSON" test_cli_status_watch_rejects_json
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
