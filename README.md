# vmangos-setup

A script to automate the installation of a VMaNGOS private World of Warcraft Classic (1.12.1) server on Ubuntu 22.04 LTS.

## What is VMaNGOS?

VMaNGOS is an independent continuation of the Elysium/LightsHope codebases, focused on delivering the most complete and accurate Vanilla WoW content progression system. It supports multiple patch versions from 1.2 through 1.12.1.

## Prerequisites

1. **Ubuntu 22.04 LTS Server** (fresh installation recommended)
2. **Static IP address** configured
3. **Root/sudo access**
4. **WoW 1.12.1.5875 client** - You need a copy of the game client's `/Data` folder
5. **Minimum 2 CPU cores and 4GB RAM** (more RAM recommended for faster compilation)

## Quick Start

### Automated Installation (Recommended)

For a fully automated installation with secure random passwords:

```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/vmangos-setup/main/auto_install.sh
wget https://raw.githubusercontent.com/YOUR_USERNAME/vmangos-setup/main/vmangos_setup.sh
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
wget https://raw.githubusercontent.com/YOUR_USERNAME/vmangos-setup/main/vmangos_setup.sh
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

## Automated/Non-Interactive Mode

The installer supports non-interactive installation via environment variables:

```bash
export VMANGOS_AUTO_INSTALL="1"
export VMANGOS_CLIENT_DATA="/home/user/Data"
export VMANGOS_INSTALL_ROOT="/opt/mangos"
export VMANGOS_SQL_ADMIN_USER="root"
export VMANGOS_SQL_ADMIN_PASS="your_secure_password"
export VMANGOS_DB_USER="mangos"
export VMANGOS_DB_PASS="your_db_password"

sudo -E bash vmangos_setup.sh
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VMANGOS_AUTO_INSTALL` | Enable non-interactive mode | (unset) |
| `VMANGOS_CLIENT_DATA` | Path to WoW client Data folder | `/home/$SUDO_USER/Data` |
| `VMANGOS_INSTALL_ROOT` | Installation directory | `/opt/mangos` |
| `VMANGOS_SQL_ADMIN_USER` | MySQL admin username | `root` |
| `VMANGOS_SQL_ADMIN_PASS` | MySQL admin password | (required) |
| `VMANGOS_SQL_ADMIN_IP` | MySQL admin IP restriction | `%` |
| `VMANGOS_WORLD_DB` | World database name | `world` |
| `VMANGOS_AUTH_DB` | Auth database name | `auth` |
| `VMANGOS_CHAR_DB` | Characters database name | `characters` |
| `VMANGOS_DB_USER` | VMANGOS database username | `mangos` |
| `VMANGOS_DB_PASS` | VMANGOS database password | (required) |
| `VMANGOS_OS_USER` | Linux user to run server | `mangos` |
| `VMANGOS_SKIP_SECURE_MYSQL` | Skip mysql_secure_installation | `yes` |

## What the Script Does

1. **Installs Dependencies** - Required packages for compilation and runtime
2. **Downloads Source** - Clones the VMaNGOS core and database repositories (with retry logic)
3. **Compiles** - Builds the auth server, world server, and extractor tools
4. **Extracts Game Data** - Processes client data (maps, vmaps, mmaps, DBC files)
5. **Sets Up Database** - Creates databases, users, and imports world data
6. **Configures** - Updates server configuration files with your settings
7. **Creates Services** - Sets up systemd services for auto-start

## Post-Installation

### Starting the Servers
```bash
sudo systemctl start auth    # Start auth server
sudo systemctl start world   # Start world server
```

### Checking Status
```bash
sudo systemctl status auth
sudo systemctl status world
```

### Viewing Logs
```bash
# Server logs
sudo journalctl -u auth -f
sudo journalctl -u world -f

# Installation log
sudo tail -f /var/log/vmangos-install.log
```

### Server Console
The world server runs with a console accessible via:
```bash
sudo screen -r  # or attach to tty3
```

## Directory Structure

```
/opt/mangos/              # Default installation root
├── source/               # VMaNGOS source code
├── db/                   # Database files
├── build/                # Build directory
├── run/                  # Compiled binaries and configs
│   ├── bin/              # Server executables
│   │   └── 5875/         # Client data (dbc, maps, vmaps, mmaps)
│   └── etc/              # Configuration files
└── logs/                 # Log files
    ├── mangosd/
    ├── realmd/
    └── honor/
```

## Default Database Names

- `auth` - Account and realm information
- `world` - Game world data (creatures, quests, spells, etc.)
- `characters` - Character data
- `logs` - Server logs

## Troubleshooting

### Installation Log
All installation output is logged to:
```bash
sudo tail -f /var/log/vmangos-install.log
```

### Git Clone Failures
The installer includes retry logic with exponential backoff for git clones. If cloning still fails:
- Check network connectivity
- Verify GitHub is accessible: `curl -I https://github.com`
- Try manual clone to test: `git clone https://github.com/vmangos/core`

### Compilation Issues
- Ensure you have at least 4GB RAM (swap can help)
- For limited RAM, edit the script to use fewer parallel jobs: change `make -j $CPU` to `make -j 1`

### Database Connection Issues
- Verify MariaDB is running: `sudo systemctl status mariadb`
- Check credentials in `/opt/mangos/run/etc/mangosd.conf` and `realmd.conf`

### Client Connection Issues
- Verify `realmlist.wtf` points to your server IP
- Check firewall settings: ports 3724 (auth) and 8085 (world) need to be open
- Verify the realmlist table: `mysql auth -e "SELECT * FROM realmlist;"`

## Security Considerations

1. **Passwords**: When using `auto_install.sh`, passwords are stored securely in `/root/.vmangos-secrets/setup.conf` (mode 600)
2. **Firewall**: Limit access to MySQL port (3306) to trusted IPs only
3. **Database**: The auto-installer skips `mysql_secure_installation` by default. Run it manually if desired:
   ```bash
   sudo mysql_secure_installation
   ```
4. **Updates**: Keep your server updated with the latest VMaNGOS commits

## Resources

- [VMaNGOS Core](https://github.com/vmangos/core)
- [VMaNGOS Database](https://github.com/brotalnia/database)
- [VMaNGOS Wiki](https://github.com/vmangos/wiki/wiki)

## Disclaimer

This script is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.
