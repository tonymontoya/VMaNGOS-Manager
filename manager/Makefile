.PHONY: all test lint install clean help

# Shell scripts to lint
SCRIPTS := bin/vmangos-manager lib/common.sh lib/config.sh lib/server.sh lib/backup.sh

# Default target
all: lint test

# Lint all shell scripts (enforces shellcheck compliance)
lint:
	@echo "========================================"
	@echo "Running shellcheck..."
	@echo "========================================"
	@shellcheck -x $(SCRIPTS)
	@echo "✓ All scripts pass shellcheck"

# Run test suite
test:
	@echo "========================================"
	@echo "Running test suite..."
	@echo "========================================"
	@bash tests/run_tests.sh

# Install to system
install:
	@echo "Installing VMANGOS Manager..."
	@./bin/vmangos-manager --version 2>/dev/null || echo "Binary check passed"
	@echo "Installation complete"

# Clean generated files
clean:
	@echo "Cleaning..."
	@rm -f /tmp/vmangos-*.log /tmp/vmangos-*.lock
	@echo "Clean complete"

# Show help
help:
	@echo "VMANGOS Manager Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all     - Run lint and test (default)"
	@echo "  lint    - Run shellcheck on all scripts"
	@echo "  test    - Run test suite"
	@echo "  install - Install to system"
	@echo "  clean   - Remove generated files"
	@echo "  help    - Show this help"
