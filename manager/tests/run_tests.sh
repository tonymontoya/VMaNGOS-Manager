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
    run_test "Config: Creation" test_config_create
    run_test "CLI: Parsing" test_cli_parsing
    run_test "Backup: Metadata generation" test_backup_metadata_generation
    run_test "Backup: Schedule parsing" test_backup_schedule_parsing
    run_test "Backup: Filename generation" test_backup_filename_generation
    run_test "Backup: Service unit generation" test_backup_service_unit_generation
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
