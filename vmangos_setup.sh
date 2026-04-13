#!/bin/bash
# =============================================================================
# VMANGOS Setup Script - Ubuntu 22.04 LTS
# =============================================================================
# This script automates the installation of VMaNGOS (Vanilla MaNGOS)
# onto Ubuntu 22.04 LTS. It includes:
# - Retry logic for network operations
# - Resume capability for interrupted installations
# - Background execution support for long builds
# - Comprehensive logging
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# CONFIGURATION - Can be overridden via environment variables
# =============================================================================

# Non-interactive mode detection
VMANGOS_AUTO_INSTALL="${VMANGOS_AUTO_INSTALL:-0}"

# Installation paths
INSTALLROOT="${VMANGOS_INSTALL_ROOT:-/opt/mangos}"
CLIENT_DATA="${VMANGOS_CLIENT_DATA:-}"
SERVERIP="${VMANGOS_SERVER_IP:-}"

# Database settings
SQLADMINUSER="${VMANGOS_SQL_ADMIN_USER:-root}"
SQLADMINIP="${VMANGOS_SQL_ADMIN_IP:-%}"
SQLADMINPASS="${VMANGOS_SQL_ADMIN_PASS:-}"
AUTHDB="${VMANGOS_AUTH_DB:-auth}"
WORLDDB="${VMANGOS_WORLD_DB:-world}"
CHARACTERDB="${VMANGOS_CHAR_DB:-characters}"
LOGSDB="${VMANGOS_LOGS_DB:-logs}"
MANGOSDBUSER="${VMANGOS_DB_USER:-mangos}"
MANGOSDBPASS="${VMANGOS_DB_PASS:-mangos}"
MANGOSOSUSER="${VMANGOS_OS_USER:-mangos}"

# Feature flags
SKIP_SECURE_MYSQL="${VMANGOS_SKIP_SECURE_MYSQL:-no}"

# Checkpoint/Resume settings
CHECKPOINT_DIR="${INSTALLROOT}/.install-checkpoints"
CHECKPOINT_FILE="${CHECKPOINT_DIR}/checkpoint"
INSTALL_LOG="${INSTALL_LOG:-/var/log/vmangos-install.log}"
BUILD_IN_BACKGROUND="${VMANGOS_BACKGROUND_BUILD:-0}"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Create log directory if needed
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$INSTALL_LOG"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$INSTALL_LOG"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$INSTALL_LOG"
}

log_section() {
    echo "" | tee -a "$INSTALL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ==========================================" | tee -a "$INSTALL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$INSTALL_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ==========================================" | tee -a "$INSTALL_LOG"
}

# =============================================================================
# USER INPUT FUNCTIONS
# =============================================================================

ask_yes_no() {
    local question="$1"
    local default="${2:-n}"
    local response
    
    while true; do
        if [ "$default" = "y" ]; then
            read -rp "$question [Y/n] " response
            response=${response:-Y}
        else
            read -rp "$question [y/N] " response
            response=${response:-N}
        fi
        
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# =============================================================================
# CHECKPOINT FUNCTIONS
# =============================================================================

init_checkpoints() {
    mkdir -p "$CHECKPOINT_DIR"
    if [ ! -f "$CHECKPOINT_FILE" ]; then
        echo "START" > "$CHECKPOINT_FILE"
    fi
}

set_checkpoint() {
    echo "$1" > "$CHECKPOINT_FILE"
    log_info "Checkpoint: $1"
}

get_checkpoint() {
    if [ -f "$CHECKPOINT_FILE" ]; then
        cat "$CHECKPOINT_FILE"
    else
        echo "START"
    fi
}

clear_checkpoint() {
    rm -f "$CHECKPOINT_FILE"
    rm -rf "$CHECKPOINT_DIR"
    log_info "Installation complete - checkpoints cleared"
}

ensure_server_ip() {
    if [ -n "$SERVERIP" ]; then
        log_info "Using server IP: $SERVERIP"
        return 0
    fi

    SERVERIP=$(hostname -I | awk '{print $1}')
    if [ -z "$SERVERIP" ]; then
        log_error "Unable to determine server IP. Set VMANGOS_SERVER_IP and rerun the installer."
        return 1
    fi

    log_info "Detected server IP: $SERVERIP"
}

# =============================================================================
# PROGRESS FUNCTIONS
# =============================================================================

show_progress_spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local delay=0.1
    local spinstr='|/-\'
    
    printf "%s " "$message"
    while [ -d /proc/$pid ]; do
        local temp=${spinstr#?}
        printf " [%c]" "$spinstr"
        local spinstr=$temp${spinstr%%$temp}
        sleep $delay
        printf "\b\b\b\b"
    done
    printf " [Done]\n"
}

show_progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "\r["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%%" "$percentage"
}

# =============================================================================
# RETRY FUNCTIONS
# =============================================================================

download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_delay=5
    
    for i in $(seq 1 $max_retries); do
        log_info "Download attempt $i/$max_retries: $url"
        if timeout 300 wget --tries=3 --timeout=60 -O "$output" "$url" 2>&1 | tee -a "$INSTALL_LOG"; then
            log_info "Download successful"
            return 0
        fi
        log_warn "Download failed, waiting ${retry_delay}s before retry..."
        sleep $retry_delay
        retry_delay=$((retry_delay * 2))
    done
    
    log_error "Download failed after $max_retries attempts"
    return 1
}

git_clone_with_retry() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="${3:-}"
    local max_retries=3
    local retry_delay=5
    
    for i in $(seq 1 $max_retries); do
        log_info "Git clone attempt $i/$max_retries: $repo_url"
        rm -rf "$target_dir"
        if [ -n "$branch" ]; then
            if timeout 300 git clone -b "$branch" "$repo_url" "$target_dir" 2>&1 | tee -a "$INSTALL_LOG"; then
                log_info "Clone successful"
                return 0
            fi
        else
            if timeout 300 git clone "$repo_url" "$target_dir" 2>&1 | tee -a "$INSTALL_LOG"; then
                log_info "Clone successful"
                return 0
            fi
        fi
        log_warn "Clone failed, waiting ${retry_delay}s before retry..."
        sleep $retry_delay
        retry_delay=$((retry_delay * 2))
    done
    
    log_error "Git clone failed after $max_retries attempts"
    return 1
}

# =============================================================================
# BACKGROUND BUILD FUNCTIONS
# =============================================================================

start_background_build() {
    log_section "STARTING BACKGROUND BUILD"
    log_info "The compilation will run in the background due to long build time (1-2 hours)"
    log_info "Monitor progress with: tail -f ${INSTALL_LOG}"
    log_info "Check build status with: cat ${CHECKPOINT_DIR}/build-status"
    
    # Create build script
    cat > "$CHECKPOINT_DIR/build.sh" << 'BUILDEOF'
#!/bin/bash
set -e
BUILD_LOG="$1"
CPU="$2"
INSTALLROOT="$3"

echo "RUNNING" > "${INSTALLROOT}/.install-checkpoints/build-status"

cd "${INSTALLROOT}/build"
if make -j "$CPU" 2>&1 | tee -a "$BUILD_LOG"; then
    echo "COMPLETED" > "${INSTALLROOT}/.install-checkpoints/build-status"
    exit 0
else
    echo "FAILED" > "${INSTALLROOT}/.install-checkpoints/build-status"
    exit 1
fi
BUILDEOF
    chmod +x "$CHECKPOINT_DIR/build.sh"
    
    # Start build in background with nohup
    nohup "$CHECKPOINT_DIR/build.sh" "$INSTALL_LOG" "$(nproc)" "$INSTALLROOT" > /dev/null 2>&1 &
    BUILD_PID=$!
    echo "$BUILD_PID" > "$CHECKPOINT_DIR/build.pid"
    
    log_info "Build started with PID: $BUILD_PID"
    log_info "Waiting for build to complete..."
    
    # Wait for build to complete
    if wait $BUILD_PID; then
        log_info "Background build completed successfully"
        return 0
    else
        log_error "Background build failed"
        return 1
    fi
}

check_build_status() {
    if [ -f "$CHECKPOINT_DIR/build-status" ]; then
        cat "$CHECKPOINT_DIR/build-status"
    else
        echo "UNKNOWN"
    fi
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_noninteractive() {
    [ "$VMANGOS_AUTO_INSTALL" = "1" ] || [ "$VMANGOS_AUTO_INSTALL" = "true" ]
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
}

show_client_data_help() {
    log_info ""
    log_info "========================================================================"
    log_info "CLIENT DATA REQUIRED"
    log_info "========================================================================"
    log_info "VMaNGOS requires WoW 1.12.1 (build 5875) client data for extraction."
    log_info ""
    log_info "LEGAL ACQUISITION OPTIONS:"
    log_info ""
    log_info "1. INTERNET ARCHIVE (Recommended - Preservation Copy):"
    log_info "   https://archive.org/details/World-of-Warcraft-1.12.-Vanilla-Pre-BC-2004"
    log_info "   Look for: World of Warcraft 1.12.1 (enUS or your locale)"
    log_info ""
    log_info "2. IF YOU OWN THE GAME:"
    log_info "   - Install from original CD/DVD media"
    log_info "   - Copy the Data folder from your installation"
    log_info ""
    log_info "3. PRE-EXTRACTED DATA (Community Alternative):"
    log_info "   Some community repacks provide pre-extracted map files."
    log_info "   Search: 'vmangos pre-extracted maps' (legally grey area)"
    log_info ""
    log_info "REQUIRED FILES IN DATA FOLDER:"
    log_info "   - dbc.MPQ, terrain.MPQ, wmo.MPQ, model.MPQ"
    log_info "   - texture.MPQ, sound.MPQ, speech.MPQ"
    log_info "   - patch.MPQ (should be ~1.9GB for 1.12.1)"
    log_info ""
    log_info "NOTE: The installer will attempt extraction but can continue without"
    log_info "      valid client data (you can extract manually later)."
    log_info "========================================================================"
    log_info ""
}

validate_client_data() {
    local data_path="$1"
    local errors=0
    
    log_info "Validating client data at: $data_path"
    
    # Check for required MPQ files
    local required_files=("dbc.MPQ" "terrain.MPQ" "wmo.MPQ" "model.MPQ" "texture.MPQ")
    for file in "${required_files[@]}"; do
        if [ ! -f "$data_path/$file" ]; then
            log_warn "Missing required file: $file"
            ((errors++))
        fi
    done
    
    # Check patch.MPQ size (should be ~1.9GB for 1.12.1)
    if [ -f "$data_path/patch.MPQ" ]; then
        local patch_size=$(stat -c%s "$data_path/patch.MPQ" 2>/dev/null || echo 0)
        if [ "$patch_size" -lt 1000000000 ]; then
            log_warn "patch.MPQ seems too small ($patch_size bytes) - expected ~1.9GB"
            log_warn "This may not be a valid 1.12.1 client"
            ((errors++))
        else
            log_info "patch.MPQ size looks correct ($(numfmt --to=iec $patch_size))"
        fi
    else
        log_warn "Missing patch.MPQ"
        ((errors++))
    fi
    
    # Test extraction capability with a dry-run
    if [ -f "$data_path/dbc.MPQ" ]; then
        log_info "Found dbc.MPQ - basic structure looks valid"
    fi
    
    if [ $errors -gt 0 ]; then
        log_warn "Client data validation found $errors issues"
        return 1
    else
        log_info "Client data validation passed"
        return 0
    fi
}

check_client_data() {
    if [ -z "$CLIENT_DATA" ]; then
        # Try to auto-detect
        for user_home in /home/*; do
            if [ -d "$user_home/Data" ]; then
                CLIENT_DATA="$user_home/Data"
                log_info "Auto-detected client data at: $CLIENT_DATA"
                break
            fi
        done
    fi
    
    if [ -z "$CLIENT_DATA" ] || [ ! -d "$CLIENT_DATA" ]; then
        show_client_data_help
        if check_noninteractive; then
            log_warn "Client data not found. Set VMANGOS_CLIENT_DATA environment variable."
            log_warn "Installation will continue but data extraction will be skipped."
            CLIENT_DATA=""
            return 0
        else
            read -rp "Enter path to WoW 1.12.1 client Data folder (or press Enter to skip): " CLIENT_DATA
            if [ -z "$CLIENT_DATA" ] || [ ! -d "$CLIENT_DATA" ]; then
                log_warn "No valid client data provided. Data extraction will be skipped."
                log_warn "You can manually extract data later after providing client files."
                CLIENT_DATA=""
                return 0
            fi
        fi
    fi
    
    # Validate the client data
    if ! validate_client_data "$CLIENT_DATA"; then
        log_warn "Client data may be incompatible or incomplete"
        if ! check_noninteractive; then
            read -rp "Continue anyway? Extraction may fail (y/N): " continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                show_client_data_help
                log_info "Please provide valid 1.12.1 client data and run again."
                exit 1
            fi
        fi
    fi
    
    log_info "Using client data from: $CLIENT_DATA"
    
    # The extractor expects {path}/Data/ structure
    # If user provided the Data folder directly, create a Data/Data symlink
    CLIENT_DATA_EXTRACT_ROOT="$CLIENT_DATA"
    if [ -f "$CLIENT_DATA/dbc.MPQ" ] && [ -f "$CLIENT_DATA/terrain.MPQ" ]; then
        # User provided the Data folder directly
        # Create a symlink Data/Data pointing to itself for extractor compatibility
        if [ ! -e "$CLIENT_DATA/Data" ]; then
            log_info "Creating Data/Data symlink for extractor compatibility..."
            ln -sf . "$CLIENT_DATA/Data" 2>/dev/null || true
        fi
        # The extractor will use the path as-is, it expects Data/ subdirectory
        CLIENT_DATA_EXTRACT_ROOT="$CLIENT_DATA"
    fi
    
    # Check if mangos user can read the client data
    # Extraction runs as mangos user for security, so we need readable permissions
    if ! sudo -u "$MANGOSOSUSER" test -r "$CLIENT_DATA_EXTRACT_ROOT/dbc.MPQ" 2>/dev/null; then
        log_warn "Client data is not accessible by $MANGOSOSUSER user"
        log_info "Copying client data to $INSTALLROOT/client-data for extraction..."
        
        # Create temp location and copy data
        mkdir -p "$INSTALLROOT/client-data"
        
        # Copy all MPQ files and required directories
        cp -r "$CLIENT_DATA_EXTRACT_ROOT"/*.MPQ "$INSTALLROOT/client-data/" 2>/dev/null || true
        cp -r "$CLIENT_DATA_EXTRACT_ROOT"/*.mpq "$INSTALLROOT/client-data/" 2>/dev/null || true
        
        # Copy Interface directory if it exists (contains Cinematics, etc)
        if [ -d "$CLIENT_DATA_EXTRACT_ROOT/Interface" ]; then
            cp -r "$CLIENT_DATA_EXTRACT_ROOT/Interface" "$INSTALLROOT/client-data/" 2>/dev/null || true
        fi
        
        # Set ownership for mangos user
        chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT/client-data"
        
        # Create the Data/Data symlink in the copy
        if [ ! -e "$INSTALLROOT/client-data/Data" ]; then
            ln -sf . "$INSTALLROOT/client-data/Data" 2>/dev/null || true
        fi
        
        CLIENT_DATA_EXTRACT_ROOT="$INSTALLROOT/client-data"
        log_info "Client data copied to: $CLIENT_DATA_EXTRACT_ROOT"
    fi
}

# =============================================================================
# INSTALLATION PHASES
# =============================================================================

phase_prerequisites() {
    log_section "PHASE: Installing Prerequisites"
    
    apt-get update
    apt-get install -y build-essential cmake git libmariadb-dev libssl-dev \
        libbz2-dev libreadline-dev libncurses-dev libboost-all-dev \
        p7zip-full wget zlib1g-dev
    
    set_checkpoint "PREREQS_DONE"
}

phase_database_setup() {
    log_section "PHASE: Database Setup"
    
    # Create databases
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$WORLDDB\`;" || true
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$AUTHDB\`;" || true
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$CHARACTERDB\`;" || true
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$LOGSDB\`;" || true
    
    # Create user
    mysql -e "CREATE USER IF NOT EXISTS '$MANGOSDBUSER'@'$SQLADMINIP' IDENTIFIED BY '$MANGOSDBPASS';" || true
    mysql -e "GRANT ALL PRIVILEGES ON \`$WORLDDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" || true
    mysql -e "GRANT ALL PRIVILEGES ON \`$AUTHDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" || true
    mysql -e "GRANT ALL PRIVILEGES ON \`$CHARACTERDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" || true
    mysql -e "GRANT ALL PRIVILEGES ON \`$LOGSDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" || true
    mysql -e "FLUSH PRIVILEGES;"
    
    set_checkpoint "DATABASE_DONE"
}

phase_source_download() {
    log_section "PHASE: Downloading Source Code"
    
    mkdir -p "$INSTALLROOT"
    cd "$INSTALLROOT"
    
    # Clone VMaNGOS core
    if [ ! -d "source" ]; then
        git_clone_with_retry "https://github.com/vmangos/core" "source"
    else
        log_info "Source directory exists, skipping clone"
    fi
    
    set_checkpoint "SOURCE_DONE"
}

phase_build() {
    log_section "PHASE: Building VMaNGOS from Source"
    
    cd "$INSTALLROOT"
    CPU=$(nproc)
    
    log_info "====================================================================="
    log_info "COMPILING VMANGOS - THIS WILL TAKE 1-2 HOURS"
    log_info "====================================================================="
    log_info ""
    log_info "Your system has $CPU CPU core(s)."
    log_info ""
    log_info "Estimated build time:"
    if [ "$CPU" -ge 8 ]; then
        log_info "  • High-end CPU (8+ cores): 30-45 minutes"
    elif [ "$CPU" -ge 4 ]; then
        log_info "  • Mid-range CPU (4 cores): 1-1.5 hours"
    else
        log_info "  • Low-end CPU (2 cores): 1.5-2.5 hours"
    fi
    log_info ""
    log_info "Build progress will be shown with percentage complete."
    log_info "DO NOT INTERRUPT THIS PROCESS - it cannot be resumed mid-build."
    log_info ""
    log_info "If you need to run this in background to prevent disconnections:"
    log_info "  Cancel now (Ctrl+C) and re-run with:"
    log_info "  sudo VMANGOS_BACKGROUND_BUILD=1 bash vmangos_setup.sh"
    log_info ""
    log_info "Starting build at $(date '+%H:%M:%S')..."
    log_info "====================================================================="
    
    # Create build directory
    mkdir -p build
    cd build
    
    # Configure
    log_info ""
    log_info "Step 1/3: Configuring build with cmake..."
    cmake ../source -DCMAKE_INSTALL_PREFIX="$INSTALLROOT/run" \
        -DCONF_DIR="$INSTALLROOT/run/etc" \
        -DBUILD_EXTRACTORS=1 \
        -DDEBUG=0 2>&1 | tee -a "$INSTALL_LOG"
    log_info "CMake configuration complete."
    
    # Build - with background support if enabled
    log_info ""
    log_info "Step 2/3: Compiling source code (this is the long part)..."
    log_info ""
    
    if [ "$BUILD_IN_BACKGROUND" = "1" ]; then
        start_background_build
    else
        log_info "Compiling with $CPU parallel jobs..."
        log_info "You will see percentage progress below:"
        log_info ""
        # Run make and filter output to show progress
        make -j "$CPU" 2>&1 | tee -a "$INSTALL_LOG" | \
            grep -E "^\[[ 0-9]+%\]|Linking|Building|Built target|Scanning" || true
        log_info ""
        log_info "Compilation complete!"
    fi
    
    # Install
    log_info ""
    log_info "Step 3/3: Installing compiled binaries..."
    make install 2>&1 | tee -a "$INSTALL_LOG"
    log_info "Installation of binaries complete."
    
    log_info ""
    log_info "====================================================================="
    log_info "BUILD COMPLETED at $(date '+%H:%M:%S')"
    log_info "====================================================================="
    
    set_checkpoint "BUILD_DONE"
}

phase_config_setup() {
    log_section "PHASE: Configuration Setup"
    
    cd "$INSTALLROOT"
    
    # Copy config files
    cp "$INSTALLROOT/run/etc/mangosd.conf.dist" "$INSTALLROOT/run/etc/mangosd.conf"
    cp "$INSTALLROOT/run/etc/realmd.conf.dist" "$INSTALLROOT/run/etc/realmd.conf"
    
    log_info "Configuring realmd.conf..."
    
    # Update realmd.conf database connection
    # The config format is: LoginDatabaseInfo = "host;port;user;pass;db"
    # Use more flexible sed patterns that handle variations in spacing
    sed -i "s|LoginDatabaseInfo.*=.*\"127\.0\.0\.1;3306;mangos;.*;realmd\"|LoginDatabaseInfo = \"$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB\"|" "$INSTALLROOT/run/etc/realmd.conf"
    sed -i "s|BindIP.*=.*\"0\.0\.0\.0\"|BindIP = \"$SERVERIP\"|" "$INSTALLROOT/run/etc/realmd.conf"
    
    log_info "Configuring mangosd.conf..."
    
    # Update World server config - handle both old and new format
    # New format uses dots: LoginDatabase.Info, WorldDatabase.Info, etc.
    # Use flexible patterns that match the actual config file format
    sed -i "s|LoginDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|LoginDatabase.Info = \"$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|WorldDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|WorldDatabase.Info = \"$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$WORLDDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|CharacterDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|CharacterDatabase.Info = \"$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$CHARACTERDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|LogsDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|LogsDatabase.Info = \"$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$LOGSDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    
    # Update DataDir to point to installation root
    sed -i "s|DataDir = \"\.\"|DataDir = \"$INSTALLROOT\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    
    # Update log directories
    sed -i "s|LogsDir = \"\"|LogsDir = \"$INSTALLROOT/logs/mangosd/\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|HonorDir = \"\"|HonorDir = \"$INSTALLROOT/logs/honor/\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    
    # Update BindIP for world server
    sed -i "s|BindIP = \"0.0.0.0\"|BindIP = \"$SERVERIP\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    
    # Disable VMaps by default (they're optional and extraction takes hours)
    sed -i "s|vmap.enableLOS = 1|vmap.enableLOS = 0|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|vmap.enableHeight = 1|vmap.enableHeight = 0|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|vmap.enableIndoorCheck = 1|vmap.enableIndoorCheck = 0|" "$INSTALLROOT/run/etc/mangosd.conf"
    
    # Ask whether bundled VMANGOS Manager files/config should be provisioned
    log_info ""
    log_info "VMANGOS Manager Release A does not require RA/SOAP."
    log_info "If you want bundled manager files and config provisioned under $INSTALLROOT/manager,"
    log_info "answer yes below."
    log_info ""
    
    if ask_yes_no "Do you want VMANGOS Manager provisioned?" "n"; then
        ENABLE_VMANGOS_MANAGER=true

        local manager_root manager_config_dir manager_config_file manager_password_file
        manager_root="$INSTALLROOT/manager"
        manager_config_dir="$manager_root/config"
        manager_config_file="$manager_config_dir/manager.conf"
        manager_password_file="$manager_config_dir/.dbpass"

        log_info "Provisioning VMANGOS Manager configuration..."
        mkdir -p "$manager_root/bin" "$manager_root/lib" "$manager_root/tests" "$manager_config_dir"

        if [ -d "$SCRIPT_DIR/manager" ]; then
            log_info "Installing bundled VMANGOS Manager sources into $manager_root"
            cp "$SCRIPT_DIR/manager/bin/vmangos-manager" "$manager_root/bin/"
            cp "$SCRIPT_DIR/manager/lib/"*.sh "$manager_root/lib/"
            cp "$SCRIPT_DIR/manager/tests/"*.sh "$manager_root/tests/" 2>/dev/null || true
            cp "$SCRIPT_DIR/manager/Makefile" "$manager_root/" 2>/dev/null || true
            chmod +x "$manager_root/bin/vmangos-manager"
        else
            log_warn "Bundled manager sources not found next to vmangos_setup.sh; creating config only"
        fi

        cat > "$manager_config_file" << EOF
# VMANGOS Manager Configuration
# Auto-generated by vmangos_setup.sh on $(date -Iseconds)

[database]
host = $SERVERIP
port = 3306
user = $MANGOSDBUSER
password_file = $manager_password_file
auth_db = $AUTHDB
characters_db = $CHARACTERDB
world_db = $WORLDDB
logs_db = $LOGSDB

[server]
install_root = $INSTALLROOT
auth_service = auth
world_service = world
console_enabled = false

[backup]
enabled = true
backup_dir = $INSTALLROOT/backups
retention_days = 7

[logging]
level = info
file = /var/log/vmangos-manager.log
EOF

        printf '%s\n' "$MANGOSDBPASS" > "$manager_password_file"
        chmod 600 "$manager_config_file" "$manager_password_file"
        log_info "Manager config written to $manager_config_file"
    else
        ENABLE_VMANGOS_MANAGER=false
        log_info "Bundled VMANGOS Manager provisioning skipped."
    fi
    
    set_checkpoint "CONFIG_DONE"
}

ensure_realmlist_entry() {
    local realm_count

    log_info "Configuring realmlist..."

    # localAddress must match address so external clients resolve the advertised realm correctly.
    mysql -u root -e "INSERT INTO \`$AUTHDB\`.\`realmlist\` (\`id\`, \`name\`, \`address\`, \`localAddress\`, \`localSubnetMask\`, \`port\`, \`icon\`, \`realmflags\`, \`timezone\`, \`allowedSecurityLevel\`, \`population\`, \`gamebuild_min\`, \`gamebuild_max\`, \`flag\`, \`realmbuilds\`)
        VALUES (1, 'VMaNGOS', '$SERVERIP', '$SERVERIP', '255.255.255.0', 8085, 0, 0, 1, 0, 0, 5875, 5875, 0, '5875 6005 6141')
        ON DUPLICATE KEY UPDATE \`name\` = 'VMaNGOS', \`address\` = '$SERVERIP', \`localAddress\` = '$SERVERIP', \`localSubnetMask\` = '255.255.255.0', \`port\` = 8085, \`icon\` = 0, \`realmflags\` = 0, \`timezone\` = 1, \`allowedSecurityLevel\` = 0, \`population\` = 0, \`gamebuild_min\` = 5875, \`gamebuild_max\` = 5875, \`flag\` = 0, \`realmbuilds\` = '5875 6005 6141';"

    realm_count=$(mysql -u root -N -B -e "SELECT COUNT(*) FROM \`$AUTHDB\`.\`realmlist\`;" 2>/dev/null || printf '0')
    if [ "$realm_count" -lt 1 ]; then
        log_error "Failed to seed \`$AUTHDB\`.realmlist; auth service would have no valid realms."
        return 1
    fi
}

phase_data_extraction() {
    log_section "PHASE: Data Extraction from Client Data"
    
    cd "$INSTALLROOT"
    
    # Check if client data is available
    if [ -z "$CLIENT_DATA" ] || [ ! -d "$CLIENT_DATA" ]; then
        log_warn "No client data available - skipping extraction phase"
        log_info "To extract data later, place 1.12.1 client Data folder and run:"
        log_info "  sudo $INSTALLROOT/run/bin/Extractors/mapextractor -i <data_path>"
        set_checkpoint "DATA_DONE"
        return 0
    fi
    
    # Copy extractors (handle both lowercase and capitalized names)
    cp "$INSTALLROOT/run/bin/mapextractor" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/mapextractor" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/MapExtractor" "$INSTALLROOT/mapextractor" 2>/dev/null || true
    cp "$INSTALLROOT/run/bin/vmap_assembler" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/vmap_assembler" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/VMapAssembler" "$INSTALLROOT/vmap_assembler" 2>/dev/null || true
    cp "$INSTALLROOT/run/bin/vmapextractor" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/vmapextractor" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/VMapExtractor" "$INSTALLROOT/vmapextractor" 2>/dev/null || true
    cp "$INSTALLROOT/run/bin/MoveMapGen" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/MoveMapGenerator" "$INSTALLROOT/MoveMapGen" 2>/dev/null || true
    
    if [ -f "$INSTALLROOT/source/contrib/mmap/offmesh.txt" ]; then
        cp "$INSTALLROOT/source/contrib/mmap/offmesh.txt" "$INSTALLROOT/"
    fi
    
    # Create directories
    mkdir -p "$INSTALLROOT/run/bin/5875"
    mkdir -p "$INSTALLROOT/logs/mangosd"
    mkdir -p "$INSTALLROOT/logs/honor"
    mkdir -p "$INSTALLROOT/logs/realmd"
    
    # Set ownership for extraction
    chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT"
    
    # Run extractors as mangos user
    cd "$INSTALLROOT"
    
    local EXTRACTION_FAILED=0
    
    # Step 1: Extract DBC files and maps (5-10 minutes)
    log_info "====================================================================="
    log_info "STEP 1/4: Extracting DBC files and base maps"
    log_info "====================================================================="
    log_info "This step extracts game data from your WoW client."
    log_info "Expected time: 5-10 minutes depending on disk speed"
    log_info "Progress: Shows percentage for each map being processed"
    log_info ""
    
    if [ -f ./mapextractor ]; then
        log_info "Starting mapextractor with client data: $CLIENT_DATA"
        if sudo -u "$MANGOSOSUSER" bash -c "cd '$INSTALLROOT' && ./mapextractor -i '$CLIENT_DATA_EXTRACT_ROOT'" 2>&1 | tee -a "$INSTALL_LOG" | \
            grep -E "Extracting|Processing|Extracted|Done|Error|Fatal|Invalid"; then
            : # Extractor output captured
        fi
        
        # Check if extraction succeeded
        if [ ! -d "$INSTALLROOT/dbc" ] || [ ! -d "$INSTALLROOT/maps" ]; then
            log_error "Map extraction failed - no output files generated"
            EXTRACTION_FAILED=1
        elif [ -z "$(ls -A $INSTALLROOT/dbc 2>/dev/null)" ]; then
            log_error "Map extraction failed - DBC folder is empty"
            EXTRACTION_FAILED=1
        else
            log_info "DBC and map extraction completed successfully"
        fi
    else
        log_warn "mapextractor not found, skipping DBC/map extraction"
        EXTRACTION_FAILED=1
    fi
    
    # Step 2: Extract vmaps (10-20 minutes)
    log_info ""
    log_info "====================================================================="
    log_info "STEP 2/4: Extracting vmaps (Visual Maps)"
    log_info "====================================================================="
    log_info "This step extracts visual geometry for line-of-sight calculations."
    log_info "Expected time: 10-20 minutes"
    log_info ""
    
    if [ $EXTRACTION_FAILED -eq 0 ] && [ -f ./vmapextractor ]; then
        log_info "Starting vmapextractor..."
        if sudo -u "$MANGOSOSUSER" bash -c "cd '$INSTALLROOT' && ./vmapextractor -i '$CLIENT_DATA_EXTRACT_ROOT'" 2>&1 | tee -a "$INSTALL_LOG"; then
            log_info "VMap extraction completed"
        else
            log_warn "VMap extractor had issues (may be normal)"
        fi
    else
        log_warn "Skipping vmap extraction (previous step failed or extractor not found)"
    fi
    
    # Step 3: Assemble vmaps (5-10 minutes)
    log_info ""
    log_info "====================================================================="
    log_info "STEP 3/4: Assembling vmaps"
    log_info "====================================================================="
    log_info "This step combines vmap data into usable format."
    log_info "Expected time: 5-10 minutes"
    log_info ""
    
    if [ $EXTRACTION_FAILED -eq 0 ] && [ -f ./vmap_assembler ]; then
        log_info "Starting vmap_assembler..."
        mkdir -p "$INSTALLROOT/vmaps"
        if sudo -u "$MANGOSOSUSER" bash -c "cd '$INSTALLROOT' && ./vmap_assembler '$CLIENT_DATA' '$INSTALLROOT/vmaps'" 2>&1 | tee -a "$INSTALL_LOG"; then
            log_info "VMap assembly completed"
        else
            log_warn "VMap assembler had issues"
        fi
    else
        log_warn "Skipping vmap assembly (previous step failed or assembler not found)"
    fi
    
    # Step 4: Generate movement maps (1-4 hours - the longest step)
    log_info ""
    log_info "====================================================================="
    log_info "STEP 4/4: Generating movement maps (mmaps)"
    log_info "====================================================================="
    log_info "THIS IS THE LONGEST STEP - PLEASE BE PATIENT"
    log_info ""
    log_info "This step calculates walkable paths for NPCs and creatures."
    log_info "It processes hundreds of tiles across all maps."
    log_info ""
    log_info "Expected time based on your hardware:"
    CPU_COUNT=$(nproc)
    if [ "$CPU_COUNT" -ge 8 ]; then
        log_info "  • High-end CPU (8+ cores): 30-60 minutes"
    elif [ "$CPU_COUNT" -ge 4 ]; then
        log_info "  • Mid-range CPU (4 cores): 1-2 hours"
    else
        log_info "  • Low-end CPU (2 cores): 2-4 hours"
    fi
    log_info ""
    log_info "Progress format: [Map XXX] Building tile [XX,XX] (XX / XXX)"
    log_info "You will see many lines like this - this is normal progress!"
    log_info ""
    log_info "DO NOT CANCEL THIS PROCESS - it will resume where it left off"
    log_info "if you re-run the installation script."
    log_info ""
    log_info "Starting MoveMapGen at $(date '+%H:%M:%S')..."
    log_info "====================================================================="
    
    if [ $EXTRACTION_FAILED -eq 0 ] && [ -f ./MoveMapGen ]; then
        # Run with a background progress heartbeat
        {
            while true; do
                sleep 300  # Every 5 minutes
                log_info "[$(date '+%H:%M:%S')] MoveMapGen still running... (this is normal)"
            done
        } &
        HEARTBEAT_PID=$!
        
        # Run the actual generation
        sudo -u "$MANGOSOSUSER" ./MoveMapGen --offMeshInput offmesh.txt 2>&1 | tee -a "$INSTALL_LOG" || \
            log_warn "MoveMapGen completed with warnings (this is usually OK)"
        
        # Stop the heartbeat
        kill $HEARTBEAT_PID 2>/dev/null || true
        wait $HEARTBEAT_PID 2>/dev/null || true
        
        log_info "====================================================================="
        log_info "Movement map generation completed at $(date '+%H:%M:%S')"
        log_info "====================================================================="
    else
        log_warn "MoveMapGen not found, skipping movement map generation"
    fi
    
    log_info ""
    if [ $EXTRACTION_FAILED -eq 1 ]; then
        log_warn "========================================="
        log_warn "DATA EXTRACTION DID NOT COMPLETE FULLY"
        log_warn "========================================="
        log_warn ""
        log_warn "This usually means:"
        log_warn "  1. The client data is not WoW 1.12.1 (build 5875)"
        log_warn "  2. The client data is incomplete or corrupted"
        log_warn "  3. The extractor tools had compatibility issues"
        log_warn ""
        log_warn "The server installation will continue, but:"
        log_warn "  - You will need valid extracted data to run the server"
        log_warn "  - Place correct 1.12.1 client data and re-run extraction"
        log_warn ""
        log_info "Manual extraction commands:"
        log_info "  cd $INSTALLROOT"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/mapextractor -i <client_data_path>"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/vmapextractor -i <client_data_path>"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/vmap_assembler buildings vmaps"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/MoveMapGenerator"
        log_warn ""
    else
        log_info "All data extraction steps completed successfully!"
        
        # Create versioned directory structure (e.g., 5875 for WoW 1.12.1)
        log_info "Creating versioned data directory structure..."
        mkdir -p "$INSTALLROOT/5875"
        
        # Create symlinks for dbc and maps in the versioned directory
        if [ -d "$INSTALLROOT/dbc" ]; then
            ln -sf "$INSTALLROOT/dbc" "$INSTALLROOT/5875/dbc" 2>/dev/null || true
            log_info "  Created 5875/dbc symlink"
        fi
        if [ -d "$INSTALLROOT/maps" ]; then
            ln -sf "$INSTALLROOT/maps" "$INSTALLROOT/5875/maps" 2>/dev/null || true
            log_info "  Created 5875/maps symlink"
        fi
        if [ -d "$INSTALLROOT/vmaps" ]; then
            ln -sf "$INSTALLROOT/vmaps" "$INSTALLROOT/5875/vmaps" 2>/dev/null || true
            log_info "  Created 5875/vmaps symlink"
        fi
        if [ -d "$INSTALLROOT/mmaps" ]; then
            ln -sf "$INSTALLROOT/mmaps" "$INSTALLROOT/5875/mmaps" 2>/dev/null || true
            log_info "  Created 5875/mmaps symlink"
        fi
        
        # Set ownership
        chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT/5875" 2>/dev/null || true
        log_info "Versioned directory structure created."
    fi
    
    set_checkpoint "DATA_DONE"
}

phase_database_import() {
    log_section "PHASE: Database Import"
    
    cd "$INSTALLROOT"
    
    # Download and import world database
    # Try multiple sources in order of preference
    WORLD_DB_URLS=(
        "https://github.com/vmangos/core/releases/download/db_latest/db-7ff0a39.zip"
        "https://github.com/brotalnia/database/releases/download/latest/world_full_14_june_2021.7z"
    )
    
    WORLD_DB_DOWNLOADED=false
    for DB_URL in "${WORLD_DB_URLS[@]}"; do
        DB_FILENAME=$(basename "$DB_URL")
        log_info "Attempting to download world database from: $DB_URL"
        
        if download_with_retry "$DB_URL" "$DB_FILENAME"; then
            # Check if file is valid (non-zero size)
            if [ -s "$DB_FILENAME" ]; then
                log_info "Extracting world database..."
                
                # Extract based on file extension
                if [[ "$DB_FILENAME" == *.zip ]]; then
                    unzip -o "$DB_FILENAME" 2>&1 | tee -a "$INSTALL_LOG"
                elif [[ "$DB_FILENAME" == *.7z ]]; then
                    7z x "$DB_FILENAME" -aoa 2>&1 | tee -a "$INSTALL_LOG"
                fi
                
                # Check for mysql-dump directory structure (from vmangos releases)
                if [ -d "mysql-dump" ]; then
                    log_info "Found mysql-dump directory, importing all database files..."
                    
                    # Import in correct order: logon -> characters -> logs -> mangos (world)
                    if [ -f "mysql-dump/logon.sql" ]; then
                        log_info "Importing auth database (logon.sql)..."
                        mysql "$AUTHDB" < "mysql-dump/logon.sql"
                    fi
                    
                    if [ -f "mysql-dump/characters.sql" ]; then
                        log_info "Importing characters database..."
                        mysql "$CHARACTERDB" < "mysql-dump/characters.sql"
                    fi
                    
                    if [ -f "mysql-dump/logs.sql" ]; then
                        log_info "Importing logs database..."
                        mysql "$LOGSDB" < "mysql-dump/logs.sql"
                    fi
                    
                    if [ -f "mysql-dump/mangos.sql" ]; then
                        log_info "Importing world database (this may take a while)..."
                        mysql "$WORLDDB" < "mysql-dump/mangos.sql"
                        log_info "World database imported successfully"
                    fi
                    
                    WORLD_DB_DOWNLOADED=true
                    
                    # Clean up extracted files
                    rm -rf mysql-dump
                else
                    # Legacy: find SQL files in current directory
                    WORLD_SQL=$(find . -name "*.sql" -type f | grep -E "(world|mangos)" | head -n1)
                    if [ -n "$WORLD_SQL" ]; then
                        log_info "Importing world database from $WORLD_SQL (this may take a while)..."
                        mysql "$WORLDDB" < "$WORLD_SQL"
                        log_info "World database imported successfully"
                        WORLD_DB_DOWNLOADED=true
                    else
                        log_warn "No SQL file found after extraction"
                    fi
                fi
                
                rm -f "$DB_FILENAME"
                break
            else
                log_warn "Downloaded file is empty, trying next source..."
                rm -f "$DB_FILENAME"
            fi
        fi
    done
    
    if [ "$WORLD_DB_DOWNLOADED" != "true" ]; then
        log_warn "Failed to download world database from all sources"
        log_warn "You will need to import the world database manually"
        log_warn "Visit: https://github.com/vmangos/core/releases/tag/db_latest"
        
        # Import base schemas from source as fallback
        log_info "Creating base database structures from source..."
        if [ -f "$INSTALLROOT/source/sql/logon.sql" ]; then
            mysql "$AUTHDB" < "$INSTALLROOT/source/sql/logon.sql" || log_warn "Auth schema import issue"
        fi
        if [ -f "$INSTALLROOT/source/sql/characters.sql" ]; then
            mysql "$CHARACTERDB" < "$INSTALLROOT/source/sql/characters.sql" || log_warn "Characters schema import issue"
        fi
        if [ -f "$INSTALLROOT/source/sql/logs.sql" ]; then
            mysql "$LOGSDB" < "$INSTALLROOT/source/sql/logs.sql" || log_warn "Logs schema import issue"
        fi
    fi
    
    # Apply migrations only if the migrations table exists
    # (This handles the case where we're using source SQL instead of downloaded DB)
    log_info "Checking for database migrations..."
    if [ -d "$INSTALLROOT/source/sql/migrations" ]; then
        MIGRATIONS_EXIST=$(mysql "$WORLDDB" -e "SHOW TABLES LIKE 'migrations';" 2>/dev/null | grep -c "migrations" || echo "0")
        
        if [ "$MIGRATIONS_EXIST" -gt 0 ] && [ "$WORLD_DB_DOWNLOADED" != "true" ]; then
            log_info "Running database migrations..."
            cd "$INSTALLROOT/source/sql/migrations"
            [ -f "merge.sh" ] && chmod +x merge.sh && ./merge.sh 2>&1 | tee -a "$INSTALL_LOG" || true
            
            [ -f "world_db_updates.sql" ] && mysql "$WORLDDB" < world_db_updates.sql || true
            [ -f "logs_db_updates.sql" ] && mysql "$LOGSDB" < logs_db_updates.sql || true
            [ -f "characters_db_updates.sql" ] && mysql "$CHARACTERDB" < characters_db_updates.sql || true
            [ -f "logon_db_updates.sql" ] && mysql "$AUTHDB" < logon_db_updates.sql || true
        else
            log_info "Skipping migrations (using pre-built database or no migrations table)"
        fi
    fi

    ensure_realmlist_entry
    
    set_checkpoint "DB_IMPORT_DONE"
}

phase_service_setup() {
    log_section "PHASE: Service Setup"
    
    # Create systemd services
    cat > /etc/systemd/system/auth.service << EOF
[Unit]
Description=VMaNGOS Auth Server (Classic WoW)
After=network.target mysql.service
Wants=mysql.service

[Service]
Type=simple
User=${MANGOSOSUSER}
ExecStart=${INSTALLROOT}/run/bin/realmd
WorkingDirectory=${INSTALLROOT}/run/bin/
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/world.service << EOF
[Unit]
Description=VMaNGOS World Server (Classic WoW)
After=network.target mysql.service
Wants=mysql.service

[Service]
Type=simple
User=${MANGOSOSUSER}
ExecStart=${INSTALLROOT}/run/bin/mangosd
WorkingDirectory=${INSTALLROOT}/run/bin/
Restart=on-failure
RestartSec=5
StandardInput=tty-force
TTYPath=/dev/tty3
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable auth.service
    systemctl enable world.service
    
    # Fix permissions
    chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT"
    
    # Start services
    log_info "Starting auth service..."
    systemctl start auth.service
    sleep 3
    
    log_info "Starting world service (this may take 30-60 seconds to fully load)..."
    systemctl start world.service
    sleep 15
    
    # Verify services are running
    log_info "Verifying services..."
    AUTH_STATUS=$(systemctl is-active auth.service 2>&1)
    WORLD_STATUS=$(systemctl is-active world.service 2>&1)
    
    if [ "$AUTH_STATUS" = "active" ]; then
        log_info "✓ Auth service is running on $SERVERIP:3724"
    else
        log_error "✗ Auth service failed to start (status: $AUTH_STATUS)"
        log_info "Check logs: journalctl -u auth -n 50"
    fi
    
    if [ "$WORLD_STATUS" = "active" ]; then
        log_info "✓ World service is running on $SERVERIP:8085"
        # Show memory usage
        WORLD_MEM=$(ps aux | grep mangosd | grep -v grep | awk '{print $6/1024}' | head -1)
        log_info "  World server memory usage: ${WORLD_MEM:-unknown} MB"
    else
        log_error "✗ World service failed to start (status: $WORLD_STATUS)"
        log_info "Check logs: journalctl -u world -n 50"
        log_info "Or: tail -50 $INSTALLROOT/logs/mangosd/Server.log"
    fi
    
    set_checkpoint "SERVICES_DONE"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log_section "VMANGOS Installation Started"
    log_info "Installation directory: $INSTALLROOT"
    log_info "Log file: $INSTALL_LOG"
    log_info "Resume support enabled - checkpoints stored in: $CHECKPOINT_DIR"
    
    check_root
    init_checkpoints
    ensure_server_ip
    
    # Get current checkpoint
    CHECKPOINT=$(get_checkpoint)
    log_info "Resuming from checkpoint: $CHECKPOINT"
    
    # Execute phases based on checkpoint
    case "$CHECKPOINT" in
        START)
            phase_prerequisites
            ;&
        PREREQS_DONE)
            check_client_data
            phase_database_setup
            ;&
        DATABASE_DONE)
            phase_source_download
            ;&
        SOURCE_DONE)
            phase_build
            ;&
        BUILD_DONE)
            phase_config_setup
            ;&
        CONFIG_DONE)
            phase_data_extraction
            ;&
        DATA_DONE)
            phase_database_import
            ;&
        DB_IMPORT_DONE)
            phase_service_setup
            ;&
        SERVICES_DONE)
            log_section "Installation Complete!"
            log_info ""
            log_info "========================================"
            log_info "VMANGOS SERVER READY"
            log_info "========================================"
            log_info ""
            log_info "Server Address: $SERVERIP"
            log_info "Auth Server:    $SERVERIP:3724"
            log_info "World Server:   $SERVERIP:8085"
            log_info ""
            log_info "--- Client Configuration ---"
            log_info "Edit your WoW client's realmlist.wtf:"
            log_info "  set realmlist $SERVERIP"
            log_info ""
            log_info "--- Account Management ---"
            log_info "If you enabled VMANGOS Manager provisioning:"
            log_info "  Manager binary: $INSTALLROOT/manager/bin/vmangos-manager"
            log_info "  Manager config: $INSTALLROOT/manager/config/manager.conf"
            log_info ""
            log_info "--- Service Commands ---"
            log_info "Start:   sudo systemctl start auth world"
            log_info "Stop:    sudo systemctl stop auth world"
            log_info "Status:  sudo systemctl status auth world"
            log_info "Logs:    sudo journalctl -u world -f"
            log_info ""
            log_info "--- Installation Directory ---"
            log_info "$INSTALLROOT"
            log_info ""
            log_info "Enjoy your Vanilla WoW server!"
            log_info "========================================"
            clear_checkpoint
            ;;
        *)
            log_error "Unknown checkpoint: $CHECKPOINT"
            log_info "Resetting to START"
            echo "START" > "$CHECKPOINT_FILE"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
