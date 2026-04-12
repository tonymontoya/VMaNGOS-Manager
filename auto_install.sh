#!/bin/bash
# =============================================================================
# VMANGOS Auto-Install Wrapper
# =============================================================================
# This script wraps vmangos_setup.sh for automated/non-interactive installation
# Uses secure password storage in /root/.vmangos-secrets/
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="/root/.vmangos-secrets"
CONFIG_FILE="$SECRETS_DIR/setup.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Create secure directory for secrets
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Generate or load configuration
generate_config() {
    log_info "Generating new configuration..."
    
    # Generate secure passwords
    SQLADMINPASS="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 24)"
    MANGOSDBPASS="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 24)"
    
    cat > "$CONFIG_FILE" << EOF
# VMANGOS Installation Secrets
# Generated: $(date -Iseconds)
# Permissions: root:root 600

# Database Admin (root)
SQLADMINUSER="root"
SQLADMINIP="%"
SQLADMINPASS="${SQLADMINPASS}"

# VMANGOS Database User
MANGOSDBUSER="mangos"
MANGOSDBPASS="${MANGOSDBPASS}"

# OS User for running server
MANGOSOSUSER="mangos"

# Database Names
AUTHDB="auth"
WORLDDB="world"
CHARACTERDB="characters"
LOGSDB="logs"

# Installation Paths
INSTALLROOT="/opt/mangos"
CLIENTDATA="/home/tony/Data"

# Auto-install settings
SKIP_SECURE_MYSQL="yes"
EOF

    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    
    log_info "Configuration saved to: $CONFIG_FILE"
    log_info "Database root password: ${SQLADMINPASS}"
    log_info "Mangos DB password: ${MANGOSDBPASS}"
}

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    log_info "Loading configuration from: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    generate_config
fi

# Verify client data exists
if [ ! -d "$CLIENTDATA" ]; then
    log_error "Client Data directory not found at: $CLIENTDATA"
    log_error "Please ensure the WoW 1.12.1 client Data folder is available."
    exit 1
fi

log_info "Client data found at: $CLIENTDATA"

# Clean up any previous partial installation
if [ -d "$INSTALLROOT" ]; then
    log_warn "Existing installation found at: $INSTALLROOT"
    read -p "Remove existing installation? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing existing installation..."
        rm -rf "$INSTALLROOT"
    else
        log_error "Cannot continue with existing installation. Please backup and remove manually."
        exit 1
    fi
fi

# Export environment variables for vmangos_setup.sh
export VMANGOS_AUTO_INSTALL="1"
export VMANGOS_CLIENT_DATA="$CLIENTDATA"
export VMANGOS_INSTALL_ROOT="$INSTALLROOT"
export VMANGOS_SQL_ADMIN_USER="$SQLADMINUSER"
export VMANGOS_SQL_ADMIN_IP="$SQLADMINIP"
export VMANGOS_SQL_ADMIN_PASS="$SQLADMINPASS"
export VMANGOS_WORLD_DB="$WORLDDB"
export VMANGOS_AUTH_DB="$AUTHDB"
export VMANGOS_CHAR_DB="$CHARACTERDB"
export VMANGOS_DB_USER="$MANGOSDBUSER"
export VMANGOS_DB_PASS="$MANGOSDBPASS"
export VMANGOS_OS_USER="$MANGOSOSUSER"
export VMANGOS_SKIP_SECURE_MYSQL="$SKIP_SECURE_MYSQL"
export VMANGOS_BACKGROUND_BUILD="1"  # Run compilation in background to prevent timeout
export INSTALL_LOG="/var/log/vmangos-install.log"

log_info "Starting VMANGOS installation..."
log_info "Installation log: $INSTALL_LOG"
log_info "This will take 1-2 hours depending on your system."
log_info ""
log_info "IMPORTANT: The compilation runs in the background to prevent timeouts."
log_info "Monitor progress with: tail -f $INSTALL_LOG"
log_info ""
log_info "If disconnected, you can resume by re-running this script."
echo

# Run the installer
if bash "$SCRIPT_DIR/vmangos_setup.sh"; then
    echo
    log_info "Installation completed successfully!"
    echo
    echo "=========================================="
    echo "IMPORTANT: SAVE THESE CREDENTIALS"
    echo "=========================================="
    echo "Config file: $CONFIG_FILE"
    echo "MariaDB root password: $SQLADMINPASS"
    echo "VMANGOS DB password: $MANGOSDBPASS"
    echo "=========================================="
    echo
    log_info "To start the servers:"
    log_info "  sudo systemctl start auth"
    log_info "  sudo systemctl start world"
    echo
    log_info "To check status:"
    log_info "  sudo systemctl status auth"
    log_info "  sudo systemctl status world"
    exit 0
else
    log_error "Installation failed. Check the log: $INSTALL_LOG"
    exit 1
fi
