#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Backup module for VMANGOS Manager
# Full SQL backup, verification, restore, and scheduling
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

export BACKUP_CONFIG_LOADED=""
export BACKUP_DIR=""
export BACKUP_RETENTION_DAYS=""
export BACKUP_VERIFY_AFTER=""

export BACKUP_LOCK_FILE="/var/run/vmangos-manager/backup.lock"

# Exit codes
export E_BACKUP_NOSPACE=10
export E_BACKUP_LOCKED=11
export E_BACKUP_MYSQLDUMP=12
export E_BACKUP_METADATA=13
export E_VERIFY_CORRUPT=14
export E_VERIFY_INCOMPLETE=15
export E_RESTORE_PRIVS=16
export E_RESTORE_PARTIAL=17
export E_SCHEDULE_INVALID=18

# Required databases for backup
# Database list populated from config in backup_load_config()

# Required tables for Level 2 verification
BACKUP_REQUIRED_TABLES=(
    "auth.account"
    "auth.account_banned"
    "auth.realmcharacters"
    "characters.characters"
    "characters.character_inventory"
    "characters.character_homebind"
    "world.creature"
    "world.gameobject"
    "world.item_template"
    "world.quest_template"
    "logs.logs"
)

# ============================================================================
# CONFIG LOADING
# ============================================================================

backup_load_config() {
    [[ "$BACKUP_CONFIG_LOADED" == "1" ]] && return 0
    
    config_load "$CONFIG_FILE" || {
        log_error "Failed to load configuration"
        return 1
    }
    
    BACKUP_DIR="${CONFIG_BACKUP_DIR:-/opt/mangos/backups}"
    BACKUP_RETENTION_DAYS="${CONFIG_BACKUP_RETENTION_DAYS:-30}"
    BACKUP_VERIFY_AFTER="${CONFIG_BACKUP_VERIFY_AFTER:-true}"

    # Load database names from config
    BACKUP_DATABASES=("$AUTH_DB" "${CONFIG_DATABASE_CHARACTERS_DB:-characters}" "${CONFIG_DATABASE_WORLD_DB:-mangos}" "${CONFIG_DATABASE_LOGS_DB:-logs}")
    
    BACKUP_CONFIG_LOADED="1"
    log_debug "Backup configuration loaded: dir=$BACKUP_DIR"
    return 0
}

# ============================================================================
# LOCKING
# ============================================================================

backup_acquire_lock() {
    if [[ -f "$BACKUP_LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$BACKUP_LOCK_FILE" 2>/dev/null) || true
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error_exit "Another backup is in progress (PID: $pid)" "$E_BACKUP_LOCKED"
        fi
        rm -f "$BACKUP_LOCK_FILE"
    fi
    
    # Ensure lock directory exists
    local lock_dir
    lock_dir=$(dirname "$BACKUP_LOCK_FILE")
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || {
            log_warn "Cannot create lock directory: $lock_dir"
        }
    fi
    
    echo $$ > "$BACKUP_LOCK_FILE"
    register_cleanup "rm -f $BACKUP_LOCK_FILE"
    log_debug "Acquired backup lock"
}

backup_release_lock() {
    rm -f "$BACKUP_LOCK_FILE"
    log_debug "Released backup lock"
}

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

backup_preflight_check() {
    log_info "Running backup pre-flight checks..."
    
    local error_count=0
    
    # Ensure backup directory exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_info "Creating backup directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR" || {
            error_exit "Failed to create backup directory: $BACKUP_DIR" "$E_BACKUP_NOSPACE"
        }
    fi
    
    # Check write permissions
    if [[ ! -w "$BACKUP_DIR" ]]; then
        error_exit "Backup directory not writable: $BACKUP_DIR" "$E_BACKUP_NOSPACE"
    fi
    
    # Check database connectivity
    if ! db_check_connection; then
        log_error "Database connectivity check failed"
        error_count=$((error_count + 1))
    else
        log_info "✓ Database connectivity OK"
    fi
    
    # Estimate required space
    local required_mb available_mb
    required_mb=$(backup_estimate_size)
    available_mb=$(df "$BACKUP_DIR" | awk 'NR==2 {print int($4/1024)}')
    
    log_info "Backup size estimate: ${required_mb}MB"
    log_info "Available space: ${available_mb}MB"
    
    # Require 2x estimated size for safety margin
    local required_with_margin=$((required_mb * 2))
    if [[ "$available_mb" -lt "$required_with_margin" ]]; then
        log_error "Insufficient disk space: ${available_mb}MB available, ${required_with_margin}MB required (2x ${required_mb}MB estimate)"
        error_count=$((error_count + 1))
    else
        log_info "✓ Disk space OK"
    fi
    
    return "$error_count"
}

backup_estimate_size() {
    # Estimate backup size based on database sizes
    # Query information_schema for rough estimate
    local opts total_size=0
    opts=$(backup_mysql_opts)
    
    for db in "${BACKUP_DATABASES[@]}"; do
        local size
        size=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" ${DB_PASS:+-p$DB_PASS} -N -B -e "
            SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024)
            FROM information_schema.tables
            WHERE table_schema = '$db'
        " 2>/dev/null || echo "0")
        
        if [[ "$size" =~ ^[0-9]+$ ]]; then
            total_size=$((total_size + size))
        fi
    done
    
    # Add 20% overhead for mysqldump text format
    echo $((total_size * 12 / 10))
}

# ============================================================================
# MYSQL HELPERS
# ============================================================================

backup_mysql_opts() {
    local opts="-h $DB_HOST -P $DB_PORT -u $DB_USER"
    [[ -n "$DB_PASS" ]] && opts="$opts -p'$DB_PASS'"
    echo "$opts"
}

db_check_connection() {
    local opts
    opts=$(backup_mysql_opts)
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" ${DB_PASS:+-p$DB_PASS} -e "SELECT 1" "$AUTH_DB" >/dev/null 2>&1
}

# ============================================================================
# BACKUP EXECUTION
# ============================================================================

backup_generate_filename() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    echo "vmangos_backup_${timestamp}"
}

backup_now() {
    local verify="${1:-false}"
    
    log_section "Starting VMANGOS Backup"
    
    # Load configuration
    backup_load_config || error_exit "Failed to load configuration" "$E_CONFIG_ERROR"
    server_load_config || error_exit "Failed to load server configuration" "$E_CONFIG_ERROR"
    
    # Acquire lock
    backup_acquire_lock
    
    # Pre-flight checks
    if ! backup_preflight_check; then
        backup_release_lock
        error_exit "Backup pre-flight checks failed" "$E_BACKUP_NOSPACE"
    fi
    
    # Generate filenames
    local basename backup_file metadata_file
    basename=$(backup_generate_filename)
    backup_file="$BACKUP_DIR/${basename}.sql.gz"
    metadata_file="$BACKUP_DIR/${basename}.json"
    
    log_info "Backup file: $backup_file"
    log_info "Metadata file: $metadata_file"
    
    # Create temporary files
    local temp_backup temp_metadata
    temp_backup=$(mktemp -t vmangos_backup.XXXXXX)
    temp_metadata=$(mktemp -t vmangos_metadata.XXXXXX)
    
    # Cleanup on failure
    cleanup_partial() {
        rm -f "$temp_backup" "$temp_metadata"
        rm -f "$backup_file" "$metadata_file"
        backup_release_lock
    }
    
    # Perform backup
    log_info "Dumping databases..."
    local opts
    opts=$(backup_mysql_opts)
    
    # Dump all required databases
    if ! mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" ${DB_PASS:+-p$DB_PASS} \
        --single-transaction \
        --routines \
        --triggers \
        --databases "${BACKUP_DATABASES[@]}" \
        2>/dev/null | gzip > "$temp_backup"; then
        log_error "mysqldump failed"
        cleanup_partial
        error_exit "Database dump failed" "$E_BACKUP_MYSQLDUMP"
    fi
    
    local backup_size
    backup_size=$(stat -c%s "$temp_backup")
    log_info "Backup size: $backup_size bytes"
    
    # Generate metadata
    log_info "Generating metadata..."
    local checksum timestamp
    checksum=$(sha256sum "$temp_backup" | cut -d' ' -f1)
    timestamp=$(date -Iseconds)
    
    # Create metadata JSON
    cat > "$temp_metadata" << EOF
{
  "timestamp": "$timestamp",
  "file": "${basename}.sql.gz",
  "basename": "$basename",
  "size_bytes": $backup_size,
  "checksum_sha256": "$checksum",
  "databases": [$(printf '"%s",' "${BACKUP_DATABASES[@]}" | sed 's/,$//')],
  "vmangos_commit": "e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149",
  "created_by": "vmangos-manager $(cd "$(dirname "$0")" && ./bin/vmangos-manager --version 2>/dev/null | awk '{print $3}')"
}
EOF
    
    # Atomic move to final location
    log_info "Finalizing backup..."
    if ! mv "$temp_backup" "$backup_file"; then
        cleanup_partial
        error_exit "Failed to move backup file" "$E_BACKUP_METADATA"
    fi
    
    if ! mv "$temp_metadata" "$metadata_file"; then
        rm -f "$backup_file"
        cleanup_partial
        error_exit "Failed to move metadata file" "$E_BACKUP_METADATA"
    fi
    
    backup_release_lock
    
    log_info "✓ Backup complete: $backup_file"
    
    # Optional verification
    if [[ "$verify" == "true" ]]; then
        log_info "Running post-backup verification..."
        if ! backup_verify "$backup_file" 1; then
            log_error "Backup verification failed"
            return 1
        fi
        log_info "✓ Verification passed"
    fi
    
    # Output result
    json_output true "{\"backup_file\": \"$backup_file\", \"metadata_file\": \"$metadata_file\", \"size_bytes\": $backup_size}"
    return 0
}

# ============================================================================
# VERIFICATION ENGINE
# ============================================================================

backup_verify() {
    local backup_file="$1"
    local level="${2:-1}"
    
    log_section "Backup Verification (Level $level)"
    
    # Validate backup file exists
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    # Find metadata file
    local metadata_file
    metadata_file="${backup_file%.sql.gz}.json"
    if [[ ! -f "$metadata_file" ]]; then
        log_warn "Metadata file not found: $metadata_file"
        metadata_file=""
    fi
    
    # Level 1: Archive integrity + checksum
    if ! verify_level_1 "$backup_file" "$metadata_file"; then
        return 1
    fi
    
    # Level 2: SQL structure + table presence
    if [[ "$level" -ge 2 ]]; then
        if ! verify_level_2 "$backup_file"; then
            return 1
        fi
    fi
    
    log_info "✓ Verification passed (Level $level)"
    return 0
}

verify_level_1() {
    local backup_file="$1"
    local metadata_file="$2"
    
    log_info "Level 1: Archive integrity check..."
    
    # Test gzip integrity
    if ! gunzip -t "$backup_file" 2>/dev/null; then
        log_error "Backup file is corrupt (gunzip test failed)"
        json_output false "null" "VERIFY_CORRUPT" "Backup file failed gunzip integrity test" "File may be incomplete or corrupted"
        return "$E_VERIFY_CORRUPT"
    fi
    
    log_info "✓ Archive integrity OK"
    
    # Verify checksum if metadata exists
    if [[ -n "$metadata_file" && -f "$metadata_file" ]]; then
        log_info "Verifying checksum..."
        
        local stored_checksum actual_checksum
        stored_checksum=$(jq -r '.checksum_sha256' "$metadata_file" 2>/dev/null)
        actual_checksum=$(sha256sum "$backup_file" | cut -d' ' -f1)
        
        if [[ "$stored_checksum" != "$actual_checksum" ]]; then
            log_error "Checksum mismatch"
            log_error "  Stored:   $stored_checksum"
            log_error "  Actual:   $actual_checksum"
            json_output false "null" "VERIFY_CORRUPT" "Backup file checksum mismatch" "File may have been modified or corrupted"
            return "$E_VERIFY_CORRUPT"
        fi
        
        log_info "✓ Checksum verified"
    else
        log_warn "No metadata file, skipping checksum verification"
    fi
    
    return 0
}

verify_level_2() {
    local backup_file="$1"
    
    log_info "Level 2: SQL structure and table presence..."
    
    # Extract first 1000 lines for header inspection
    local header
    header=$(gunzip -c "$backup_file" 2>/dev/null | head -1000)
    
    if [[ -z "$header" ]]; then
        log_error "Cannot read backup file header"
        return "$E_VERIFY_INCOMPLETE"
    fi
    
    # Check for SQL dump header indicators
    if [[ ! "$header" =~ "MySQL dump" ]]; then
        log_error "SQL dump header not found"
        json_output false "null" "VERIFY_INCOMPLETE" "Backup missing MySQL dump header" "File may not be a valid SQL dump"
        return "$E_VERIFY_INCOMPLETE"
    fi
    
    log_info "✓ SQL dump header present"
    
    # Check for required table structures
    local missing_tables=()
    
    for table in "${BACKUP_REQUIRED_TABLES[@]}"; do
        local tbl_name
        tbl_name="${table#*.}"
        
        # Look for CREATE TABLE statement
        if ! gunzip -c "$backup_file" 2>/dev/null | grep -q "CREATE TABLE.*\`$tbl_name\`"; then
            missing_tables+=("$table")
        fi
    done
    
    if [[ ${#missing_tables[@]} -gt 0 ]]; then
        log_error "Missing required tables:"
        for tbl in "${missing_tables[@]}"; do
            log_error "  - $tbl"
        done
        json_output false "null" "VERIFY_INCOMPLETE" "Backup missing required tables" "Backup may be incomplete"
        return "$E_VERIFY_INCOMPLETE"
    fi
    
    log_info "✓ All required tables present"
    return 0
}

# ============================================================================
# RESTORE PATH
# ============================================================================

backup_restore() {
    local backup_file="$1"
    local dry_run="${2:-false}"
    
    log_section "VMANGOS Backup Restore"
    
    # Load configuration
    backup_load_config || error_exit "Failed to load configuration" "$E_CONFIG_ERROR"
    server_load_config || error_exit "Failed to load server configuration" "$E_CONFIG_ERROR"
    
    # Validate backup file
    if [[ ! -f "$backup_file" ]]; then
        error_exit "Backup file not found: $backup_file" "$E_CONFIG_ERROR"
    fi
    
    # Dry-run mode
    if [[ "$dry_run" == "true" ]]; then
        backup_restore_dry_run "$backup_file"
        return 0
    fi
    
    # WARNING: Restore requires downtime and root privileges
    echo ""
    log_warn "⚠️  RESTORE OPERATION REQUIRES SERVER DOWNTIME ⚠️"
    log_warn ""
    log_warn "This operation will:"
    log_warn "  1. STOP the VMANGOS server (world + auth services)"
    log_warn "  2. DROP all existing databases"
    log_warn "  3. RESTORE from backup: $backup_file"
    log_warn "  4. START the VMANGOS server"
    log_warn ""
    log_warn "Required:"
    log_warn "  - Root database credentials (not vmangos_mgr)"
    log_warn "  - Server downtime (users will be disconnected)"
    log_warn ""
    
    # Require explicit confirmation
    if [[ "${FORCE_RESTORE:-0}" != "1" ]]; then
        echo -n "Type 'RESTORE' to confirm: "
        read -r confirmation
        if [[ "$confirmation" != "RESTORE" ]]; then
            log_info "Restore cancelled"
            return 1
        fi
    fi
    
    # Verify backup before proceeding
    log_info "Verifying backup integrity..."
    if ! backup_verify "$backup_file" 1; then
        error_exit "Backup verification failed - restore aborted" "$E_VERIFY_CORRUPT"
    fi
    
    # Stop services (world first, then auth)
    log_info "Stopping VMANGOS services..."
    server_stop false false || {
        log_error "Failed to stop services cleanly"
        log_warn "Proceeding anyway..."
    }
    
    # Restore databases
    
    # Restore from backup (single import of full dump)
    log_info "Restoring from backup: $backup_file"
    log_info "This will restore all databases: ${BACKUP_DATABASES[*]}"
    
    if ! backup_restore_full "$backup_file"; then
        log_error "═══════════════════════════════════════════════════"
        log_error "  RESTORE FAILED"
        log_error "═══════════════════════════════════════════════════"
        log_error ""
        log_error "The database restore operation failed."
        log_error "Your databases may be in an INCONSISTENT state."
        log_error "Manual intervention is required."
        log_error ""
        
        # Try to restart services anyway so the server is not left down
        log_warn "Attempting to restart services..."
        server_start false || true
        
        json_output false "null" "RESTORE_PARTIAL" "Database restore failed" "Databases may be in an inconsistent state. Manual intervention required."
        return "$E_RESTORE_PARTIAL"
    fi
    
    log_info "✓ Database restore complete"
    
    log_info "✓ Restore complete"
    json_output true "{\"restored_from\": \"$backup_file\", \"databases\": [$(printf '"%s",' "${BACKUP_DATABASES[@]}" | sed 's/,$//')]}"
    return 0
}

backup_restore_full() {
    local backup_file="$1"
    
    # Check for root credentials
    if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
        log_error "Root database password not provided"
        log_info "Set MYSQL_ROOT_PASSWORD environment variable"
        return "$E_RESTORE_PRIVS"
    fi
    
    # Create temporary MySQL options file (avoids password in process list)
    local mysql_defaults
    mysql_defaults=$(mktemp -t vmangos_restore.XXXXXX)
    chmod 600 "$mysql_defaults"
    
    cat > "$mysql_defaults" << EOF
[client]
host = $DB_HOST
port = $DB_PORT
user = root
password = $MYSQL_ROOT_PASSWORD
EOF
    
    # Restore from backup using defaults file
    local restore_result=0
    if ! gunzip -c "$backup_file" 2>/dev/null | mysql --defaults-file="$mysql_defaults" 2>/dev/null; then
        restore_result=1
    fi
    
    # Clean up temporary file
    rm -f "$mysql_defaults"
    
    return "$restore_result"
}

backup_restore_dry_run() {
    local backup_file="$1"
    
    log_info "RESTORE DRY-RUN: What would happen"
    echo ""
    echo "Backup file: $backup_file"
    echo ""
    
    # Show backup metadata
    local metadata_file
    metadata_file="${backup_file%.sql.gz}.json"
    if [[ -f "$metadata_file" ]]; then
        echo "Backup metadata:"
        jq < "$metadata_file" -r '
            "  Created: \(.timestamp)",
            "  Size: \(.size_bytes) bytes",
            "  Databases: \(.databases | join(", "))"
        ' 2>/dev/null || echo "  (metadata parse error)"
        echo ""
    fi
    
    echo "Actions that would be taken:"
    echo "  1. Stop world service"
    echo "  2. Stop auth service"
    echo "  3. Restore databases from backup"
    for db in "${BACKUP_DATABASES[@]}"; do
        echo "     - $db"
    done
    echo "  4. Start auth service"
    echo "  5. Start world service"
    echo ""
    echo "Requirements:"
    echo "  - Root database credentials (not vmangos_mgr)"
    echo "  - Server downtime (users will be disconnected)"
    echo ""
    echo "Estimated downtime: 1-5 minutes depending on backup size"
    echo ""
}

# ============================================================================
# SCHEDULING SYSTEM
# ============================================================================

backup_schedule() {
    local schedule_type="$1"
    local schedule_value="$2"
    
    log_section "Backup Scheduling"
    
    case "$schedule_type" in
        daily)
            schedule_parse_daily "$schedule_value" || return 1
            schedule_create_daily "$schedule_value" || return 1
            ;;
        weekly)
            schedule_parse_weekly "$schedule_value" || return 1
            schedule_create_weekly "$schedule_value" || return 1
            ;;
        *)
            error_exit "Invalid schedule type: $schedule_type (use 'daily' or 'weekly')" "$E_SCHEDULE_INVALID"
            ;;
    esac
    
    log_info "✓ Backup schedule created"
    return 0
}

schedule_parse_daily() {
    local time_str="$1"
    
    # Validate HH:MM format (24-hour)
    if [[ ! "$time_str" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        log_error "Invalid time format: $time_str"
        log_info "Expected format: HH:MM (24-hour, e.g., 04:00, 23:30)"
        return "$E_SCHEDULE_INVALID"
    fi
    
    return 0
}

schedule_parse_weekly() {
    local schedule_str="$1"
    
    # Validate "Day HH:MM" format
    local day time
    day=$(echo "$schedule_str" | awk '{print $1}')
    time=$(echo "$schedule_str" | awk '{print $2}')
    
    # Validate day
    local valid_days="Mon Tue Wed Thu Fri Sat Sun"
    if [[ ! "$valid_days" =~ (^| )$day($| ) ]]; then
        log_error "Invalid day: $day"
        log_info "Valid days: Mon, Tue, Wed, Thu, Fri, Sat, Sun"
        return "$E_SCHEDULE_INVALID"
    fi
    
    # Validate time
    if [[ ! "$time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        log_error "Invalid time format: $time"
        log_info "Expected format: HH:MM (24-hour)"
        return "$E_SCHEDULE_INVALID"
    fi
    
    return 0
}

schedule_create_daily() {
    local time_str="$1"
    local hour minute
    hour="${time_str%%:*}"
    minute="${time_str#*:}"
    
    local timer_name="vmangos-backup-daily"
    local service_name="vmangos-backup"
    
    # Create systemd service file
    local service_file="/etc/systemd/system/${service_name}.service"
    log_info "Creating service: $service_file"
    
    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=VMANGOS Daily Backup
After=network.target

[Service]
Type=oneshot
ExecStart="$MANAGER_BIN" backup now --verify
User=root
StandardOutput=journal
StandardError=journal
EOF
    
    # Create systemd timer file (Ubuntu 22.04 format)
    local timer_file="/etc/systemd/system/${timer_name}.timer"
    log_info "Creating timer: $timer_file"
    
    sudo tee "$timer_file" > /dev/null << EOF
[Unit]
Description=Run VMANGOS backup daily at $time_str

[Timer]
OnCalendar=*-*-* $hour:$minute:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Reload and enable
    log_info "Enabling timer..."
    sudo systemctl daemon-reload
    sudo systemctl enable "${timer_name}.timer"
    sudo systemctl start "${timer_name}.timer"
    
    log_info "✓ Daily backup scheduled for $time_str"
    log_info "Timer status:"
    systemctl list-timers "${timer_name}.timer" 2>/dev/null || true
    
    return 0
}

schedule_create_weekly() {
    local schedule_str="$1"
    local day time
    day=$(echo "$schedule_str" | awk '{print $1}')
    time=$(echo "$schedule_str" | awk '{print $2}')
    
    local hour minute
    hour="${time%%:*}"
    minute="${time#*:}"
    
    local timer_name="vmangos-backup-weekly"
    local service_name="vmangos-backup"
    
    # Create systemd service file
    local service_file="/etc/systemd/system/${service_name}.service"
    log_info "Creating service: $service_file"
    
    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=VMANGOS Weekly Backup
After=network.target

[Service]
Type=oneshot
ExecStart="$MANAGER_BIN" backup now --verify
User=root
StandardOutput=journal
StandardError=journal
EOF
    
    # Create systemd timer file (Ubuntu 22.04 format)
    local timer_file="/etc/systemd/system/${timer_name}.timer"
    log_info "Creating timer: $timer_file"
    
    sudo tee "$timer_file" > /dev/null << EOF
[Unit]
Description=Run VMANGOS backup weekly on $day at $time

[Timer]
OnCalendar=$day *-*-* $hour:$minute:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Reload and enable
    log_info "Enabling timer..."
    sudo systemctl daemon-reload
    sudo systemctl enable "${timer_name}.timer"
    sudo systemctl start "${timer_name}.timer"
    
    log_info "✓ Weekly backup scheduled for $day at $time"
    log_info "Timer status:"
    systemctl list-timers "${timer_name}.timer" 2>/dev/null || true
    
    return 0
}

# ============================================================================
# MAINTENANCE OPERATIONS
# ============================================================================

backup_list() {
    local format="${1:-text}"
    
    log_section "Backup List"
    
    backup_load_config || return 1
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        return 1
    fi
    
    # Find all backup metadata files
    local metadata_files=()
    while IFS= read -r -d '' file; do
        metadata_files+=("$file")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.json" -type f -print0 2>/dev/null | sort -z)
    
    if [[ ${#metadata_files[@]} -eq 0 ]]; then
        log_info "No backups found in $BACKUP_DIR"
        return 0
    fi
    
    if [[ "$format" == "json" ]]; then
        # Output JSON array
        echo "["
        local first=1
        for meta_file in "${metadata_files[@]}"; do
            [[ $first -eq 1 ]] || echo ","
            first=0
            jq -c . "$meta_file" 2>/dev/null || echo "null"
        done
        echo ""
        echo "]"
    else
        # Output text table
        echo ""
        printf "%-20s %-12s %-10s %s\n" "Timestamp" "Size" "Verified" "File"
        printf "%-20s %-12s %-10s %s\n" "--------------------" "------------" "----------" "----"
        
        for meta_file in "${metadata_files[@]}"; do
            local timestamp size_bytes file verified
            timestamp=$(jq -r '.timestamp' "$meta_file" 2>/dev/null | cut -d'T' -f1)
            size_bytes=$(jq -r '.size_bytes' "$meta_file" 2>/dev/null)
            file=$(jq -r '.file' "$meta_file" 2>/dev/null)
            
            # Check if backup file exists and verify checksum
            local backup_file="$BACKUP_DIR/$file"
            if [[ -f "$backup_file" ]]; then
                local stored_checksum actual_checksum
                stored_checksum=$(jq -r '.checksum_sha256' "$meta_file" 2>/dev/null)
                actual_checksum=$(sha256sum "$backup_file" 2>/dev/null | cut -d' ' -f1)
                if [[ "$stored_checksum" == "$actual_checksum" ]]; then
                    verified="✓"
                else
                    verified="✗"
                fi
            else
                verified="MISSING"
            fi
            
            # Format size
            local size_str
            if [[ "$size_bytes" -gt 1073741824 ]]; then
                size_str=$(echo "scale=1; $size_bytes/1073741824" | bc)G
            elif [[ "$size_bytes" -gt 1048576 ]]; then
                size_str=$(echo "scale=1; $size_bytes/1048576" | bc)M
            elif [[ "$size_bytes" -gt 1024 ]]; then
                size_str=$(echo "scale=1; $size_bytes/1024" | bc)K
            else
                size_str="${size_bytes}B"
            fi
            
            printf "%-20s %-12s %-10s %s\n" "$timestamp" "$size_str" "$verified" "$file"
        done
        echo ""
    fi
}

backup_clean() {
    local keep_last="${1:-}"
    
    log_section "Backup Cleanup"
    
    backup_load_config || return 1
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        return 1
    fi
    
    # Determine retention strategy
    if [[ -n "$keep_last" ]]; then
        log_info "Retention strategy: keep last $keep_last backups"
    else
        keep_last="$BACKUP_RETENTION_DAYS"
        log_info "Retention strategy: keep last $keep_last backups (from config)"
    fi
    
    # Get all backups sorted by timestamp (from metadata)
    local all_backups=()
    while IFS= read -r -d '' meta_file; do
        local timestamp basename
        timestamp=$(jq -r '.timestamp' "$meta_file" 2>/dev/null)
        basename=$(jq -r '.basename' "$meta_file" 2>/dev/null)
        if [[ -n "$timestamp" && -n "$basename" ]]; then
            all_backups+=("$timestamp|$basename|$meta_file")
        fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.json" -type f -print0 2>/dev/null)
    
    # Sort by timestamp (newest first)
    local sorted_backups=()
    while IFS="" read -r line; do
        sorted_backups+=("$line")
    done < <(printf "%s\n" "${all_backups[@]}" | sort -r -t"|" -k1)
    
    local total_count=${#sorted_backups[@]}
    log_info "Found $total_count backups"
    
    if [[ "$total_count" -le "$keep_last" ]]; then
        log_info "Nothing to clean (keeping all $total_count backups)"
        return 0
    fi
    
    local to_delete=$((total_count - keep_last))
    log_info "Will delete $to_delete old backups"
    
    # Delete old backups
    local deleted=0
    for ((i=keep_last; i<total_count; i++)); do
        local entry="${sorted_backups[$i]}"
        local basename="${entry#*|}"
        basename="${basename%|*}"
        
        local backup_file="$BACKUP_DIR/${basename}.sql.gz"
        local metadata_file="$BACKUP_DIR/${basename}.json"
        
        log_info "Deleting: $basename"
        
        [[ -f "$backup_file" ]] && rm -f "$backup_file"
        [[ -f "$metadata_file" ]] && rm -f "$metadata_file"
        
        deleted=$((deleted + 1))
    done
    
    log_info "✓ Cleanup complete: deleted $deleted backups, kept $keep_last"
    return 0
}
