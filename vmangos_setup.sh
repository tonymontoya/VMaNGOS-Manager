#!/bin/bash
# =============================================================================
# VMANGOS Setup Script - Ubuntu LTS (22.04/24.04/26.04)
# =============================================================================
# This script automates the installation of VMaNGOS (Vanilla MaNGOS)
# onto Ubuntu LTS (22.04/24.04/26.04, MariaDB or MySQL 8.4). It includes:
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
VMANGOS_PROVISION_TARGET="${VMANGOS_PROVISION_TARGET:-}"
VMANGOS_INPUT_MODE="${VMANGOS_INPUT_MODE:-}"

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
INSTALLER_STATE_FILE=""

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
# STRUCTURED PROGRESS MARKERS (protocol "@@VMANGOS v1")
#
# Markers are stdout-only: the journal (systemd-run) is the marker channel,
# never the install log. One marker per line; values containing spaces are
# double-quoted. Parsers grep for the literal prefix "@@VMANGOS v1".
# =============================================================================

log_marker() {
    local phase="$1" event="$2"
    shift 2
    local out="@@VMANGOS v1 phase=${phase} event=${event}"
    local kv key value
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        if [[ "$value" == *' '* || "$value" == *'"'* ]]; then
            value="${value//\"/\\\"}"
            value="\"${value}\""
        fi
        out="${out} ${key}=${value}"
    done
    printf '%s\n' "$out"
}

# fail_marker <phase> <msg> <hint>: the guarded-failure shape shared by every
# phase death path. Always returns non-zero so `cmd || { fail_marker ...;
# return 1; }` fails the phase even when errexit is suppressed (tests rely on
# that). warn_marker <phase> <msg>: something failed but the install continues;
# always returns zero so the guarded command's failure stays swallowed.
fail_marker() {
    log_marker "$1" error "msg=$2" "hint=$3"
    return 1
}

warn_marker() {
    log_marker "$1" warn "msg=$2"
    return 0
}

refresh_runtime_paths() {
    CHECKPOINT_DIR="${INSTALLROOT}/.install-checkpoints"
    CHECKPOINT_FILE="${CHECKPOINT_DIR}/checkpoint"
    INSTALLER_STATE_FILE="${CHECKPOINT_DIR}/installer.env"
}

refresh_runtime_paths

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

prompt_with_default() {
    local question="$1"
    local current_value="$2"
    local result_var="$3"
    local response

    read -rp "$question [$current_value]: " response
    printf -v "$result_var" '%s' "${response:-$current_value}"
}

prompt_with_optional_default() {
    local question="$1"
    local current_value="$2"
    local placeholder="$3"
    local result_var="$4"
    local response

    if [ -n "$current_value" ]; then
        read -rp "$question [$current_value]: " response
        printf -v "$result_var" '%s' "${response:-$current_value}"
    else
        read -rp "$question [$placeholder]: " response
        printf -v "$result_var" '%s' "$response"
    fi
}

installer_target_is_valid() {
    case "${1:-}" in
        vmangos_only|vmangos_manager)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

installer_mode_is_valid() {
    case "${1:-}" in
        automated|guided)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

installer_target_label() {
    case "${1:-}" in
        vmangos_only)
            printf 'VMANGOS only'
            ;;
        vmangos_manager)
            printf 'VMANGOS + Manager'
            ;;
        *)
            printf '%s' "${1:-unknown}"
            ;;
    esac
}

installer_mode_label() {
    case "${1:-}" in
        automated)
            printf 'Automated'
            ;;
        guided)
            printf 'Guided'
            ;;
        *)
            printf '%s' "${1:-unknown}"
            ;;
    esac
}

validate_installer_selection() {
    if ! installer_target_is_valid "$VMANGOS_PROVISION_TARGET"; then
        log_error "Invalid VMANGOS_PROVISION_TARGET: ${VMANGOS_PROVISION_TARGET:-unset}"
        log_info "Expected one of: vmangos_only, vmangos_manager"
        exit 1
    fi

    if ! installer_mode_is_valid "$VMANGOS_INPUT_MODE"; then
        log_error "Invalid VMANGOS_INPUT_MODE: ${VMANGOS_INPUT_MODE:-unset}"
        log_info "Expected one of: automated, guided"
        exit 1
    fi

    if check_noninteractive && [ "$VMANGOS_INPUT_MODE" != "automated" ]; then
        log_error "Non-interactive installs require VMANGOS_INPUT_MODE=automated"
        exit 1
    fi
}

select_installer_target() {
    local choice

    if [ -n "$VMANGOS_PROVISION_TARGET" ]; then
        return 0
    fi

    if check_noninteractive; then
        VMANGOS_PROVISION_TARGET="vmangos_manager"
        return 0
    fi

    log_section "INSTALLER TARGET"
    log_info "Choose what this host should provision:"
    log_info "  1) VMANGOS only"
    log_info "  2) VMANGOS + Manager"

    while true; do
        read -rp "Provisioning target [2]: " choice
        case "${choice:-2}" in
            1)
                VMANGOS_PROVISION_TARGET="vmangos_only"
                break
                ;;
            2)
                VMANGOS_PROVISION_TARGET="vmangos_manager"
                break
                ;;
            *)
                echo "Please choose 1 or 2."
                ;;
        esac
    done
}

select_input_mode() {
    local choice

    if [ -n "$VMANGOS_INPUT_MODE" ]; then
        return 0
    fi

    if check_noninteractive; then
        VMANGOS_INPUT_MODE="automated"
        return 0
    fi

    log_section "INSTALLER INPUT MODE"
    log_info "Choose how values should be supplied:"
    log_info "  1) Automated (defaults and auto-detected values)"
    log_info "  2) Guided (prompt for key install values)"

    while true; do
        read -rp "Input mode [2]: " choice
        case "${choice:-2}" in
            1)
                VMANGOS_INPUT_MODE="automated"
                break
                ;;
            2)
                VMANGOS_INPUT_MODE="guided"
                break
                ;;
            *)
                echo "Please choose 1 or 2."
                ;;
        esac
    done
}

prompt_guided_install_root() {
    if [ "$VMANGOS_INPUT_MODE" != "guided" ] || check_noninteractive; then
        return 0
    fi

    log_section "GUIDED INSTALL ROOT"
    prompt_with_default "Install root" "$INSTALLROOT" INSTALLROOT
    refresh_runtime_paths
}

load_installer_state() {
    if [ "$VMANGOS_INPUT_MODE" != "guided" ] || check_noninteractive; then
        return 0
    fi

    if [ ! -f "$INSTALLER_STATE_FILE" ]; then
        return 0
    fi

    # shellcheck source=/dev/null
    source "$INSTALLER_STATE_FILE"
    log_info "Loaded installer state from $INSTALLER_STATE_FILE"
}

save_installer_state() {
    if [ "$VMANGOS_INPUT_MODE" != "guided" ] || check_noninteractive; then
        return 0
    fi

    mkdir -p "$CHECKPOINT_DIR"
    cat > "$INSTALLER_STATE_FILE" << EOF
VMANGOS_PROVISION_TARGET=$(printf '%q' "$VMANGOS_PROVISION_TARGET")
VMANGOS_INPUT_MODE=$(printf '%q' "$VMANGOS_INPUT_MODE")
CLIENT_DATA=$(printf '%q' "$CLIENT_DATA")
SQLADMINUSER=$(printf '%q' "$SQLADMINUSER")
SQLADMINIP=$(printf '%q' "$SQLADMINIP")
SQLADMINPASS=$(printf '%q' "$SQLADMINPASS")
AUTHDB=$(printf '%q' "$AUTHDB")
WORLDDB=$(printf '%q' "$WORLDDB")
CHARACTERDB=$(printf '%q' "$CHARACTERDB")
LOGSDB=$(printf '%q' "$LOGSDB")
MANGOSDBUSER=$(printf '%q' "$MANGOSDBUSER")
MANGOSDBPASS=$(printf '%q' "$MANGOSDBPASS")
MANGOSOSUSER=$(printf '%q' "$MANGOSOSUSER")
SKIP_SECURE_MYSQL=$(printf '%q' "$SKIP_SECURE_MYSQL")
SERVERIP=$(printf '%q' "$SERVERIP")
EOF
}

prompt_guided_values() {
    if [ "$VMANGOS_INPUT_MODE" != "guided" ] || check_noninteractive; then
        return 0
    fi

    log_section "GUIDED INSTALL SETTINGS"
    prompt_with_optional_default "Client data path" "$CLIENT_DATA" "auto-detect/skip" CLIENT_DATA
    prompt_with_default "Auth database name" "$AUTHDB" AUTHDB
    prompt_with_default "World database name" "$WORLDDB" WORLDDB
    prompt_with_default "Characters database name" "$CHARACTERDB" CHARACTERDB
    prompt_with_default "Logs database name" "$LOGSDB" LOGSDB
    prompt_with_default "VMANGOS DB user" "$MANGOSDBUSER" MANGOSDBUSER
    prompt_with_default "VMANGOS DB password" "$MANGOSDBPASS" MANGOSDBPASS
    prompt_with_default "VMANGOS OS user" "$MANGOSOSUSER" MANGOSOSUSER
}

announce_installer_selection() {
    log_info "Provisioning target: $(installer_target_label "$VMANGOS_PROVISION_TARGET")"
    log_info "Input mode: $(installer_mode_label "$VMANGOS_INPUT_MODE")"
}

installer_should_provision_manager() {
    [ "$VMANGOS_PROVISION_TARGET" = "vmangos_manager" ]
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
    local spinstr='|/-+'
    
    printf "%s " "$message"
    while [ -d "/proc/$pid" ]; do
        local temp=${spinstr#?}
        printf " [%c]" "$spinstr"
        local spinstr=$temp${spinstr%%"$temp"}
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
    local retry_delay="${VMANGOS_DOWNLOAD_RETRY_DELAY:-5}"
    local wget_rc=0

    for i in $(seq 1 $max_retries); do
        log_info "Download attempt $i/$max_retries: $url"
        # -q: suppress progress output. Writing progress through a pipe can
        # make wget detach to wget-log.N, leaving the -O file empty. -q also
        # keeps tee out of the pipeline so wget's own exit code is not masked.
        if timeout 300 wget -q --tries=1 --timeout=60 -O "$output" "$url"; then
            if [ -s "$output" ]; then
                log_info "Download successful"
                return 0
            fi
            log_warn "Downloaded file is empty"
        else
            wget_rc=$?
            log_warn "wget exited with status $wget_rc"
        fi
        rm -f "$output"
        log_warn "Download failed, waiting ${retry_delay}s before retry..."
        sleep "$retry_delay"
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
set -o pipefail
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
    if wait "$BUILD_PID"; then
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
        local patch_size
        patch_size=$(stat -c%s "$data_path/patch.MPQ" 2>/dev/null || echo 0)
        if [ "$patch_size" -lt 1000000000 ]; then
            log_warn "patch.MPQ seems too small ($patch_size bytes) - expected ~1.9GB"
            log_warn "This may not be a valid 1.12.1 client"
            ((errors++))
        else
            log_info "patch.MPQ size looks correct ($(numfmt --to=iec "$patch_size"))"
        fi
    else
        log_warn "Missing patch.MPQ"
        ((errors++))
    fi
    
    # Test extraction capability with a dry-run
    if [ -f "$data_path/dbc.MPQ" ]; then
        log_info "Found dbc.MPQ - basic structure looks valid"
    fi
    
    if [ "$errors" -gt 0 ]; then
        log_warn "Client data validation found $errors issues"
        return 1
    else
        log_info "Client data validation passed"
        return 0
    fi
}

# Decide how to treat an existing INSTALLROOT: "clean" (nothing installed),
# "resume" (install checkpoints present - the phase runner can continue),
# or the configured REINSTALL_POLICY ("abort"/"replace").
existing_install_action() {
    if [ ! -d "$INSTALLROOT" ]; then
        printf 'clean\n'
    elif [ -f "$CHECKPOINT_FILE" ]; then
        printf 'resume\n'
    else
        printf '%s\n' "${REINSTALL_POLICY:-abort}"
    fi
}

# The extractors and realm services run under a dedicated system account.
# The installer uses this account from the client-data phase onward, so it
# must exist before any chown/sudo -u references it.
ensure_service_account() {
    if id "$MANGOSOSUSER" >/dev/null 2>&1; then
        return 0
    fi
    log_info "Creating service account: $MANGOSOSUSER (system user, no login shell)"
    useradd --system --home-dir "$INSTALLROOT" --no-create-home --shell /usr/sbin/nologin "$MANGOSOSUSER"
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
            log_warn "The installer will stop at the data extraction phase."
            CLIENT_DATA=""
            return 0
        else
            read -rp "Enter path to WoW 1.12.1 client Data folder (or press Enter to skip): " CLIENT_DATA
            if [ -z "$CLIENT_DATA" ] || [ ! -d "$CLIENT_DATA" ]; then
                log_warn "No valid client data provided."
                log_warn "The installer will stop at the data extraction phase."
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
    ensure_service_account

    prepare_extraction_root
}

# Derive CLIENT_DATA_EXTRACT_ROOT from CLIENT_DATA so the extractors can read
# the MPQs as $MANGOSOSUSER. Called from check_client_data on fresh installs
# and on demand from phase_data_extraction, because a resumed install re-enters
# the extraction phase without re-running the earlier phases.
prepare_extraction_root() {
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
    fi

    # Check if mangos user can read the client data
    # Extraction runs as mangos user for security, so we need readable permissions
    if sudo -u "$MANGOSOSUSER" test -r "$CLIENT_DATA_EXTRACT_ROOT/dbc.MPQ" 2>/dev/null; then
        return 0
    fi

    # Reuse a copy staged by an earlier (interrupted) run instead of
    # re-copying several GB of MPQs on every resume.
    if [ -f "$INSTALLROOT/client-data/dbc.MPQ" ] && \
        sudo -u "$MANGOSOSUSER" test -r "$INSTALLROOT/client-data/dbc.MPQ" 2>/dev/null; then
        CLIENT_DATA_EXTRACT_ROOT="$INSTALLROOT/client-data"
        log_info "Using previously staged client data: $CLIENT_DATA_EXTRACT_ROOT"
        return 0
    fi

    log_warn "Client data is not accessible by $MANGOSOSUSER user"
    log_info "Copying client data to $INSTALLROOT/client-data for extraction..."

    # Create temp location and copy data
    mkdir -p "$INSTALLROOT/client-data" || {
        fail_marker extraction "Failed to create the client-data staging directory" "Check the permissions under $INSTALLROOT, then re-run the installer"
        return 1
    }

    # Copy all MPQ files and required directories
    cp -r "$CLIENT_DATA_EXTRACT_ROOT"/*.MPQ "$INSTALLROOT/client-data/" 2>/dev/null || true
    cp -r "$CLIENT_DATA_EXTRACT_ROOT"/*.mpq "$INSTALLROOT/client-data/" 2>/dev/null || true

    # Copy Interface directory if it exists (contains Cinematics, etc)
    if [ -d "$CLIENT_DATA_EXTRACT_ROOT/Interface" ]; then
        cp -r "$CLIENT_DATA_EXTRACT_ROOT/Interface" "$INSTALLROOT/client-data/" 2>/dev/null || true
    fi

    # Set ownership for mangos user
    chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT/client-data" || {
        fail_marker extraction "Failed to hand the staged client data to $MANGOSOSUSER" "Check that the installer runs as root, then re-run the installer"
        return 1
    }

    # Create the Data/Data symlink in the copy
    if [ ! -e "$INSTALLROOT/client-data/Data" ]; then
        ln -sf . "$INSTALLROOT/client-data/Data" 2>/dev/null || true
    fi

    CLIENT_DATA_EXTRACT_ROOT="$INSTALLROOT/client-data"
    log_info "Client data copied to: $CLIENT_DATA_EXTRACT_ROOT"
}

# =============================================================================
# INSTALLATION PHASES
# =============================================================================

phase_prerequisites() {
    log_section "PHASE: Installing Prerequisites"
    log_marker prerequisites start

    # Keep prerequisite installs headless-safe on real servers where needrestart
    # may otherwise hold apt open behind a whiptail prompt.
    DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update || {
        fail_marker prerequisites "apt-get update failed" "Check network access and the apt mirror configuration, then re-run the installer"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none \
        apt-get install -y build-essential cmake git libmariadb-dev default-libmysqlclient-dev libssl-dev \
            libbz2-dev libreadline-dev libncurses-dev libboost-all-dev \
            p7zip-full python3 python3-pip python3-venv sysstat wget zlib1g-dev || {
        fail_marker prerequisites "Failed to install build prerequisites" "Check the apt output in the install log for the failing package"
        return 1
    }

    ensure_service_account || {
        fail_marker prerequisites "Failed to set up the service account $MANGOSOSUSER" "Check that the user name is available and that useradd succeeded"
        return 1
    }

    log_marker prerequisites "done"
    set_checkpoint "PREREQS_DONE"
}

phase_database_setup() {
    log_section "PHASE: Database Setup"
    log_marker database start

    # Create databases. These are best-effort (|| true in the original): a
    # failure is recorded as a warn marker so phase=database event=done never
    # asserts an unverified step; the import phase fails loudly if a database
    # or grant that mattered is still missing.
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$WORLDDB\`;" \
        || warn_marker database "CREATE DATABASE failed for $WORLDDB"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$AUTHDB\`;" \
        || warn_marker database "CREATE DATABASE failed for $AUTHDB"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$CHARACTERDB\`;" \
        || warn_marker database "CREATE DATABASE failed for $CHARACTERDB"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$LOGSDB\`;" \
        || warn_marker database "CREATE DATABASE failed for $LOGSDB"

    # Create user
    mysql -e "CREATE USER IF NOT EXISTS '$MANGOSDBUSER'@'$SQLADMINIP' IDENTIFIED BY '$MANGOSDBPASS';" \
        || warn_marker database "CREATE USER failed for $MANGOSDBUSER"
    mysql -e "GRANT ALL PRIVILEGES ON \`$WORLDDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" \
        || warn_marker database "GRANT failed on $WORLDDB for $MANGOSDBUSER"
    mysql -e "GRANT ALL PRIVILEGES ON \`$AUTHDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" \
        || warn_marker database "GRANT failed on $AUTHDB for $MANGOSDBUSER"
    mysql -e "GRANT ALL PRIVILEGES ON \`$CHARACTERDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" \
        || warn_marker database "GRANT failed on $CHARACTERDB for $MANGOSDBUSER"
    mysql -e "GRANT ALL PRIVILEGES ON \`$LOGSDB\`.* TO '$MANGOSDBUSER'@'$SQLADMINIP';" \
        || warn_marker database "GRANT failed on $LOGSDB for $MANGOSDBUSER"
    mysql -e "FLUSH PRIVILEGES;" || {
        fail_marker database "Failed to apply database grants" "Check that MariaDB or MySQL is running, then re-run the installer"
        return 1
    }

    log_marker database "done"
    set_checkpoint "DATABASE_DONE"
}

phase_source_download() {
    log_section "PHASE: Downloading Source Code"
    log_marker source start

    mkdir -p "$INSTALLROOT" || {
        fail_marker source "Failed to create the installation directory $INSTALLROOT" "Check the path and its permissions, then re-run the installer"
        return 1
    }
    cd "$INSTALLROOT" || {
        fail_marker source "Failed to enter the installation directory $INSTALLROOT" "Check the directory permissions, then re-run the installer"
        return 1
    }

    # Clone VMaNGOS core
    if [ ! -d "source" ]; then
        git_clone_with_retry "https://github.com/vmangos/core" "source" || {
            fail_marker source "Failed to clone the VMaNGOS core repository" "Check network access to github.com, then re-run the installer"
            return 1
        }
    else
        log_info "Source directory exists, skipping clone"
    fi

    log_marker source "done"
    set_checkpoint "SOURCE_DONE"
}

phase_build() {
    log_section "PHASE: Building VMaNGOS from Source"
    log_marker build start

    cd "$INSTALLROOT" || {
        fail_marker build "Failed to enter the installation directory $INSTALLROOT" "Check the directory permissions, then re-run the installer"
        return 1
    }
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
    mkdir -p build || {
        fail_marker build "Failed to create the build directory" "Check the permissions under $INSTALLROOT, then re-run the installer"
        return 1
    }
    cd build || {
        fail_marker build "Failed to enter the build directory" "Check the permissions under $INSTALLROOT/build, then re-run the installer"
        return 1
    }
    
    # Configure
    log_info ""
    log_info "Step 1/3: Configuring build with cmake..."
    set +e
    cmake ../source -DCMAKE_INSTALL_PREFIX="$INSTALLROOT/run" \
        -DCONF_DIR="$INSTALLROOT/run/etc" \
        -DBUILD_EXTRACTORS=1 \
        -DDEBUG=0 2>&1 | tee -a "$INSTALL_LOG"
    CMAKE_RC="${PIPESTATUS[0]}"

    if [ "$CMAKE_RC" -ne 0 ]; then
        set -e
        log_error "CMake configuration failed (exit $CMAKE_RC)"
        log_error "Check $INSTALL_LOG for the cmake error output"
        fail_marker build "CMake configuration failed" "Check the cmake error output in the install log for the failing component"
        return 1
    fi
    log_info "CMake configuration complete."
    log_marker build progress "percent=33" "step=Configure"

    # Build - with background support if enabled
    log_info ""
    log_info "Step 2/3: Compiling source code (this is the long part)..."
    log_info ""

    if [ "$BUILD_IN_BACKGROUND" = "1" ]; then
        if ! start_background_build; then
            set -e
            log_error "Background build failed"
            log_error "Check $INSTALL_LOG and $CHECKPOINT_DIR/build-status"
            fail_marker build "Compilation failed" "Check the build log and build-status file for the failing target"
            return 1
        fi
    else
        log_info "Compiling with $CPU parallel jobs..."
        log_info "You will see percentage progress below:"
        log_info ""
        # Run make and filter output to show progress
        make -j "$CPU" 2>&1 | tee -a "$INSTALL_LOG" | \
            grep -E "^\[[ 0-9]+%\]|Linking|Building|Built target|Scanning"
        MAKE_RC="${PIPESTATUS[0]}"
        if [ "$MAKE_RC" -ne 0 ]; then
            set -e
            log_error "Compilation failed (exit $MAKE_RC) - full output in $INSTALL_LOG"
            fail_marker build "Compilation failed" "Check the install log for the compiler error"
            return 1
        fi
        log_info ""
        log_info "Compilation complete!"
    fi
    log_marker build progress "percent=66" "step=Compile"

    # Install
    log_info ""
    log_info "Step 3/3: Installing compiled binaries..."
    make install 2>&1 | tee -a "$INSTALL_LOG"
    INSTALL_RC="${PIPESTATUS[0]}"
    set -e
    if [ "$INSTALL_RC" -ne 0 ]; then
        log_error "make install failed (exit $INSTALL_RC)"
        fail_marker build "make install failed" "Check the install log for the failing install step"
        return 1
    fi
    if [ ! -f "$INSTALLROOT/run/etc/mangosd.conf.dist" ]; then
        log_error "Build artifacts missing after install (expected $INSTALLROOT/run/etc/mangosd.conf.dist)"
        fail_marker build "Build artifacts missing after install" "Re-run the build phase; the compiled output was not produced"
        return 1
    fi
    log_info "Installation of binaries complete."
    
    log_info ""
    log_info "====================================================================="
    log_info "BUILD COMPLETED at $(date '+%H:%M:%S')"
    log_info "====================================================================="
    log_marker build "done"

    set_checkpoint "BUILD_DONE"
}

phase_config_setup() {
    log_section "PHASE: Configuration Setup"
    log_marker config start

    cd "$INSTALLROOT" || {
        fail_marker config "Failed to enter the installation directory $INSTALLROOT" "Check the directory permissions, then re-run the installer"
        return 1
    }

    # Copy config files
    cp "$INSTALLROOT/run/etc/mangosd.conf.dist" "$INSTALLROOT/run/etc/mangosd.conf" || {
        fail_marker config "Build artifacts are missing (mangosd.conf.dist)" "Re-run the installer so the build phase completes first"
        return 1
    }
    cp "$INSTALLROOT/run/etc/realmd.conf.dist" "$INSTALLROOT/run/etc/realmd.conf" || {
        fail_marker config "Build artifacts are missing (realmd.conf.dist)" "Re-run the installer so the build phase completes first"
        return 1
    }
    
    log_info "Configuring realmd.conf..."

    # The database is set up locally by this installer (MySQL binds 127.0.0.1
    # by default on Ubuntu), so the daemons must connect via 127.0.0.1 - not
    # $SERVERIP, which nothing listens on. Clients keep using $SERVERIP via
    # the realmlist entry and BindIP below.
    # The config format is: LoginDatabaseInfo = "host;port;user;pass;db"
    # Use more flexible sed patterns that handle variations in spacing
    sed -i "s|LoginDatabaseInfo.*=.*\"127\.0\.0\.1;3306;mangos;.*;realmd\"|LoginDatabaseInfo = \"127.0.0.1;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB\"|" "$INSTALLROOT/run/etc/realmd.conf"
    sed -i "s|BindIP.*=.*\"0\.0\.0\.0\"|BindIP = \"$SERVERIP\"|" "$INSTALLROOT/run/etc/realmd.conf"

    log_info "Configuring mangosd.conf..."

    # Update World server config - handle both old and new format
    # New format uses dots: LoginDatabase.Info, WorldDatabase.Info, etc.
    # Use flexible patterns that match the actual config file format
    sed -i "s|LoginDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|LoginDatabase.Info = \"127.0.0.1;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|WorldDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|WorldDatabase.Info = \"127.0.0.1;3306;$MANGOSDBUSER;$MANGOSDBPASS;$WORLDDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|CharacterDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|CharacterDatabase.Info = \"127.0.0.1;3306;$MANGOSDBUSER;$MANGOSDBPASS;$CHARACTERDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    sed -i "s|LogsDatabase\.Info.*=.*\"127\.0\.0\.1;3306;mangos;.*;.*\"|LogsDatabase.Info = \"127.0.0.1;3306;$MANGOSDBUSER;$MANGOSDBPASS;$LOGSDB\"|" "$INSTALLROOT/run/etc/mangosd.conf"
    
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
    
    if installer_should_provision_manager; then
        local manager_root manager_config_dir manager_config_file manager_password_file
        manager_root="$INSTALLROOT/manager"
        manager_config_dir="$manager_root/config"
        manager_config_file="$manager_config_dir/manager.conf"
        manager_password_file="$manager_config_dir/.dbpass"

        log_info "Provisioning VMANGOS Manager configuration..."
        mkdir -p "$manager_root/bin" "$manager_root/lib" "$manager_root/tests" "$manager_config_dir" || {
            fail_marker config "Failed to create the manager directories" "Check the permissions under $manager_root, then re-run the installer"
            return 1
        }

        if [ -d "$SCRIPT_DIR/manager" ]; then
            log_info "Installing bundled VMANGOS Manager sources into $manager_root"
            cp "$SCRIPT_DIR/manager/bin/vmangos-manager" "$manager_root/bin/" || {
                fail_marker config "Failed to install the manager CLI" "Check the sources under $SCRIPT_DIR/manager, then re-run the installer"
                return 1
            }
            cp "$SCRIPT_DIR/manager/lib/"*.sh "$manager_root/lib/" || {
                fail_marker config "Failed to install the manager libraries" "Check the sources under $SCRIPT_DIR/manager, then re-run the installer"
                return 1
            }
            cp "$SCRIPT_DIR/manager/lib/"*.py "$manager_root/lib/" 2>/dev/null || true
            cp "$SCRIPT_DIR/manager/tests/"*.sh "$manager_root/tests/" 2>/dev/null || true
            cp "$SCRIPT_DIR/manager/Makefile" "$manager_root/" 2>/dev/null || true
            cp "$SCRIPT_DIR/manager/dashboard-requirements.txt" "$manager_root/" 2>/dev/null || true
            chmod +x "$manager_root/bin/vmangos-manager" || {
                fail_marker config "Failed to make the manager CLI executable" "Check the permissions under $manager_root/bin, then re-run the installer"
                return 1
            }
        else
            log_warn "Bundled manager sources not found next to vmangos_setup.sh; creating config only"
        fi

        if ! cat > "$manager_config_file" << EOF
# VMANGOS Manager Configuration
# Auto-generated by vmangos_setup.sh on $(date -Iseconds)

[database]
host = 127.0.0.1
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
        then
            fail_marker config "Failed to write the manager configuration" "Check the disk and permissions under $manager_config_dir, then re-run the installer"
            return 1
        fi

        printf '%s\n' "$MANGOSDBPASS" > "$manager_password_file" || {
            fail_marker config "Failed to write the manager password file" "Check the disk and permissions under $manager_config_dir, then re-run the installer"
            return 1
        }
        # 640 + mangos group (set by the later chown -R) lets non-root users
        # read the config after 'usermod -aG mangos <user>'; 600 would lock
        # them out with errors on every subcommand.
        chmod 640 "$manager_config_file" "$manager_password_file" || {
            fail_marker config "Failed to set the manager config permissions" "Check the permissions under $manager_config_dir, then re-run the installer"
            return 1
        }
        mkdir -p "$INSTALLROOT/backups" || {
            fail_marker config "Failed to create the backups directory" "Check the permissions under $INSTALLROOT, then re-run the installer"
            return 1
        }
        chmod 775 "$INSTALLROOT/backups" || {
            fail_marker config "Failed to set the backups directory permissions" "Check the permissions on $INSTALLROOT/backups, then re-run the installer"
            return 1
        }
        # Runtime lock dir is on tmpfs: recreate it group-writable at boot.
        mkdir -p /etc/tmpfiles.d || {
            fail_marker config "Failed to create /etc/tmpfiles.d" "Check the install log for the failing step, then re-run the installer"
            return 1
        }
        printf 'd /run/vmangos-manager 0775 root %s -\n' "$MANGOSOSUSER" > /etc/tmpfiles.d/vmangos-manager.conf || {
            fail_marker config "Failed to write the manager tmpfiles rule" "Check the install log for the failing step, then re-run the installer"
            return 1
        }
        systemd-tmpfiles --create /etc/tmpfiles.d/vmangos-manager.conf 2>/dev/null || true
        mkdir -p /var/run/vmangos-manager || {
            fail_marker config "Failed to create /var/run/vmangos-manager" "Check the install log for the failing step, then re-run the installer"
            return 1
        }
        chgrp "$MANGOSOSUSER" /var/run/vmangos-manager || {
            fail_marker config "Failed to set the manager runtime directory group" "Check the install log for the failing step, then re-run the installer"
            return 1
        }
        chmod 775 /var/run/vmangos-manager || {
            fail_marker config "Failed to set the manager runtime directory permissions" "Check the install log for the failing step, then re-run the installer"
            return 1
        }
        log_info "Manager config written to $manager_config_file"
        log_info "To manage the server as a non-root user:"
        log_info "  sudo usermod -aG $MANGOSOSUSER <username>   # then that user logs out/in"

        if [ -x "$manager_root/bin/vmangos-manager" ]; then
            if "$manager_root/bin/vmangos-manager" -c "$manager_config_file" dashboard --bootstrap >/dev/null 2>&1; then
                log_info "Manager dashboard dependencies bootstrapped"
            else
                log_warn "Manager dashboard bootstrap failed; run '$manager_root/bin/vmangos-manager -c $manager_config_file dashboard --bootstrap' after install"
            fi
        fi
    else
        log_info "Provisioning target excludes VMANGOS Manager; bundled manager setup skipped."
    fi
    log_marker config "done"

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
    log_marker extraction start

    cd "$INSTALLROOT" || {
        fail_marker extraction "Failed to enter the installation directory $INSTALLROOT" "Check the directory permissions, then re-run the installer"
        return 1
    }

    # The server cannot boot without DBC files and base maps, so do NOT
    # checkpoint DATA_DONE here — stop and tell the user how to resume.
    if [ -z "$CLIENT_DATA" ] || [ ! -d "$CLIENT_DATA" ]; then
        log_error "========================================="
        log_error "NO CLIENT DATA"
        log_error "========================================="
        log_error ""
        log_error "The server cannot start without DBC files and base maps,"
        log_error "so the installation stops here instead of continuing."
        log_error ""
        log_info "Provide a WoW 1.12.1 (build 5875) client Data folder and re-run"
        log_info "the installer; it will resume from this phase:"
        log_info "  VMANGOS_CLIENT_DATA=/path/to/Data sudo bash vmangos_setup.sh"
        log_info ""
        log_info "To extract manually instead, place the client Data folder and run:"
        log_info "  sudo $INSTALLROOT/run/bin/Extractors/mapextractor --silent -i <client_root_with_Data>"
        fail_marker extraction "No client data found" "Provide a WoW 1.12.1 (build 5875) client Data folder and set VMANGOS_CLIENT_DATA, then re-run the installer"
        return 1
    fi

    # A resumed install re-enters this phase without re-running
    # check_client_data, so make sure the service account exists (this phase
    # chowns and sudo -us to it) and derive the extraction root on demand.
    ensure_service_account
    prepare_extraction_root

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
    mkdir -p "$INSTALLROOT/run/bin/5875" "$INSTALLROOT/logs/mangosd" \
        "$INSTALLROOT/logs/honor" "$INSTALLROOT/logs/realmd" || {
        fail_marker extraction "Failed to create the extraction output directories" "Check the permissions under $INSTALLROOT, then re-run the installer"
        return 1
    }
    
    # Set ownership for extraction
    chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT" || {
        fail_marker extraction "Failed to hand the installation directory to $MANGOSOSUSER" "Check that the installer runs as root, then re-run the installer"
        return 1
    }
    
    # Run extractors as mangos user
    cd "$INSTALLROOT" || {
        fail_marker extraction "Failed to enter the installation directory $INSTALLROOT" "Check the directory permissions, then re-run the installer"
        return 1
    }
    
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
        log_info "Starting mapextractor with client data: $CLIENT_DATA_EXTRACT_ROOT"
        # --silent: the extractor prompts for y/n + "press enter" otherwise,
        # which wedges an unattended install. Defaults kept: high res, limited height.
        # PIPESTATUS: tee would otherwise mask the extractor's exit code.
        sudo -u "$MANGOSOSUSER" bash -c "cd '$INSTALLROOT' && ./mapextractor --silent -i '$CLIENT_DATA_EXTRACT_ROOT'" 2>&1 | tee -a "$INSTALL_LOG"
        local MAPEXTRACT_RC=${PIPESTATUS[0]}

        if [ "$MAPEXTRACT_RC" -eq 0 ] && [ -n "$(ls -A "$INSTALLROOT/dbc" 2>/dev/null)" ] && [ -n "$(ls -A "$INSTALLROOT/maps" 2>/dev/null)" ]; then
            log_info "DBC and map extraction completed successfully"
            log_marker extraction progress "percent=10" "step=Extract DBC and maps"
        else
            log_error "Map extraction failed (exit status $MAPEXTRACT_RC or missing dbc/maps output)"
            EXTRACTION_FAILED=1
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
    
    local VMAPS_FAILED=0

    if [ $EXTRACTION_FAILED -eq 0 ] && [ -f ./vmapextractor ]; then
        log_info "Starting vmapextractor..."
        # -d (not -i): vmapextractor's input flag; it expects the MPQ folder itself.
        # --silent: skip its "press enter" prompts.
        # PIPESTATUS: tee would otherwise mask the extractor's exit code.
        sudo -u "$MANGOSOSUSER" bash -c "cd '$INSTALLROOT' && ./vmapextractor --silent -d '$CLIENT_DATA_EXTRACT_ROOT'" 2>&1 | tee -a "$INSTALL_LOG"
        if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -n "$(ls -A "$INSTALLROOT/Buildings" 2>/dev/null)" ]; then
            log_info "VMap extraction completed"
            log_marker extraction progress "percent=25" "step=Extract vmaps"
        else
            log_warn "VMap extractor failed or produced no Buildings output"
            VMAPS_FAILED=1
        fi
    else
        log_warn "Skipping vmap extraction (previous step failed or extractor not found)"
        VMAPS_FAILED=1
    fi
    
    # Step 3: Assemble vmaps (5-10 minutes)
    log_info ""
    log_info "====================================================================="
    log_info "STEP 3/4: Assembling vmaps"
    log_info "====================================================================="
    log_info "This step combines vmap data into usable format."
    log_info "Expected time: 5-10 minutes"
    log_info ""
    
    if [ $EXTRACTION_FAILED -eq 0 ] && [ $VMAPS_FAILED -eq 0 ] && [ -f ./vmap_assembler ]; then
        log_info "Starting vmap_assembler..."
        mkdir -p "$INSTALLROOT/vmaps"
        # The assembler runs as $MANGOSOSUSER and must write into vmaps;
        # mkdir ran as root, so hand the directory over first.
        chown "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT/vmaps"
        # Assemble from the Buildings dir vmapextractor wrote to $INSTALLROOT,
        # not from the raw client data. --silent skips its "press enter" prompt.
        sudo -u "$MANGOSOSUSER" bash -c "cd '$INSTALLROOT' && ./vmap_assembler --silent '$INSTALLROOT/Buildings' '$INSTALLROOT/vmaps'" 2>&1 | tee -a "$INSTALL_LOG"
        if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -n "$(ls -A "$INSTALLROOT/vmaps" 2>/dev/null)" ]; then
            log_info "VMap assembly completed"
            log_marker extraction progress "percent=40" "step=Assemble vmaps"
        else
            log_warn "VMap assembler had issues - server will run without vmaps"
            VMAPS_FAILED=1
        fi
    else
        log_warn "Skipping vmap assembly (previous step failed or assembler not found)"
        VMAPS_FAILED=1
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
    
    local MMAPS_FAILED=0

    if [ $EXTRACTION_FAILED -eq 0 ] && [ $VMAPS_FAILED -eq 0 ] && [ -f ./MoveMapGen ]; then
        # Run with a background progress heartbeat
        {
            while true; do
                sleep 300  # Every 5 minutes
                log_info "[$(date '+%H:%M:%S')] MoveMapGen still running... (this is normal)"
            done
        } &
        HEARTBEAT_PID=$!

        # Run the actual generation (--silent: it waits for "press enter" otherwise)
        sudo -u "$MANGOSOSUSER" ./MoveMapGen --silent --offMeshInput offmesh.txt 2>&1 | tee -a "$INSTALL_LOG"
        local MOVEMAP_RC=${PIPESTATUS[0]}

        # Stop the heartbeat
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true

        log_info "====================================================================="
        if [ "$MOVEMAP_RC" -eq 0 ] && [ -n "$(ls -A "$INSTALLROOT/mmaps" 2>/dev/null)" ]; then
            log_info "Movement map generation completed at $(date '+%H:%M:%S')"
            log_marker extraction progress "percent=90" "step=Generate movement maps"
        else
            log_warn "MoveMapGen exited with status $MOVEMAP_RC at $(date '+%H:%M:%S')"
            log_warn "Server will run without mmaps (NPC pathfinding disabled)"
            MMAPS_FAILED=1
        fi
        log_info "====================================================================="
    else
        log_warn "Skipping movement map generation (previous step failed, vmaps missing or generator not found)"
        MMAPS_FAILED=1
    fi
    
    log_info ""
    if [ $EXTRACTION_FAILED -eq 1 ]; then
        log_error "========================================="
        log_error "DATA EXTRACTION FAILED"
        log_error "========================================="
        log_error ""
        log_error "The server cannot start without DBC files and base maps,"
        log_error "so the installation stops here instead of continuing."
        log_error ""
        log_error "This usually means:"
        log_error "  1. The client data is not WoW 1.12.1 (build 5875)"
        log_error "  2. The client data is incomplete or corrupted"
        log_error "  3. The extractor tools had compatibility issues"
        log_error ""
        log_info "Manual extraction commands:"
        log_info "  cd $INSTALLROOT"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/mapextractor --silent -i <client_root_with_Data>"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/vmapextractor --silent -d <client_data_folder>"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/vmap_assembler --silent buildings vmaps"
        log_info "  sudo -u $MANGOSOSUSER ./run/bin/Extractors/MoveMapGenerator --silent"
        log_error ""
        fail_marker extraction "Data extraction failed" "Verify the client data is WoW 1.12.1 (build 5875) and complete, then re-run the installer to resume from this phase"
        return 1
    else
        if [ $VMAPS_FAILED -eq 1 ] || [ $MMAPS_FAILED -eq 1 ]; then
            log_warn "Extraction completed with gaps:"
            if [ $VMAPS_FAILED -eq 1 ]; then
                log_warn "  - vmaps missing: line-of-sight is disabled in mangosd.conf"
            fi
            if [ $MMAPS_FAILED -eq 1 ]; then
                log_warn "  - mmaps missing: NPC pathfinding will be limited"
            fi
            log_info "You can re-run the missing steps manually (see commands above)."
        else
            log_info "All data extraction steps completed successfully!"
        fi
        
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
    log_marker extraction "done"

    set_checkpoint "DATA_DONE"
}

# The db_latest release asset is revision-pinned (db-<shortsha>.zip) and its
# name changes as the core moves, so hardcoded URLs rot into 404s. Resolve the
# current asset name via the GitHub API and fall back to a known name.
resolve_world_db_urls() {
    local api_json url
    WORLD_DB_URLS=()

    api_json=$(wget -qO- --timeout=30 \
        "https://api.github.com/repos/vmangos/core/releases/tags/db_latest" 2>/dev/null || true)
    if [ -n "$api_json" ]; then
        url=$(printf '%s' "$api_json" | \
            grep -o 'https://github.com/vmangos/core/releases/download/db_latest/db-[^"]*\.zip' | \
            grep -v sqlite | head -n1 || true)
        if [ -n "$url" ]; then
            log_info "Resolved current world database release: $url"
            WORLD_DB_URLS+=("$url")
        fi
    fi

    # Known-good fallback if the API is unreachable or its shape changed
    WORLD_DB_URLS+=("https://github.com/vmangos/core/releases/download/db_latest/db-810fef8.zip")
}

phase_database_import() {
    log_section "PHASE: Database Import"
    log_marker db-import start

    cd "$INSTALLROOT" || {
        fail_marker db-import "Failed to enter the installation directory $INSTALLROOT" "Check the directory permissions, then re-run the installer"
        return 1
    }

    # Download and import world database
    # Try multiple sources in order of preference
    resolve_world_db_urls
    
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
                        mysql "$AUTHDB" < "mysql-dump/logon.sql" || {
                            fail_marker db-import "Failed to import the auth database" "Check the MariaDB log for the failing statement, then re-run the installer"
                            return 1
                        }
                        log_marker db-import progress "percent=20" "step=Import auth database"
                    fi
                    
                    if [ -f "mysql-dump/characters.sql" ]; then
                        log_info "Importing characters database..."
                        mysql "$CHARACTERDB" < "mysql-dump/characters.sql" || {
                            fail_marker db-import "Failed to import the characters database" "Check the MariaDB log for the failing statement, then re-run the installer"
                            return 1
                        }
                        log_marker db-import progress "percent=40" "step=Import characters database"
                    fi
                    
                    if [ -f "mysql-dump/logs.sql" ]; then
                        log_info "Importing logs database..."
                        mysql "$LOGSDB" < "mysql-dump/logs.sql" || {
                            fail_marker db-import "Failed to import the logs database" "Check the MariaDB log for the failing statement, then re-run the installer"
                            return 1
                        }
                        log_marker db-import progress "percent=60" "step=Import logs database"
                    fi
                    
                    if [ -f "mysql-dump/mangos.sql" ]; then
                        log_info "Importing world database (this may take a while)..."
                        mysql "$WORLDDB" < "mysql-dump/mangos.sql" || {
                            fail_marker db-import "Failed to import the world database" "Check the MariaDB log for the failing statement, then re-run the installer"
                            return 1
                        }
                        log_info "World database imported successfully"
                        log_marker db-import progress "percent=80" "step=Import world database"
                    fi
                    
                    WORLD_DB_DOWNLOADED=true
                    
                    # Clean up extracted files
                    rm -rf mysql-dump
                else
                    # Legacy: find SQL files in current directory
                    WORLD_SQL=$(find . -name "*.sql" -type f | grep -E "(world|mangos)" | head -n1)
                    if [ -n "$WORLD_SQL" ]; then
                        log_info "Importing world database from $WORLD_SQL (this may take a while)..."
                        mysql "$WORLDDB" < "$WORLD_SQL" || {
                            fail_marker db-import "Failed to import the world database" "Check the MariaDB log for the failing statement, then re-run the installer"
                            return 1
                        }
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
            cd "$INSTALLROOT/source/sql/migrations" || {
                fail_marker db-import "Failed to enter the migrations directory" "Check the sources under $INSTALLROOT/source/sql, then re-run the installer"
                return 1
            }
            if [ -f "merge.sh" ]; then
                chmod +x merge.sh || {
                    fail_marker db-import "Failed to make the migration merge script executable" "Check the sources under $INSTALLROOT/source/sql/migrations, then re-run the installer"
                    return 1
                }
                ./merge.sh 2>&1 | tee -a "$INSTALL_LOG" || true
            fi

            if [ -f "world_db_updates.sql" ]; then
                mysql "$WORLDDB" < world_db_updates.sql || true
            fi
            if [ -f "logs_db_updates.sql" ]; then
                mysql "$LOGSDB" < logs_db_updates.sql || true
            fi
            if [ -f "characters_db_updates.sql" ]; then
                mysql "$CHARACTERDB" < characters_db_updates.sql || true
            fi
            if [ -f "logon_db_updates.sql" ]; then
                mysql "$AUTHDB" < logon_db_updates.sql || true
            fi
        else
            log_info "Skipping migrations (using pre-built database or no migrations table)"
        fi
    fi

    ensure_realmlist_entry || {
        fail_marker db-import "Failed to seed the realmlist" "Check that the auth database exists and the MariaDB log for the failing statement"
        return 1
    }
    log_marker db-import "done"

    set_checkpoint "DB_IMPORT_DONE"
}

phase_service_setup() {
    log_section "PHASE: Service Setup"
    log_marker services start

    # Create systemd services
    if ! cat > /etc/systemd/system/auth.service << EOF
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
    then
        fail_marker services "Failed to write the auth service unit" "Check the install log for the failing step, then re-run the installer"
        return 1
    fi

    if ! cat > /etc/systemd/system/world.service << EOF
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
    then
        fail_marker services "Failed to write the world service unit" "Check the install log for the failing step, then re-run the installer"
        return 1
    fi

    systemctl daemon-reload || {
        fail_marker services "systemctl daemon-reload failed" "Check the install log for the systemd error, then re-run the installer"
        return 1
    }
    systemctl enable auth.service || {
        fail_marker services "Failed to enable the auth service" "Check the install log for the systemd error, then re-run the installer"
        return 1
    }
    systemctl enable world.service || {
        fail_marker services "Failed to enable the world service" "Check the install log for the systemd error, then re-run the installer"
        return 1
    }
    
    # Fix permissions
    chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT" || {
        fail_marker services "Failed to hand the installation directory to $MANGOSOSUSER" "Check that the installer runs as root, then re-run the installer"
        return 1
    }
    
    # Start services
    log_info "Starting auth service..."
    systemctl start auth.service || {
        fail_marker services "Failed to start the auth service" "Check the unit with: journalctl -u auth -n 50, then re-run the installer"
        return 1
    }
    sleep 3

    log_info "Starting world service (this may take 30-60 seconds to fully load)..."
    systemctl start world.service || {
        fail_marker services "Failed to start the world service" "Check the unit with: journalctl -u world -n 50, then re-run the installer"
        return 1
    }
    sleep 15
    
    # Verify services are running
    # (is-active exits non-zero for inactive services; without || true that
    # would abort this phase under set -e before the failure is even logged)
    log_info "Verifying services..."
    AUTH_STATUS=$(systemctl is-active auth.service 2>&1 || true)
    WORLD_STATUS=$(systemctl is-active world.service 2>&1 || true)
    
    if [ "$AUTH_STATUS" = "active" ]; then
        log_info "✓ Auth service is running on $SERVERIP:3724"
    else
        log_error "✗ Auth service failed to start (status: $AUTH_STATUS)"
        log_info "Check logs: journalctl -u auth -n 50"
    fi
    
    if [ "$WORLD_STATUS" = "active" ]; then
        log_info "✓ World service is running on $SERVERIP:8085"
        # Show memory usage
        WORLD_MEM=""
        WORLD_PID=$(pgrep -n mangosd 2>/dev/null || true)
        if [ -n "$WORLD_PID" ]; then
            WORLD_MEM=$(ps -o rss= -p "$WORLD_PID" | awk '{print $1/1024}')
        fi
        log_info "  World server memory usage: ${WORLD_MEM:-unknown} MB"
    else
        log_error "✗ World service failed to start (status: $WORLD_STATUS)"
        log_info "Check logs: journalctl -u world -n 50"
        log_info "Or: tail -50 $INSTALLROOT/logs/mangosd/Server.log"
    fi

    if [ "$AUTH_STATUS" != "active" ] || [ "$WORLD_STATUS" != "active" ]; then
        log_error "Service verification failed - not marking installation complete"
        fail_marker services "Service verification failed" "Check journalctl -u auth and journalctl -u world for the startup failure, then re-run the installer"
        return 1
    fi

    if [ -d "$INSTALLROOT/logs/mangosd" ]; then
        chmod 600 \
            "$INSTALLROOT/logs/mangosd/Anticheat.log" \
            "$INSTALLROOT/logs/mangosd/gm_critical.log" \
            2>/dev/null || true
    fi
    log_marker services "done"

    set_checkpoint "SERVICES_DONE"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log_section "VMANGOS Installation Started"
    log_info "Installation directory: $INSTALLROOT"
    log_info "Log file: $INSTALL_LOG"
    
    check_root
    select_installer_target
    select_input_mode
    validate_installer_selection
    prompt_guided_install_root

    log_info "Resume support enabled - checkpoints stored in: $CHECKPOINT_DIR"
    init_checkpoints
    load_installer_state
    validate_installer_selection
    prompt_guided_values
    announce_installer_selection
    save_installer_state
    ensure_server_ip
    save_installer_state
    
    # Get current checkpoint
    CHECKPOINT=$(get_checkpoint)
    log_info "Resuming from checkpoint: $CHECKPOINT"

    # Self-heal a BUILD_DONE checkpoint that has no build artifacts behind
    # it (a previous build phase reported success while cmake/make failed).
    if [ "$CHECKPOINT" = "BUILD_DONE" ] && [ ! -f "$INSTALLROOT/run/etc/mangosd.conf.dist" ]; then
        log_warn "BUILD_DONE checkpoint found but build artifacts are missing"
        log_warn "Resetting to SOURCE_DONE so the build phase runs again"
        log_marker build progress "percent=0" "step=Self-heal: build artifacts missing, the build phase will run again"
        CHECKPOINT="SOURCE_DONE"
        set_checkpoint "SOURCE_DONE"
    fi
    
    case "$CHECKPOINT" in
        START|PREREQS_DONE|DATABASE_DONE|SOURCE_DONE|BUILD_DONE|CONFIG_DONE|DATA_DONE|DB_IMPORT_DONE|SERVICES_DONE)
            ;;
        *)
            log_error "Unknown checkpoint: $CHECKPOINT"
            log_info "Resetting to START"
            echo "START" > "$CHECKPOINT_FILE"
            exit 1
            ;;
    esac

    if [ "$CHECKPOINT" = "START" ]; then
        phase_prerequisites
        CHECKPOINT="PREREQS_DONE"
    fi

    if [ "$CHECKPOINT" = "PREREQS_DONE" ]; then
        check_client_data
        phase_database_setup
        CHECKPOINT="DATABASE_DONE"
    fi

    if [ "$CHECKPOINT" = "DATABASE_DONE" ]; then
        phase_source_download
        CHECKPOINT="SOURCE_DONE"
    fi

    if [ "$CHECKPOINT" = "SOURCE_DONE" ]; then
        phase_build
        CHECKPOINT="BUILD_DONE"
    fi

    if [ "$CHECKPOINT" = "BUILD_DONE" ]; then
        phase_config_setup
        CHECKPOINT="CONFIG_DONE"
    fi

    if [ "$CHECKPOINT" = "CONFIG_DONE" ]; then
        phase_data_extraction
        CHECKPOINT="DATA_DONE"
    fi

    if [ "$CHECKPOINT" = "DATA_DONE" ]; then
        phase_database_import
        CHECKPOINT="DB_IMPORT_DONE"
    fi

    if [ "$CHECKPOINT" = "DB_IMPORT_DONE" ]; then
        phase_service_setup
        CHECKPOINT="SERVICES_DONE"
    fi

    if [ "$CHECKPOINT" = "SERVICES_DONE" ]; then
        log_marker install "done" "server_ip=${SERVERIP:-unknown}" auth_port=3724 world_port=8085
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
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
