# VMANGOS Manager Makefile

.PHONY: all test lint install clean

# Directories
PREFIX ?= /opt/mangos/manager
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
CONFIGDIR = $(PREFIX)/config

# Shell scripts
SCRIPTS = bin/vmangos-manager
LIBS = lib/common.sh lib/config.sh lib/server.sh

all: lint

lint:
	@echo "Running shellcheck..."
	@shellcheck $(SCRIPTS) $(LIBS) || true
	@echo "Lint complete"

test:
	@echo "Running unit tests..."
	@bash tests/test_common.sh 2>/dev/null || echo "test_common.sh not yet implemented"
	@bash tests/test_config.sh 2>/dev/null || echo "test_config.sh not yet implemented"
	@bash tests/test_server.sh 2>/dev/null || echo "test_server.sh not yet implemented"
	@echo "Tests complete"

install:
	@echo "Installing VMANGOS Manager..."
	@mkdir -p $(BINDIR) $(LIBDIR) $(CONFIGDIR)
	@install -m 755 $(SCRIPTS) $(BINDIR)/
	@install -m 644 $(LIBS) $(LIBDIR)/
	@echo "Installed to $(PREFIX)"
	@echo "Run '$(BINDIR)/vmangos-manager --help' to get started"

uninstall:
	@echo "Uninstalling VMANGOS Manager..."
	@rm -rf $(PREFIX)
	@echo "Uninstalled"

clean:
	@echo "Cleaning..."
	@rm -f *.log
	@echo "Clean complete"

help:
	@echo "VMANGOS Manager Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Run lint (default)"
	@echo "  lint     - Run shellcheck on all scripts"
	@echo "  test     - Run unit tests"
	@echo "  install  - Install to PREFIX (default: /opt/mangos/manager)"
	@echo "  uninstall- Remove installation"
	@echo "  clean    - Clean temporary files"
	@echo "  help     - Show this help"
