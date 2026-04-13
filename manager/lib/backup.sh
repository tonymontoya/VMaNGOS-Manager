#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Backup module for VMANGOS Manager
# Full SQL backup, verification, restore, and scheduling
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/server.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

export BACKUP_CONFIG_LOADED=""
export BACKUP_DIR=""
export BACKUP_RETENTION_DAYS=""
export BACKUP_VERIFY_AFTER=""
export MANAGER_BIN="${MANAGER_BIN:-}"

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

    server_load_config || {
        log_error "Failed to load server configuration"
        return 1
    }

    BACKUP_DATABASES=("$AUTH_DB" "${CONFIG_DATABASE_CHARACTERS_DB:-characters}" "${CONFIG_DATABASE_WORLD_DB:-mangos}" "${CONFIG_DATABASE_LOGS_DB:-logs}")
    MANAGER_BIN="$(backup_resolve_manager_bin)"
    
    BACKUP_CONFIG_LOADED="1"
    log_debug "Backup configuration loaded: dir=$BACKUP_DIR"
    return 0
}

backup_resolve_manager_bin() {
    local manager_root

    if [[ -n "${MANAGER_BIN:-}" ]]; then
        printf '%s' "$MANAGER_BIN"
        return 0
    fi

    manager_root=$(config_resolve_manager_root "$CONFIG_FILE")
    local configured_path="$manager_root/bin/vmangos-manager"
    local repo_path
    repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/vmangos-manager"

    if [[ -x "$configured_path" ]]; then
        printf '%s' "$configured_path"
    elif [[ -x "$repo_path" ]]; then
        printf '%s' "$repo_path"
    else
        printf '%s' "$configured_path"
    fi
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

backup_manager_version() {
    local manager_bin_path
    manager_bin_path="$(backup_resolve_manager_bin)"

    if [[ -x "$manager_bin_path" ]]; then
        "$manager_bin_path" --version 2>/dev/null | awk '{print $4}'
    else
        printf '%s' 'unknown'
    fi
}

metadata_json_get() {
    local metadata_file="$1"
    local key="$2"

    awk -v key="$key" '
        {
            if (match($0, "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
                value = substr($0, RSTART, RLENGTH)
                sub(/^[^:]*:[[:space:]]*"/, "", value)
                sub(/"$/, "", value)
                print value
                exit
            }
            if (match($0, "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+")) {
                value = substr($0, RSTART, RLENGTH)
                sub(/^[^:]*:[[:space:]]*/, "", value)
                print value
                exit
            }
        }
    ' "$metadata_file"
}

metadata_json_array_values() {
    local metadata_file="$1"
    local key="$2"

    local line values
    line=$(grep -m1 "\"$key\"" "$metadata_file" 2>/dev/null || true)
    [[ -n "$line" ]] || return 0

    values=$(printf '%s\n' "$line" | sed -E 's/^[^[]*\[//; s/\].*$//; s/"//g; s/[[:space:]]*,[[:space:]]*/\n/g')
    if [[ -n "$values" ]]; then
        printf '%s\n' "$values"
    fi
}

metadata_json_array_join() {
    local metadata_file="$1"
    local key="$2"
    local joined

    joined=$(metadata_json_array_values "$metadata_file" "$key" | paste -sd ', ' -)
    printf '%s' "$joined"
}

metadata_json_array_count() {
    local metadata_file="$1"
    local key="$2"

    metadata_json_array_values "$metadata_file" "$key" | awk 'NF {count++} END {print count+0}'
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
    backup_size=$(get_file_size_bytes "$temp_backup")
    log_info "Backup size: $backup_size bytes"
    
    # Generate metadata
    log_info "Generating metadata..."
    local checksum manager_version timestamp
    checksum=$(sha256_file "$temp_backup")
    manager_version=$(backup_manager_version)
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
    "created_by": "vmangos-manager $manager_version"
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

    backup_load_config || return 1
    server_load_config || return 1
    
    # Validate backup file exists
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    # Find metadata file
    local metadata_file
    metadata_file="${backup_file%.sql.gz}.json"
    if [[ ! -f "$metadata_file" ]]; then
        log_error "Metadata file not found: $metadata_file"
        json_output false "null" "VERIFY_INCOMPLETE" "Backup metadata file missing" "Backups must include sidecar metadata to verify"
        return "$E_VERIFY_INCOMPLETE"
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
    log_info "Verifying checksum..."

    local stored_checksum actual_checksum
    stored_checksum=$(metadata_json_get "$metadata_file" "checksum_sha256")
    actual_checksum=$(sha256_file "$backup_file")

    if [[ -z "$stored_checksum" ]]; then
        log_error "Metadata checksum missing or malformed"
        json_output false "null" "VERIFY_INCOMPLETE" "Backup metadata checksum missing" "Metadata must include checksum_sha256"
        return "$E_VERIFY_INCOMPLETE"
    fi

    if [[ "$stored_checksum" != "$actual_checksum" ]]; then
        log_error "Checksum mismatch"
        log_error "  Stored:   $stored_checksum"
        log_error "  Actual:   $actual_checksum"
        json_output false "null" "VERIFY_CORRUPT" "Backup file checksum mismatch" "File may have been modified or corrupted"
        return "$E_VERIFY_CORRUPT"
    fi

    log_info "✓ Checksum verified"
    
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
    if [[ "$header" != *"MySQL dump"* && "$header" != *"MariaDB dump"* ]]; then
        log_error "SQL dump header not found"
        json_output false "null" "VERIFY_INCOMPLETE" "Backup missing SQL dump header" "File may not be a valid SQL dump"
        return "$E_VERIFY_INCOMPLETE"
    fi
    
    log_info "✓ SQL dump header present"
    
    # Check for required table structures
    local missing_tables=()
    
    # Build required tables list from actual DB names
    local required_tables=(
        "$AUTH_DB.account"
        "$AUTH_DB.account_banned"
        "$AUTH_DB.realmcharacters"
        "${CONFIG_DATABASE_CHARACTERS_DB:-characters}.characters"
        "${CONFIG_DATABASE_CHARACTERS_DB:-characters}.character_inventory"
        "${CONFIG_DATABASE_CHARACTERS_DB:-characters}.character_homebind"
        "${CONFIG_DATABASE_WORLD_DB:-world}.creature"
        "${CONFIG_DATABASE_WORLD_DB:-world}.gameobject"
        "${CONFIG_DATABASE_WORLD_DB:-world}.item_template"
        "${CONFIG_DATABASE_WORLD_DB:-world}.quest_template"
    )
    
    for table in "${required_tables[@]}"; do
        local db_name tbl_name
        db_name="${table%%.*}"
        tbl_name="${table#*.}"

        if ! backup_dump_has_table "$backup_file" "$db_name" "$tbl_name"; then
            missing_tables+=("$table")
        fi
    done

    local logs_db_name
    logs_db_name="${CONFIG_DATABASE_LOGS_DB:-logs}"
    if ! backup_dump_has_any_table_in_db "$backup_file" "$logs_db_name"; then
        missing_tables+=("$logs_db_name.<any table>")
    fi
    
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

backup_dump_has_table() {
    local backup_file="$1"
    local target_db="$2"
    local target_table="$3"

    gunzip -c "$backup_file" 2>/dev/null | awk -v target_db="$target_db" -v target_table="$target_table" '
        /^-- Current Database: `/ {
            if (match($0, /`[^`]+`/)) {
                current_db = substr($0, RSTART + 1, RLENGTH - 2)
            }
            next
        }
        /^USE `/ {
            if (match($0, /`[^`]+`/)) {
                current_db = substr($0, RSTART + 1, RLENGTH - 2)
            }
            next
        }
        current_db == target_db && $0 ~ "CREATE TABLE.*`" target_table "`" {
            found = 1
            next
        }
        END {
            exit found ? 0 : 1
        }
    '
}

backup_dump_has_any_table_in_db() {
    local backup_file="$1"
    local target_db="$2"

    gunzip -c "$backup_file" 2>/dev/null | awk -v target_db="$target_db" '
        /^-- Current Database: `/ {
            if (match($0, /`[^`]+`/)) {
                current_db = substr($0, RSTART + 1, RLENGTH - 2)
            }
            next
        }
        /^USE `/ {
            if (match($0, /`[^`]+`/)) {
                current_db = substr($0, RSTART + 1, RLENGTH - 2)
            }
            next
        }
        current_db == target_db && /^CREATE TABLE `/ {
            found = 1
            next
        }
        END {
            exit found ? 0 : 1
        }
    '
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
    local mysql_defaults
    mysql_defaults=$(backup_restore_defaults_file) || return "$E_RESTORE_PRIVS"
    
    # Restore from backup using defaults file
    local restore_result=0
    if ! gunzip -c "$backup_file" 2>/dev/null | mysql --defaults-file="$mysql_defaults" 2>/dev/null; then
        restore_result=1
    fi
    
    # Clean up temporary file
    rm -f "$mysql_defaults"
    
    return "$restore_result"
}

backup_restore_defaults_file() {
    if [[ -n "${MYSQL_RESTORE_DEFAULTS_FILE:-}" ]]; then
        if [[ ! -f "$MYSQL_RESTORE_DEFAULTS_FILE" ]]; then
            log_error "Restore defaults file not found: $MYSQL_RESTORE_DEFAULTS_FILE"
            return "$E_RESTORE_PRIVS"
        fi

        printf '%s' "$MYSQL_RESTORE_DEFAULTS_FILE"
        return 0
    fi

    if [[ -z "${MYSQL_RESTORE_PASSWORD:-}" ]]; then
        log_error "Privileged restore credentials not provided"
        log_info "Set MYSQL_RESTORE_DEFAULTS_FILE or MYSQL_RESTORE_PASSWORD before running restore"
        return "$E_RESTORE_PRIVS"
    fi

    local restore_user="${MYSQL_RESTORE_USER:-root}"
    local mysql_defaults
    mysql_defaults=$(mktemp_secure vmangos_restore.XXXXXX)

    cat > "$mysql_defaults" << EOF
[client]
host = $DB_HOST
port = $DB_PORT
user = $restore_user
password = $MYSQL_RESTORE_PASSWORD
EOF

    printf '%s' "$mysql_defaults"
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
        local created_at size_bytes databases
        created_at=$(metadata_json_get "$metadata_file" "timestamp")
        size_bytes=$(metadata_json_get "$metadata_file" "size_bytes")
        databases=$(metadata_json_array_join "$metadata_file" "databases")
        if [[ -n "$created_at" || -n "$size_bytes" || -n "$databases" ]]; then
            [[ -n "$created_at" ]] && echo "  Created: $created_at"
            [[ -n "$size_bytes" ]] && echo "  Size: $size_bytes bytes"
            [[ -n "$databases" ]] && echo "  Databases: $databases"
        else
            echo "  (metadata parse error)"
        fi
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
    echo "  - Explicit privileged database credentials"
    echo "    Use MYSQL_RESTORE_DEFAULTS_FILE or MYSQL_RESTORE_PASSWORD"
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

backup_service_unit_content() {
    local description="$1"
    local manager_bin_path="$2"

    cat << EOF
[Unit]
Description=$description
After=network.target

[Service]
Type=oneshot
ExecStart=$manager_bin_path backup now --verify
User=root
StandardOutput=journal
StandardError=journal
EOF
}

backup_timer_unit_content() {
    local description="$1"
    local on_calendar="$2"

    cat << EOF
[Unit]
Description=$description

[Timer]
OnCalendar=$on_calendar
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

schedule_create_daily() {
    local time_str="$1"
    local hour minute
    hour="${time_str%%:*}"
    minute="${time_str#*:}"
    
    local timer_name="vmangos-backup-daily"
    local service_name="vmangos-backup"
    local manager_bin_path
    manager_bin_path="$(backup_resolve_manager_bin)"
    
    # Create systemd service file
    local service_file="/etc/systemd/system/${service_name}.service"
    log_info "Creating service: $service_file"
    
    backup_service_unit_content "VMANGOS Daily Backup" "$manager_bin_path" | sudo tee "$service_file" > /dev/null
    
    # Create systemd timer file (Ubuntu 22.04 format)
    local timer_file="/etc/systemd/system/${timer_name}.timer"
    log_info "Creating timer: $timer_file"
    
    backup_timer_unit_content "Run VMANGOS backup daily at $time_str" "*-*-* $hour:$minute:00" | sudo tee "$timer_file" > /dev/null
    
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
    local manager_bin_path
    manager_bin_path="$(backup_resolve_manager_bin)"
    
    # Create systemd service file
    local service_file="/etc/systemd/system/${service_name}.service"
    log_info "Creating service: $service_file"
    
    backup_service_unit_content "VMANGOS Weekly Backup" "$manager_bin_path" | sudo tee "$service_file" > /dev/null
    
    # Create systemd timer file (Ubuntu 22.04 format)
    local timer_file="/etc/systemd/system/${timer_name}.timer"
    log_info "Creating timer: $timer_file"
    
    backup_timer_unit_content "Run VMANGOS backup weekly on $day at $time" "$day *-*-* $hour:$minute:00" | sudo tee "$timer_file" > /dev/null
    
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
            tr -d '\n' < "$meta_file" || echo "null"
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
            timestamp=$(metadata_json_get "$meta_file" "timestamp" | cut -d'T' -f1)
            size_bytes=$(metadata_json_get "$meta_file" "size_bytes")
            file=$(metadata_json_get "$meta_file" "file")
            
            # Check if backup file exists and verify checksum
            local backup_file="$BACKUP_DIR/$file"
            if [[ -f "$backup_file" ]]; then
                local stored_checksum actual_checksum
                stored_checksum=$(metadata_json_get "$meta_file" "checksum_sha256")
                actual_checksum=$(sha256_file "$backup_file")
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
    
    # Get all backups with metadata
    local all_backups=()
    while IFS= read -r -d '' meta_file; do
        local timestamp basename
        timestamp=$(metadata_json_get "$meta_file" "timestamp")
        basename=$(metadata_json_get "$meta_file" "basename")
        if [[ -n "$timestamp" && -n "$basename" ]]; then
            all_backups+=("$timestamp|$basename|$meta_file")
        fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.json" -type f -print0 2>/dev/null)
    
    local total_count=${#all_backups[@]}
    log_info "Found $total_count backups"
    
    if [[ ${#all_backups[@]} -eq 0 ]]; then
        log_info "No backups to clean"
        return 0
    fi
    
    local deleted=0
    
    if [[ -n "$keep_last" ]]; then
        # Count-based retention (--keep-last N)
        log_info "Retention strategy: keep last $keep_last backups (count-based)"
        
        if [[ "$total_count" -le "$keep_last" ]]; then
            log_info "Nothing to clean (keeping all $total_count backups)"
            return 0
        fi
        
        # Sort by timestamp (newest first)
        local sorted_backups=()
        while IFS="" read -r line; do
            sorted_backups+=("$line")
        done < <(printf "%s\n" "${all_backups[@]}" | sort -r -t"|" -k1)
        
        # Delete old backups beyond keep_last
        for ((i=keep_last; i<${#sorted_backups[@]}; i++)); do
            local entry="${sorted_backups[$i]}"
            local basename="${entry#*|}"
            basename="${basename%|*}"
            
            log_info "Deleting: $basename"
            rm -f "$BACKUP_DIR/${basename}.sql.gz" "$BACKUP_DIR/${basename}.json"
            deleted=$((deleted + 1))
        done
    else
        # Age-based retention (retention_days config)
        local retention_days="$BACKUP_RETENTION_DAYS"
        log_info "Retention strategy: delete backups older than $retention_days days (age-based)"
        
        # Calculate cutoff date (retention_days ago)
        local cutoff_date
        cutoff_date=$(date -d "$retention_days days ago" +%Y-%m-%d 2>/dev/null || date -v-"${retention_days}"d +%Y-%m-%d)
        log_info "Cutoff date: $cutoff_date (backups older than this will be deleted)"
        
        # Check each backup's age
        for entry in "${all_backups[@]}"; do
            local timestamp basename
            timestamp="${entry%%|*}"
            basename="${entry#*|}"
            basename="${basename%|*}"
            
            # Extract date from timestamp (ISO 8601 format: 2026-04-13T10:00:00+00:00)
            local backup_date="${timestamp%%T*}"
            
            if [[ "$backup_date" < "$cutoff_date" ]]; then
                log_info "Deleting: $basename (age: $backup_date, cutoff: $cutoff_date)"
                rm -f "$BACKUP_DIR/${basename}.sql.gz" "$BACKUP_DIR/${basename}.json"
                deleted=$((deleted + 1))
            fi
        done
    fi
    
    log_info "✓ Cleanup complete: deleted $deleted backups"
    return 0
}
