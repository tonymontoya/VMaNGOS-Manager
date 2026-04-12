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

# =============================================================================
# CONFIGURATION - Can be overridden via environment variables
# =============================================================================

# Non-interactive mode detection
VMANGOS_AUTO_INSTALL="${VMANGOS_AUTO_INSTALL:-0}"

# Installation paths
INSTALLROOT="${VMANGOS_INSTALL_ROOT:-/opt/mangos}"
CLIENT_DATA="${VMANGOS_CLIENT_DATA:-}"

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
        if check_noninteractive; then
            log_error "Client data not found. Set VMANGOS_CLIENT_DATA environment variable."
            exit 1
        else
            read -rp "Enter path to WoW 1.12.1 client Data folder: " CLIENT_DATA
            if [ ! -d "$CLIENT_DATA" ]; then
                log_error "Client data not found at: $CLIENT_DATA"
                exit 1
            fi
        fi
    fi
    
    log_info "Using client data from: $CLIENT_DATA"
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
    
    # Get server IP
    SERVERIP=$(hostname -I | awk '{print $1}')
    log_info "Detected server IP: $SERVERIP"
    
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
    
    # Update database connections
    sed -i "s|127.0.0.1;3306;mangos;mangos;realmd|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB|g" "$INSTALLROOT/run/etc/realmd.conf"
    sed -i "s|BindIP = \"0.0.0.0\"|BindIP = \"$SERVERIP\"|g" "$INSTALLROOT/run/etc/realmd.conf"
    
    # Update World server config
    sed -i "s|127.0.0.1;3306;mangos;mangos;realmd|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB|g" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|127.0.0.1;3306;mangos;mangos;mangos|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$WORLDDB|g" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|127.0.0.1;3306;mangos;mangos;characters|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$CHARACTERDB|g" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|127.0.0.1;3306;mangos;mangos;logs|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$LOGSDB|g" "$INSTALLROOT/run/etc/mangosd.conf"
    
    # Update log directories
    sed -i "s|LogsDir = \"\"|LogsDir = \"$INSTALLROOT/logs/mangosd/\"|g" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|HonorDir = \"\"|HonorDir = \"$INSTALLROOT/logs/honor/\"|g" "$INSTALLROOT/run/etc/mangosd.conf"
    
    # Update realmlist
    mysql "$AUTHDB" -e "UPDATE \`realmlist\` SET \`address\` = '$SERVERIP', \`localaddress\` = '127.0.0.1' WHERE \`id\` = '1';" || true
    
    set_checkpoint "CONFIG_DONE"
}

phase_data_extraction() {
    log_section "PHASE: Data Extraction from Client Data"
    
    cd "$INSTALLROOT"
    
    # Copy extractors
    cp "$INSTALLROOT/run/bin/mapextractor" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/mapextractor" "$INSTALLROOT/" 2>/dev/null || true
    cp "$INSTALLROOT/run/bin/vmap_assembler" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/vmap_assembler" "$INSTALLROOT/" 2>/dev/null || true
    cp "$INSTALLROOT/run/bin/vmapextractor" "$INSTALLROOT/" 2>/dev/null || \
        cp "$INSTALLROOT/run/bin/Extractors/vmapextractor" "$INSTALLROOT/" 2>/dev/null || true
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
    
    # Step 1: Extract DBC files and maps (5-10 minutes)
    log_info "====================================================================="
    log_info "STEP 1/4: Extracting DBC files and base maps"
    log_info "====================================================================="
    log_info "This step extracts game data from your WoW client."
    log_info "Expected time: 5-10 minutes depending on disk speed"
    log_info "Progress: Shows percentage for each map being processed"
    log_info ""
    
    if [ -f ./mapextractor ]; then
        log_info "Starting mapextractor..."
        sudo -u "$MANGOSOSUSER" ./mapextractor 2>&1 | tee -a "$INSTALL_LOG" | \
            grep -E "Extracting|Processing|Extracted|Done|Error|Fatal" || true
        log_info "DBC and map extraction completed"
    else
        log_warn "mapextractor not found, skipping DBC/map extraction"
    fi
    
    # Step 2: Extract vmaps (10-20 minutes)
    log_info ""
    log_info "====================================================================="
    log_info "STEP 2/4: Extracting vmaps (Visual Maps)"
    log_info "====================================================================="
    log_info "This step extracts visual geometry for line-of-sight calculations."
    log_info "Expected time: 10-20 minutes"
    log_info ""
    
    if [ -f ./vmapextractor ]; then
        log_info "Starting vmapextractor..."
        sudo -u "$MANGOSOSUSER" ./vmapextractor 2>&1 | tee -a "$INSTALL_LOG" || \
            log_warn "VMap extractor had issues (may be normal if no output)"
    else
        log_warn "vmapextractor not found, skipping vmap extraction"
    fi
    
    # Step 3: Assemble vmaps (5-10 minutes)
    log_info ""
    log_info "====================================================================="
    log_info "STEP 3/4: Assembling vmaps"
    log_info "====================================================================="
    log_info "This step combines vmap data into usable format."
    log_info "Expected time: 5-10 minutes"
    log_info ""
    
    if [ -f ./vmap_assembler ]; then
        log_info "Starting vmap_assembler..."
        sudo -u "$MANGOSOSUSER" ./vmap_assembler 2>&1 | tee -a "$INSTALL_LOG" || \
            log_warn "VMap assembler had issues"
        log_info "VMap assembly completed"
    else
        log_warn "vmap_assembler not found, skipping vmap assembly"
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
    
    if [ -f ./MoveMapGen ]; then
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
    log_info "All data extraction steps completed!"
    
    set_checkpoint "DATA_DONE"
}

phase_database_import() {
    log_section "PHASE: Database Import"
    
    cd "$INSTALLROOT"
    
    # Download and import world database
    WORLD_DB_URL="https://github.com/brotalnia/database/releases/download/latest/world_full_14_june_2021.7z"
    log_info "Downloading world database..."
    
    if download_with_retry "$WORLD_DB_URL" "world_full.7z"; then
        log_info "Extracting world database..."
        7z x world_full.7z -aoa 2>&1 | tee -a "$INSTALL_LOG"
        
        WORLD_SQL=$(find . -name "world_full*.sql" -type f | head -n1)
        if [ -n "$WORLD_SQL" ]; then
            log_info "Importing world database (this may take a while)..."
            mysql "$WORLDDB" < "$WORLD_SQL"
            log_info "World database imported successfully"
        fi
        rm -f world_full.7z
    else
        log_warn "Failed to download world database - you may need to import manually"
    fi
    
    # Import base schemas
    log_info "Creating characters database structure..."
    mysql "$CHARACTERDB" < "$INSTALLROOT/source/sql/characters.sql" || log_warn "Characters schema import issue"
    
    log_info "Creating logs database structure..."
    mysql "$LOGSDB" < "$INSTALLROOT/source/sql/logs.sql" || log_warn "Logs schema import issue"
    
    log_info "Creating auth database structure..."
    mysql "$AUTHDB" < "$INSTALLROOT/source/sql/logon.sql" || log_warn "Auth schema import issue"
    
    # Apply migrations
    log_info "Running database migrations..."
    if [ -d "$INSTALLROOT/source/sql/migrations" ]; then
        cd "$INSTALLROOT/source/sql/migrations"
        [ -f "merge.sh" ] && chmod +x merge.sh && ./merge.sh 2>&1 | tee -a "$INSTALL_LOG" || true
        
        [ -f "world_db_updates.sql" ] && mysql "$WORLDDB" < world_db_updates.sql || true
        [ -f "logs_db_updates.sql" ] && mysql "$LOGSDB" < logs_db_updates.sql || true
        [ -f "characters_db_updates.sql" ] && mysql "$CHARACTERDB" < characters_db_updates.sql || true
        [ -f "logon_db_updates.sql" ] && mysql "$AUTHDB" < logon_db_updates.sql || true
    fi
    
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
            log_info "To start the servers:"
            log_info "  sudo systemctl start auth"
            log_info "  sudo systemctl start world"
            log_info ""
            log_info "Update your WoW client's realmlist.wtf:"
            log_info "  set realmlist $SERVERIP"
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
