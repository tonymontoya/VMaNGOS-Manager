# VMANGOS Manager

A comprehensive administration tool for VMaNGOS (Vanilla World of Warcraft 1.12.1) private servers on Ubuntu 22.04 LTS.

## Overview

VMANGOS Manager provides:

1. **Automated Installer** (`vmangos_setup.sh`, `auto_install.sh`) - One-command installation with retry logic and error handling
2. **Management CLI** (`vmangos-manager`) - Day-to-day server administration with JSON output support

## What is VMaNGOS?

VMaNGOS is an independent continuation of the Elysium/LightsHope codebases, focused on delivering the most complete and accurate Vanilla WoW content progression system. It supports multiple patch versions from 1.2 through 1.12.1.

---

## Part 1: Installation

### Prerequisites

1. **Ubuntu 22.04 LTS Server** (fresh installation recommended)
2. **Static IP address** configured
3. **Root/sudo access**
4. **WoW 1.12.1.5875 client** - You need a copy of the game client's `/Data` folder
   - **Legal Sources:** Internet Archive (preservation copies), original CD/DVD media
   - The installer will display legal acquisition options if client data is not found
5. **Minimum 2 CPU cores and 4GB RAM** (more RAM recommended for faster compilation)

### Automated Installation (Recommended)

For a fully automated installation with secure random passwords:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash auto_install.sh
```

The auto-installer will:
- Generate secure random passwords stored in `/root/.vmangos-secrets/setup.conf`
- Run the full installation non-interactively
- Display credentials at completion

### Interactive Installation

1. Upload your WoW 1.12.1 client's `/Data` folder to the server
2. Download and run the script:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

3. Follow the interactive prompts to configure:
   - Installation directory
   - Database names and credentials
   - OS user to run the server

4. After installation, update your WoW client's `realmlist.wtf`:
```
set realmlist YOUR_SERVER_IP
```

### Installation Features

- **Git Retry Logic** - Automatic retry with exponential backoff for network failures
- **Non-Interactive Mode** - Full automation via environment variables
- **Installation Logging** - Complete logs at `/var/log/vmangos-install.log`
- **Secure Password Storage** - Credentials stored with mode 600 permissions
- **Client Data Auto-Handling** - Automatically copies client data to accessible location if needed
- **Data/Data Path Fix** - Handles the extractor's expected directory structure automatically
- **Checkpoint/Resume** - Can resume interrupted installations from where they left off

---

## Part 2: Management CLI

The `vmangos-manager` command-line tool provides Release A administration for server control, account management, backups, and update checks.

Detailed operator references live in:

- `MANUAL.md`
- `TROUBLESHOOTING.md`
- `SECURITY.md`

### Installation of CLI

```bash
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager

# Run the manager test suite
cd manager
make test

# Install manager files into /opt/mangos/manager
sudo make install PREFIX=/opt/mangos/manager

# Or use the convenience wrapper from the repo root
cd ..
sudo ./manager/install_manager.sh --run-tests
```

### Quick Start

```bash
# Validate config
sudo /opt/mangos/manager/bin/vmangos-manager config validate

# One-shot status
sudo /opt/mangos/manager/bin/vmangos-manager server status

# Watch status
sudo /opt/mangos/manager/bin/vmangos-manager server status --watch --interval 2

# Create an account without exposing the password on the command line
sudo VMANGOS_PASSWORD='ChangeMe7' /opt/mangos/manager/bin/vmangos-manager account create TESTUSER --password-env

# Check for manager updates from a git checkout
./manager/bin/vmangos-manager update check
```

### Commands

#### Global Options

| Option | Description |
|--------|-------------|
| `-c, --config FILE` | Config file path |
| `-f, --format text|json` | Output format |
| `-v, --verbose` | Enable verbose logging |
| `-h, --help` | Show help |
| `--version` | Show version information |

#### Server

```bash
vmangos-manager server start [--wait]
vmangos-manager server stop [--graceful|--force]
vmangos-manager server restart
vmangos-manager server status [--format text|json] [--watch] [--interval SECONDS]
```

#### Account

```bash
vmangos-manager account create <username> [--password-file PATH|--password-env]
vmangos-manager account list [--online]
vmangos-manager account setgm <username> <0-3>
vmangos-manager account ban <username> <duration> --reason "<words>"
vmangos-manager account unban <username>
vmangos-manager account password <username> [--password-file PATH|--password-env]
```

#### Update

```bash
vmangos-manager update check
vmangos-manager --format json update check
vmangos-manager update plan
vmangos-manager update apply --backup-first
```

`update check` is read-only. On an installed host with a configured VMANGOS core checkout under `<install_root>/source`, it inspects that source tree and reports whether the core is behind its tracked remote. If no installed source tree is available, it falls back to the Release A Manager-checkout behavior and compares the current `VMANGOS-Manager` git checkout to its tracked remote ref.

`update plan` and `update apply` operate on the configured VMANGOS core tree under `<install_root>/source`. The workflow is intentionally non-atomic: it stops services, fast-forwards the existing source tree, rebuilds in the existing build directory, reinstalls into the existing run directory, and starts services again. `update apply` rejects dirty or divergent source trees and requires either `--backup-first` or explicit confirmation that a verified backup already exists. `update apply` is text-only; `update check` and `update plan` support JSON output.

#### Config

```bash
vmangos-manager config create [--path FILE]
vmangos-manager config detect [--format text|json]
vmangos-manager config validate [--format text|json]
vmangos-manager config show [--format text|json]
```

`config detect` is an explicit adoption helper for existing VMANGOS hosts. It inspects likely install roots, looks for `mangosd.conf` and `realmd.conf`, matches auth/world service names from `systemd` when possible, and emits a reviewable proposed `manager.conf`. It does not silently change runtime behavior or overwrite your existing config.

#### Backup

```bash
vmangos-manager backup now [--verify]
vmangos-manager backup list [--format text|json]
vmangos-manager backup verify <file> [--level 1|2]
vmangos-manager backup restore <file> [--dry-run]
vmangos-manager backup clean [--keep-last N]
vmangos-manager backup schedule --daily HH:MM
vmangos-manager backup schedule --weekly "Sun 04:00"
```

### JSON Output Schema

```json
{
  "success": true,
  "timestamp": "2026-04-12T15:30:00+00:00",
  "data": {
    "services": {
      "auth": {
        "service": "auth",
        "active": true,
        "enabled": true,
        "uptime": "Sun 2026-04-12 15:25:00 UTC",
        "memory_bytes": 1524000
      },
      "world": {
        "service": "world",
        "active": true,
        "enabled": true,
        "uptime": "Sun 2026-04-12 15:25:05 UTC",
        "memory_bytes": 245800000
      }
    }
  },
  "error": null
}
```

---

## Architecture

```
VMANGOS-Manager/
├── manager/
│   ├── bin/vmangos-manager      # Main CLI entry point
│   ├── lib/common.sh            # Logging, locks, JSON helpers
│   ├── lib/config.sh            # INI parser and config management
│   ├── lib/server.sh            # Service control and status
│   ├── lib/account.sh           # Account management and validation
│   ├── lib/update.sh            # Git-based update checks
│   ├── lib/backup.sh            # Backup, verify, restore, schedule
│   ├── tests/run_tests.sh       # Shell test runner
│   ├── Makefile                 # lint/test/install/uninstall
│   └── install_manager.sh       # Source-install wrapper
├── vmangos_setup.sh         # Interactive installer
├── auto_install.sh          # Automated installer wrapper
├── README.md
├── MANUAL.md
├── TROUBLESHOOTING.md
└── SECURITY.md
```

### Library Modules

#### `manager/lib/common.sh`
- **Logging** - Structured logging with multiple levels (ERROR, WARN, INFO, DEBUG)
- **Locks** - PID-verified file locking for concurrent operation safety
- **JSON** - Escaping and output functions for API compatibility

#### `manager/lib/config.sh`
- **INI Parser** - Reads configuration files with section support
- **Defaults** - Sensible defaults for all configuration values
- **Validation** - Key and connection string format validation

#### `manager/lib/server.sh`
- **Service Control** - Start, stop, restart with timeout handling
- **Status** - Running state, uptime, memory usage, DB reachability, player counts
- **Watch Mode** - Repeated text refresh with interval control

#### `manager/lib/account.sh`
- **Validation** - Username, GM level, duration, and reason whitelists
- **Security** - Interactive/file/env password handling and VMANGOS SRP hashing
- **Operations** - Create, list, GM assignment, bans, unbans, password resets

#### `manager/lib/update.sh`
- **Update Check** - Fetches remote metadata without mutating local code
- **Comparison** - Reports the current checkout, tracked remote ref, and `commits_behind`
- **Instructions** - Prints manual non-atomic update steps for the bundled install model

---

## Directory Structure (After Installation)

```
/opt/mangos/                    # Installation root
├── source/                     # VMaNGOS source code
├── db/                         # Database files
├── build/                      # Build directory
├── run/                        # Compiled binaries and configs
│   ├── bin/                    # Server executables
│   │   └── 5875/              # Client data (dbc, maps, vmaps, mmaps)
│   └── etc/                    # Configuration files
├── logs/                       # Server logs
│   ├── mangosd/
│   ├── realmd/
│   └── honor/
└── manager/                    # VMANGOS Manager (if installed)
    ├── bin/vmangos-manager
    └── lib/
```

---

## Configuration

### Environment Variables (Installer)

| Variable | Description | Default |
|----------|-------------|---------|
| `VMANGOS_AUTO_INSTALL` | Enable non-interactive mode | (unset) |
| `VMANGOS_CLIENT_DATA` | Path to WoW client Data folder | `/home/$SUDO_USER/Data` |
| `VMANGOS_INSTALL_ROOT` | Installation directory | `/opt/mangos` |
| `VMANGOS_SQL_ADMIN_PASS` | MySQL admin password | (required) |
| `VMANGOS_DB_PASS` | VMANGOS database password | (required) |

### Manager Config File

Optional config file at `/opt/mangos/manager/config/manager.conf`:

```ini
[database]
host = 127.0.0.1
port = 3306
user = mangos
password_file = /opt/mangos/manager/config/.dbpass
auth_db = auth
characters_db = characters
world_db = world
logs_db = logs

[backup]
enabled = true
retention_days = 7
backup_dir = /opt/mangos/backups
```

---

## Testing

### Run Manager Tests

```bash
cd VMANGOS-Manager/manager
make test
```

### Test Coverage

- **36 shell tests** covering config, status, account, update, backup, and packaging behavior
- **100% pass rate** required for releases
- **CI shellcheck** - Zero warnings expected in pull requests

---

## Troubleshooting

See `TROUBLESHOOTING.md` for:

- installation and git checkout problems
- config permission errors
- status/account/backup failure patterns
- update check repo-detection issues
- host validation commands

---

## Security Considerations

See `SECURITY.md` for Release A password handling, audit logging, DB access expectations, and operational guidance.

---

## Roadmap

### Release A (Foundation) - Current
- ✅ Automated installer with retry logic
- ✅ Management CLI with JSON output
- ✅ Service control and rich status/watch output
- ✅ Account management module
- ✅ Backup and verify workflows
- ✅ Update check with manual non-atomic instructions
- ✅ Comprehensive unit tests
- ✅ Checkpoint/resume for interrupted installations
- ✅ Client data validation and legal acquisition instructions
- ✅ Auto-handling of client data permissions and path structure

### Release B
- 🔄 Non-atomic update assistant
- 🔄 Maintenance scheduler
- 🔄 Enhanced server control safety interlocks
- 🔄 Log rotation

### Release C
- 🔄 Textual dashboard

---

## Resources

- [VMaNGOS Core](https://github.com/vmangos/core)
- [VMaNGOS Database](https://github.com/brotalnia/database)
- [VMaNGOS Wiki](https://github.com/vmangos/wiki/wiki)
- [Issue Tracker](https://github.com/tonymontoya/VMANGOS-Manager/issues)

---

## License & Disclaimer

This project is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.

VMANGOS Manager is not affiliated with Blizzard Entertainment or the VMaNGOS project. It's an independent administration tool.
