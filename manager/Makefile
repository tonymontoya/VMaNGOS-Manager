.PHONY: all test test-dashboard lint install uninstall clean help

# Shell scripts to lint (wildcards: new lib/ or tests/ scripts are covered automatically)
SCRIPTS := $(wildcard bin/*) install_manager.sh $(wildcard lib/*.sh) $(wildcard tests/*.sh)

# Python files to lint (syntax + undefined names)
PYTHON_FILES := lib/dashboard.py lib/wizard.py
RUFF_RULES := E9,F63,F7,F82

PREFIX ?= /opt/mangos/manager
DESTDIR ?=
INSTALL_ROOT := $(DESTDIR)$(PREFIX)
INSTALL_BIN_DIR := $(INSTALL_ROOT)/bin
INSTALL_LIB_DIR := $(INSTALL_ROOT)/lib
INSTALL_TEST_DIR := $(INSTALL_ROOT)/tests

# Default target
all: lint test

# Lint shell scripts (shellcheck) and Python files (ruff)
lint:
	@echo "========================================"
	@echo "Running shellcheck..."
	@echo "========================================"
	@shellcheck -x $(SCRIPTS)
	@echo "✓ All scripts pass shellcheck"
	@echo "========================================"
	@echo "Running ruff ($(RUFF_RULES)) on Python files..."
	@echo "========================================"
	@ruff check --select $(RUFF_RULES) $(PYTHON_FILES)
	@echo "✓ Python lint clean"

# Run test suite
test:
	@echo "========================================"
	@echo "Running test suite..."
	@echo "========================================"
	@bash tests/run_tests.sh

# Run the Textual dashboard + wizard pilot tests (needs textual + pytest; CI
# installs them from dashboard-requirements.txt)
test-dashboard:
	@echo "========================================"
	@echo "Running Textual pilot tests..."
	@echo "========================================"
	@python3 -m pytest tests/test_dashboard.py tests/test_wizard.py -q
	@echo "✓ Textual pilot tests passed"

# Install to system
install:
	@echo "Installing VMANGOS Manager into $(INSTALL_ROOT)..."
	@install -d "$(INSTALL_BIN_DIR)" "$(INSTALL_LIB_DIR)" "$(INSTALL_TEST_DIR)"
	@install -m 755 bin/vmangos-manager "$(INSTALL_BIN_DIR)/vmangos-manager"
	@install -m 644 lib/*.sh "$(INSTALL_LIB_DIR)/"
	@install -m 644 lib/*.py "$(INSTALL_LIB_DIR)/" 2>/dev/null || true
	@install -m 644 tests/*.sh "$(INSTALL_TEST_DIR)/"
	@install -m 644 Makefile "$(INSTALL_ROOT)/Makefile"
	@install -m 644 dashboard-requirements.txt "$(INSTALL_ROOT)/dashboard-requirements.txt"
	@echo "Installation complete"

# Uninstall from system without removing config/
uninstall:
	@echo "Removing VMANGOS Manager from $(INSTALL_ROOT)..."
	@rm -f "$(INSTALL_BIN_DIR)/vmangos-manager"
	@rm -f "$(INSTALL_LIB_DIR)"/*.sh
	@rm -f "$(INSTALL_LIB_DIR)"/*.py
	@rm -f "$(INSTALL_TEST_DIR)"/*.sh
	@rm -f "$(INSTALL_ROOT)/Makefile"
	@rm -f "$(INSTALL_ROOT)/dashboard-requirements.txt"
	@rmdir "$(INSTALL_BIN_DIR)" 2>/dev/null || true
	@rmdir "$(INSTALL_LIB_DIR)" 2>/dev/null || true
	@rmdir "$(INSTALL_TEST_DIR)" 2>/dev/null || true
	@rmdir "$(INSTALL_ROOT)" 2>/dev/null || true
	@echo "Uninstall complete"

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
	@echo "  test-dashboard - Run Textual dashboard pilot tests (pytest)"
	@echo "  install - Install to system"
	@echo "  uninstall - Remove installed manager files"
	@echo "  clean   - Remove generated files"
	@echo "  help    - Show this help"
