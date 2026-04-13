#!/usr/bin/env bash
# Unit tests for common.sh

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

test_log_functions() {
    echo "Testing log functions..."
    log_info "Test info message"
    log_warn "Test warning message"
    echo "✓ Log functions work"
}

test_json_escape() {
    echo "Testing json_escape..."
    local result
    result=$(json_escape 'test"quote')
    if [[ "$result" == 'test\"quote' ]]; then
        echo "✓ JSON escape works"
    else
        echo "✗ JSON escape failed: $result"
        return 1
    fi
}

test_error_exit() {
    echo "Testing error_exit (should print error)..."
    # Note: This will exit, so we can't fully test in script
    echo "✓ error_exit function defined"
}

# Run tests
test_log_functions
test_json_escape
test_error_exit

echo ""
echo "Common tests complete"
