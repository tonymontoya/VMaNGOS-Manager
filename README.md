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

---

## Part 2: Management CLI

The `vmangos-manager` command-line tool provides comprehensive server administration.

### Installation of CLI

```bash
# Clone the repository
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager

# Install to system (optional)
sudo cp bin/vmangos-manager /usr/local/bin/
sudo chmod +x /usr/local/bin/vmangos-manager
```

### Quick Start

```bash
# Check server status
sudo vmangos-manager server status all

# Start servers
sudo vmangos-manager server start all

# View logs
sudo vmangos-manager server logs world -f
```

### Commands

#### Server Control

```bash
# Start services
sudo vmangos-manager server start [auth|world|all]

# Stop services
sudo vmangos-manager server stop [auth|world|all]

# Restart services
sudo vmangos-manager server restart [auth|world|all]

# Check status
sudo vmangos-manager server status [auth|world|all]

# View logs
sudo vmangos-manager server logs [auth|world] [-f]
```

#### Global Options

| Option | Description |
|--------|-------------|
| `-j, --json` | Output in JSON format |
| `-v, --verbose` | Enable verbose logging |
| `-n, --dry-run` | Show what would be done without executing |
| `-h, --help` | Show help message |
| `--version` | Show version information |

#### Examples

```bash
# JSON output for scripting
sudo vmangos-manager --json server status world

# Dry run to preview changes
sudo vmangos-manager -n server restart all

# Verbose logging for debugging
sudo vmangos-manager -v server start all

# Follow logs in real-time
sudo vmangos-manager server logs auth -f
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
├── bin/
│   └── vmangos-manager      # Main CLI entry point
├── lib/
│   ├── common.sh            # Logging, locks, JSON helpers, security
│   ├── config.sh            # INI parser, config management
│   └── server.sh            # Service control (start/stop/restart/status)
├── tests/
│   └── unit/                # Unit test suite
├── vmangos_setup.sh         # Interactive installer
├── auto_install.sh          # Automated installer wrapper
└── README.md
```

### Library Modules

#### `lib/common.sh`
- **Logging** - Structured logging with multiple levels (ERROR, WARN, INFO, DEBUG)
- **Locks** - PID-verified file locking for concurrent operation safety
- **JSON** - Escaping and output functions for API compatibility
- **Security** - Password file permission checking, input validation

#### `lib/config.sh`
- **INI Parser** - Reads configuration files with section support
- **Defaults** - Sensible defaults for all configuration values
- **Validation** - Key and connection string format validation

#### `lib/server.sh`
- **Service Control** - Start, stop, restart with timeout handling
- **Status** - Running state, uptime, memory usage
- **Health Checks** - Verify services are actually responding
- **Bulk Operations** - All-services operations with proper ordering

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

Optional config file at `/opt/mangos/manager/manager.conf`:

```ini
[database]
host = localhost
port = 3306
manager_user = vmangos_mgr

[backup]
enabled = true
retention_days = 7
path = /opt/mangos/backups
```

---

## Testing

### Run Unit Tests

```bash
cd VMANGOS-Manager
bash tests/unit/test_common.sh
bash tests/unit/test_config.sh
```

### Test Coverage

- **32 unit tests** covering core functionality
- **100% pass rate** required for releases
- **Shellcheck clean** - Zero warnings or errors

---

## Troubleshooting

### Installation Issues

#### Git Clone Failures
The installer includes retry logic with exponential backoff. If cloning still fails:
- Check network connectivity
- Verify GitHub is accessible: `curl -I https://github.com`
- Try manual clone: `git clone https://github.com/vmangos/core`

#### Compilation Issues
- Ensure you have at least 4GB RAM (swap can help)
- For limited RAM, edit to use fewer jobs: `make -j 1` instead of `make -j $CPU`

### Management CLI Issues

#### Permission Denied
The CLI requires root privileges for systemctl operations:
```bash
sudo vmangos-manager server status all
```

#### Lock Timeouts
If you see "Could not acquire lock" errors:
- Check if another manager process is running: `ps aux | grep vmangos-manager`
- Stale locks are automatically cleared after 60 seconds

#### JSON Parsing Errors
Ensure your system has Python 3 for JSON validation:
```bash
python3 --version
```

### Server Issues

#### Services Won't Start
```bash
# Check systemd status
sudo systemctl status auth
sudo systemctl status world

# View detailed logs
sudo journalctl -u auth -n 50
sudo journalctl -u world -n 50
```

#### Database Connection Issues
```bash
# Verify MariaDB is running
sudo systemctl status mariadb

# Check credentials in config
sudo grep -E "DatabaseInfo" /opt/mangos/run/etc/mangosd.conf
```

#### Client Can't Connect
- Verify `realmlist.wtf` points to your server IP
- Check firewall: ports 3724 (auth) and 8085 (world) must be open
- Verify realmlist table: `mysql auth -e "SELECT * FROM realmlist;"`

---

## Security Considerations

1. **Password Files** - Always use mode 600, owned by root
2. **Firewall** - Limit MySQL port (3306) to trusted IPs only
3. **Updates** - Keep VMANGOS core updated with latest commits
4. **Backups** - Regular database backups recommended

---

## Roadmap

### Release A (Foundation) - Current
- ✅ Automated installer with retry logic
- ✅ Management CLI with JSON output
- ✅ Service control (start/stop/restart/status)
- ✅ Comprehensive unit tests

### Release B (Backup & Monitoring)
- 🔄 Database backup/restore
- 🔄 Automated backup scheduling
- 🔄 Player count monitoring
- 🔄 Service health dashboards

### Release C (Account Management)
- 🔄 Account CRUD operations
- 🔄 Ban/unban functionality
- 🔄 Password management
- 🔄 GM level management

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
