#!/bin/bash
# =============================================================================
# Unit Tests for lib/common.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test runner
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

# =============================================================================
# json_escape Tests
# =============================================================================

test_json_escape_quotes() {
    local result
    result=$(json_escape 'test with "quotes"')
    [[ "$result" == *\"* ]]
}

test_json_escape_backslashes() {
    local result
    result=$(json_escape 'path\to\file')
    [[ "$result" == *\\\\* ]]
}

test_json_escape_newlines() {
    local result
    result=$(json_escape $'line1\nline2')
    [[ "$result" == *\n* ]]
}

test_json_escape_produces_valid_json() {
    local input='test with "quotes" and \ backslashes'
    local escaped
    escaped=$(json_escape "$input")
    printf '"%s"' "$escaped" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null
}

# =============================================================================
# json_output Tests
# =============================================================================

test_json_output_success() {
    local output
    output=$(json_output true '{"test":"data"}')
    [[ "$output" == *'"success":true'* ]] && [[ "$output" == *'"data":'* ]]
}

test_json_output_error() {
    local output
    output=$(json_output false "null" "TEST_ERROR" "Something went wrong" "Try again")
    [[ "$output" == *'"success":false'* ]] && [[ "$output" == *'"code":"TEST_ERROR"'* ]]
}

test_json_output_valid_format() {
    local output
    output=$(json_output true '{"key":"value"}')
    echo "$output" | python3 -c "import sys, json; d=json.loads(sys.stdin.read()); assert 'success' in d; assert 'timestamp' in d; assert 'data' in d; assert 'error' in d" 2>/dev/null
}

# =============================================================================
# validate_username Tests
# =============================================================================

test_validate_username_valid() {
    local result
    result=$(validate_username "TestUser123")
    [[ "$result" == "TestUser123" ]] && [[ $? -eq 0 ]]
}

test_validate_username_too_short() {
    local result
    result=$(validate_username "a" 2>&1)
    [[ $? -ne 0 ]]
}

test_validate_username_too_long() {
    local result
    result=$(validate_username "thisusernameiswaytoolongtobevalid" 2>&1)
    [[ $? -ne 0 ]]
}

test_validate_username_invalid_chars() {
    local result
    result=$(validate_username "user@name" 2>&1)
    [[ $? -ne 0 ]]
}

# =============================================================================
# validate_gm_level Tests
# =============================================================================

test_validate_gm_level_valid() {
    local r1 r2
    r1=$(validate_gm_level "0")
    r2=$(validate_gm_level "3")
    [[ "$r1" == "0" && "$r2" == "3" ]]
}

test_validate_gm_level_invalid_high() {
    validate_gm_level "4" 2>/dev/null
    [[ $? -ne 0 ]]
}

test_validate_gm_level_invalid_negative() {
    validate_gm_level "-1" 2>/dev/null
    [[ $? -ne 0 ]]
}

# =============================================================================
# check_root Tests
# =============================================================================

test_check_root() {
    # This will pass if running as root, fail otherwise
    # Just verify it returns consistent results
    if [[ $EUID -eq 0 ]]; then
        check_root
        [[ $? -eq 0 ]]
    else
        check_root 2>/dev/null
        [[ $? -ne 0 ]]
    fi
}

# =============================================================================
# get_password_from_file Tests
# =============================================================================

test_get_password_from_file_mode_600() {
    local test_file="/tmp/test_pass_600_$$"
    echo "testpassword123" > "$test_file"
    chmod 600 "$test_file"
    
    local result
    result=$(get_password_from_file "$test_file")
    local exit_code=$?
    
    rm -f "$test_file"
    [[ $exit_code -eq 0 && "$result" == "testpassword123" ]]
}

test_get_password_from_file_mode_644() {
    local test_file="/tmp/test_pass_644_$$"
    echo "testpassword123" > "$test_file"
    chmod 644 "$test_file"
    
    get_password_from_file "$test_file" 2>/dev/null
    local exit_code=$?
    
    rm -f "$test_file"
    [[ $exit_code -ne 0 ]]
}

test_get_password_from_file_nonexistent() {
    get_password_from_file "/tmp/nonexistent_pass_$$" 2>/dev/null
    [[ $? -ne 0 ]]
}

test_get_password_from_file_too_short() {
    local test_file="/tmp/test_pass_short_$$"
    echo "short" > "$test_file"
    chmod 600 "$test_file"
    
    get_password_from_file "$test_file" 2>/dev/null
    local exit_code=$?
    
    rm -f "$test_file"
    [[ $exit_code -ne 0 ]]
}

# =============================================================================
# Lock Tests
# =============================================================================

test_lock_acquire_and_release() {
    local lock_file
    lock_file=$(lock_acquire "test_lock_$$" 5)
    local acquire_result=$?
    
    local release_result=0
    if [[ $acquire_result -eq 0 && -d "$lock_file" ]]; then
        lock_release "$lock_file"
        release_result=$?
    fi
    
    [[ $acquire_result -eq 0 && $release_result -eq 0 ]]
}

test_lock_prevents_double_acquire() {
    local lock_file1 lock_file2
    local result=0
    
    # First acquire should succeed
    lock_file1=$(lock_acquire "test_lock_double_$$" 2)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Second acquire with short timeout should fail
    lock_file2=$(lock_acquire "test_lock_double_$$" 1)
    if [[ $? -eq 0 ]]; then
        result=1
    fi
    
    # Cleanup
    lock_release "$lock_file1"
    [[ $result -eq 0 ]]
}

# =============================================================================
# Run All Tests
# =============================================================================

echo "=================================="
echo "Unit Tests: lib/common.sh"
echo "=================================="
echo ""

# json_escape tests
run_test "json_escape handles quotes" test_json_escape_quotes
run_test "json_escape handles backslashes" test_json_escape_backslashes
run_test "json_escape handles newlines" test_json_escape_newlines
run_test "json_escape produces valid JSON" test_json_escape_produces_valid_json

echo ""

# json_output tests
run_test "json_output success format" test_json_output_success
run_test "json_output error format" test_json_output_error
run_test "json_output valid JSON" test_json_output_valid_format

echo ""

# validate_username tests
run_test "validate_username accepts valid" test_validate_username_valid
run_test "validate_username rejects too short" test_validate_username_too_short
run_test "validate_username rejects too long" test_validate_username_too_long
run_test "validate_username rejects invalid chars" test_validate_username_invalid_chars

echo ""

# validate_gm_level tests
run_test "validate_gm_level accepts valid" test_validate_gm_level_valid
run_test "validate_gm_level rejects too high" test_validate_gm_level_invalid_high
run_test "validate_gm_level rejects negative" test_validate_gm_level_invalid_negative

echo ""

# check_root tests
run_test "check_root" test_check_root

echo ""

# get_password_from_file tests
run_test "get_password_from_file mode 600" test_get_password_from_file_mode_600
run_test "get_password_from_file rejects mode 644" test_get_password_from_file_mode_644
run_test "get_password_from_file rejects nonexistent" test_get_password_from_file_nonexistent
run_test "get_password_from_file rejects short password" test_get_password_from_file_too_short

echo ""

# Lock tests
run_test "lock acquire and release" test_lock_acquire_and_release
run_test "lock prevents double acquire" test_lock_prevents_double_acquire

echo ""
echo "=================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
