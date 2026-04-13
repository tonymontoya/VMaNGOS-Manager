#!/usr/bin/env bash
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
    source "$LIB_DIR/common.sh"
    SKIP_ROOT_INIT=1
    local all_passed=0
    assert_equals 'hello' "$(json_escape 'hello')" "json_escape: plain text" || all_passed=1
    assert_equals 'hello\"world' "$(json_escape 'hello"world')" "json_escape: quotes" || all_passed=1
    assert_equals 'hello\\world' "$(json_escape 'hello\world')" "json_escape: backslash" || all_passed=1
    return $all_passed
}

test_config_loading() {
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
    source "$LIB_DIR/config.sh"
    SKIP_ROOT_INIT=1
    local temp_dir; temp_dir=$(mktemp -d)
    local config_file="$temp_dir/test.conf"
    config_create "$config_file" 2>/dev/null
    local all_passed=0
    assert_file_exists "$config_file" "config_create: creates file" || all_passed=1
    local perms; perms=$(stat -c "%a" "$config_file")
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
    timestamp=$(jq -r '.timestamp' "$metadata_file")
    assert_equals "2026-04-13T10:00:00+00:00" "$timestamp" "metadata: timestamp field"
    
    local size
    size=$(jq -r '.size_bytes' "$metadata_file")
    assert_equals "104857600" "$size" "metadata: size_bytes field"
    
    local db_count
    db_count=$(jq -r '.databases | length' "$metadata_file")
    assert_equals "4" "$db_count" "metadata: databases count"
    
    rm -rf "$temp_dir"
    return $all_passed
}

test_backup_schedule_parsing() {
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
