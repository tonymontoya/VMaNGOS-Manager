#!/bin/bash
# =============================================================================
# Unit Tests for lib/config.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
source "$SCRIPT_DIR/../../lib/config.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    local test_func="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Testing $test_name... "
    
    if $test_func; then
        echo "✅ PASS"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "❌ FAIL"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Create test config file
setup_test_config() {
    cat > /tmp/test_config_$$.ini << 'EOF'
# Test config file
[database]
host = localhost
port = 3306
user = mangos
password = secret123

[backup]
enabled = true
retention_days = 7
path = /opt/mangos/backups

[server]
max_players = 1000
motd = "Welcome to VMANGOS!"
EOF
}

cleanup_test_config() {
    rm -f /tmp/test_config_$$.ini
}

# =============================================================================
# config_parse_ini Tests
# =============================================================================

test_parse_ini_reads_sections() {
    setup_test_config
    config_parse_ini /tmp/test_config_$$.ini "CONFIG"
    local result=0
    [[ "${CONFIG_database_host:-}" == "localhost" ]] || result=1
    [[ "${CONFIG_database_port:-}" == "3306" ]] || result=1
    [[ "${CONFIG_backup_enabled:-}" == "true" ]] || result=1
    cleanup_test_config
    return $result
}

test_parse_ini_handles_quotes() {
    setup_test_config
    config_parse_ini /tmp/test_config_$$.ini "CONFIG"
    local result=0
    [[ "${CONFIG_server_motd:-}" == 'Welcome to VMANGOS!' ]] || result=1
    cleanup_test_config
    return $result
}

test_parse_ini_missing_file() {
    (config_parse_ini /tmp/nonexistent_config_$$.ini 2>/dev/null)
    local exit_code=$?
    [[ $exit_code -ne 0 ]]
}

# =============================================================================
# config_get Tests
# =============================================================================

test_config_get_existing() {
    setup_test_config
    config_parse_ini /tmp/test_config_$$.ini "CONFIG"
    local result
    result=$(config_get "database_host")
    cleanup_test_config
    [[ "$result" == "localhost" ]]
}

test_config_get_with_default() {
    setup_test_config
    config_parse_ini /tmp/test_config_$$.ini "CONFIG"
    local result
    result=$(config_get "nonexistent_key" "default_value")
    cleanup_test_config
    [[ "$result" == "default_value" ]]
}

# =============================================================================
# parse_db_connection_string Tests
# =============================================================================

test_parse_db_connection() {
    local test_conn="127.0.0.1;3306;mangos;secret;world"
    parse_db_connection_string "$test_conn"
    local result=0
    [[ "$DB_HOST" == "127.0.0.1" ]] || result=1
    [[ "$DB_PORT" == "3306" ]] || result=1
    [[ "$DB_USER" == "mangos" ]] || result=1
    [[ "$DB_PASS" == "secret" ]] || result=1
    [[ "$DB_NAME" == "world" ]] || result=1
    return $result
}

# =============================================================================
# Run All Tests
# =============================================================================

echo "=================================="
echo "Unit Tests: lib/config.sh"
echo "=================================="
echo ""

run_test "parse_ini reads sections" test_parse_ini_reads_sections
run_test "parse_ini handles quotes" test_parse_ini_handles_quotes
run_test "parse_ini fails on missing file" test_parse_ini_missing_file

echo ""

run_test "config_get returns existing value" test_config_get_existing
run_test "config_get returns default for missing" test_config_get_with_default

echo ""

run_test "parse_db_connection_string extracts all fields" test_parse_db_connection

echo ""
echo "=================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
