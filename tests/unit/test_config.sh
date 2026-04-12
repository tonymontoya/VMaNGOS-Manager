#!/bin/bash
# =============================================================================
# Unit Tests for lib/config.sh
# =============================================================================

set -uo pipefail

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
    local result=$?
    local checks=0
    [[ "${CONFIG_database_host:-}" == "localhost" ]] && ((checks++))
    [[ "${CONFIG_database_port:-}" == "3306" ]] && ((checks++))
    [[ "${CONFIG_backup_enabled:-}" == "true" ]] && ((checks++))
    cleanup_test_config
    [[ $result -eq 0 && $checks -eq 3 ]]
}

test_parse_ini_handles_quotes() {
    setup_test_config
    config_parse_ini /tmp/test_config_$$.ini "CONFIG"
    local result=$?
    local checks=0
    [[ "${CONFIG_server_motd:-}" == 'Welcome to VMANGOS!' ]] && ((checks++))
    cleanup_test_config
    [[ $result -eq 0 && $checks -eq 1 ]]
}

test_parse_ini_missing_file() {
    config_parse_ini "/tmp/nonexistent_config_$$" 2>/dev/null
    [[ $? -ne 0 ]]
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
# config_load Tests
# =============================================================================

test_config_load_with_defaults() {
    config_load "/tmp/nonexistent_config_$$"  # Will use defaults
    local checks=0
    [[ "${CONFIG_install_dir:-}" == "/opt/mangos" ]] && ((checks++))
    [[ "${CONFIG_db_host:-}" == "localhost" ]] && ((checks++))
    [[ $checks -eq 2 ]]
}

# =============================================================================
# parse_db_connection_string Tests
# =============================================================================

test_parse_db_connection_valid() {
    local test_conn="127.0.0.1;3306;mangos;secret;world"
    parse_db_connection_string "$test_conn"
    local result=$?
    local checks=0
    [[ "$DB_HOST" == "127.0.0.1" ]] && ((checks++))
    [[ "$DB_PORT" == "3306" ]] && ((checks++))
    [[ "$DB_USER" == "mangos" ]] && ((checks++))
    [[ "$DB_PASS" == "secret" ]] && ((checks++))
    [[ "$DB_NAME" == "world" ]] && ((checks++))
    [[ $result -eq 0 && $checks -eq 5 ]]
}

test_parse_db_connection_invalid() {
    local test_conn="invalid_format"
    parse_db_connection_string "$test_conn" 2>/dev/null
    [[ $? -ne 0 ]]
}

test_parse_db_connection_empty_fields() {
    local test_conn=";;user;pass;db"
    parse_db_connection_string "$test_conn" 2>/dev/null
    [[ $? -ne 0 ]]
}

# =============================================================================
# server_config_get Tests
# =============================================================================

test_server_config_get_missing_file() {
    server_config_get "/tmp/nonexistent" "key" 2>/dev/null
    [[ $? -ne 0 ]]
}

test_server_config_set_invalid_key() {
    # Create temp config file
    local test_file="/tmp/test_server_config_$$"
    echo "valid_key = value" > "$test_file"
    
    server_config_set "$test_file" "invalid key with spaces" "value" 2>/dev/null
    local result=$?
    
    rm -f "$test_file"
    [[ $result -ne 0 ]]
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

run_test "config_load sets defaults" test_config_load_with_defaults

echo ""

run_test "parse_db_connection_string extracts fields" test_parse_db_connection_valid
run_test "parse_db_connection_string rejects invalid" test_parse_db_connection_invalid
run_test "parse_db_connection_string rejects empty fields" test_parse_db_connection_empty_fields

echo ""

run_test "server_config_get fails on missing file" test_server_config_get_missing_file
run_test "server_config_set rejects invalid key" test_server_config_set_invalid_key

echo ""
echo "=================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
