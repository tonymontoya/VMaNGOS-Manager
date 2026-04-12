#!/bin/bash
# =============================================================================
# Unit Tests for lib/common.sh
# =============================================================================

# Source the library
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
    [[ "$result" == "TestUser123" ]]
}

test_validate_username_too_short() {
    # Test that short username fails - run in subshell to catch exit
    (validate_username "a" 2>/dev/null)
    local exit_code=$?
    [[ $exit_code -ne 0 ]]
}

test_validate_username_too_long() {
    (validate_username "thisusernameiswaytoolongtobevalid" 2>/dev/null)
    local exit_code=$?
    [[ $exit_code -ne 0 ]]
}

test_validate_username_invalid_chars() {
    (validate_username "user@name" 2>/dev/null)
    local exit_code=$?
    [[ $exit_code -ne 0 ]]
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

test_validate_gm_level_invalid() {
    (validate_gm_level "4" 2>/dev/null)
    local exit_code=$?
    [[ $exit_code -ne 0 ]]
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
run_test "validate_gm_level rejects invalid" test_validate_gm_level_invalid

echo ""
echo "=================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
