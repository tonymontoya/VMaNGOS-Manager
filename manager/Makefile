.PHONY: all test lint install uninstall clean help

# Shell scripts to lint
SCRIPTS := bin/vmangos-manager install_manager.sh lib/common.sh lib/config.sh lib/server.sh lib/account.sh lib/update.sh lib/backup.sh

PREFIX ?= /opt/mangos/manager
DESTDIR ?=
INSTALL_ROOT := $(DESTDIR)$(PREFIX)
INSTALL_BIN_DIR := $(INSTALL_ROOT)/bin
INSTALL_LIB_DIR := $(INSTALL_ROOT)/lib
INSTALL_TEST_DIR := $(INSTALL_ROOT)/tests

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
	@echo "Installing VMANGOS Manager into $(INSTALL_ROOT)..."
	@install -d "$(INSTALL_BIN_DIR)" "$(INSTALL_LIB_DIR)" "$(INSTALL_TEST_DIR)"
	@install -m 755 bin/vmangos-manager "$(INSTALL_BIN_DIR)/vmangos-manager"
	@install -m 644 lib/*.sh "$(INSTALL_LIB_DIR)/"
	@install -m 644 tests/*.sh "$(INSTALL_TEST_DIR)/"
	@install -m 644 Makefile "$(INSTALL_ROOT)/Makefile"
	@echo "Installation complete"

# Uninstall from system without removing config/
uninstall:
	@echo "Removing VMANGOS Manager from $(INSTALL_ROOT)..."
	@rm -f "$(INSTALL_BIN_DIR)/vmangos-manager"
	@rm -f "$(INSTALL_LIB_DIR)"/*.sh
	@rm -f "$(INSTALL_TEST_DIR)"/*.sh
	@rm -f "$(INSTALL_ROOT)/Makefile"
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
	@echo "  install - Install to system"
	@echo "  uninstall - Remove installed manager files"
	@echo "  clean   - Remove generated files"
	@echo "  help    - Show this help"
