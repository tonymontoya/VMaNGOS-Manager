#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Database access module for VMANGOS Manager
# The single MySQL access layer: every mysql/mysqldump invocation in the
# codebase lives here. Credentials are passed via MYSQL_PWD, never on a
# command line (command lines are visible in ps output).
#
# Interface:
#   db_load_config                       load credentials + db names (idempotent)
#   db_name_for_role <role>              auth|characters|world|logs -> db name
#   db_query <db> <sql>                  run SQL, print rows (tab-separated)
#   db_exec <db> <sql>                   run SQL, discard output, return status
#   db_exec_file <db> <path>             import a .sql file, show errors
#   db_check_connection                  verify the server is reachable
#   db_dump <db>...                      mysqldump one or more databases to stdout
#   db_restore_credentials               validate privileged restore credentials
#   db_restore <file.sql.gz>             import a gzipped dump (privileged)
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

DB_CONFIG_LOADED=""
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
DB_AUTH_DB=""
DB_CHARACTERS_DB=""
DB_WORLD_DB=""
DB_LOGS_DB=""

# Single copy of the connection defaults for the whole codebase.
# CONFIG_DATABASE_* (from config_load) is the only other legitimate source.
db_load_config() {
    [[ "$DB_CONFIG_LOADED" == "1" ]] && return 0

    config_load "$CONFIG_FILE" || {
        [[ "${CONFIG_ERROR_REPORTED:-0}" == "1" ]] || log_error "Failed to load database configuration"
        return 1
    }

    DB_HOST="${CONFIG_DATABASE_HOST:-127.0.0.1}"
    DB_PORT="${CONFIG_DATABASE_PORT:-3306}"
    DB_USER="${CONFIG_DATABASE_USER:-mangos}"
    DB_PASS="${CONFIG_DATABASE_PASSWORD:-}"
    DB_AUTH_DB="${CONFIG_DATABASE_AUTH_DB:-auth}"
    DB_CHARACTERS_DB="${CONFIG_DATABASE_CHARACTERS_DB:-characters}"
    DB_WORLD_DB="${CONFIG_DATABASE_WORLD_DB:-mangos}"
    DB_LOGS_DB="${CONFIG_DATABASE_LOGS_DB:-logs}"

    DB_CONFIG_LOADED="1"
    log_debug "Database configuration loaded"
}

db_name_for_role() {
    local role="$1"

    db_load_config || return 1

    case "$role" in
        auth) printf '%s\n' "$DB_AUTH_DB" ;;
        characters) printf '%s\n' "$DB_CHARACTERS_DB" ;;
        world) printf '%s\n' "$DB_WORLD_DB" ;;
        logs) printf '%s\n' "$DB_LOGS_DB" ;;
        *)
            log_error "Unknown DB role: $role"
            return 1
            ;;
    esac
}

db_query() {
    local database="$1"
    local query="$2"

    db_load_config || return 1

    # MYSQL_PWD keeps credentials off the command line (visible via ps otherwise)
    MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -N -B -e "$query" "$database" 2>/dev/null
}

db_exec() {
    local database="$1"
    local query="$2"

    db_load_config || return 1

    db_query "$database" "$query" >/dev/null
}

db_exec_file() {
    local database="$1"
    local sql_file="$2"

    db_load_config || return 1

    [[ -r "$sql_file" ]] || {
        log_error "SQL file not readable: $sql_file"
        return 1
    }

    # Errors stream to stderr so failed migrations explain themselves
    MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -D "$database" < "$sql_file"
}

db_check_connection() {
    db_load_config || return 1
    db_query "$DB_AUTH_DB" "SELECT 1" >/dev/null
}

db_dump() {
    [[ $# -ge 1 ]] || {
        log_error "db_dump requires at least one database"
        return 1
    }

    db_load_config || return 1

    # MYSQL_PWD keeps credentials off the command line (visible via ps otherwise)
    MYSQL_PWD="$DB_PASS" mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" \
        --single-transaction \
        --routines \
        --triggers \
        --databases "$@" \
        2>/dev/null
}

db_restore_credentials() {
    if [[ -n "${MYSQL_RESTORE_DEFAULTS_FILE:-}" ]]; then
        if [[ ! -f "$MYSQL_RESTORE_DEFAULTS_FILE" ]]; then
            log_error "Restore defaults file not found: $MYSQL_RESTORE_DEFAULTS_FILE"
            return 1
        fi

        # The defaults file holds a plaintext password: keep it private
        local perms
        perms=$(get_file_permissions "$MYSQL_RESTORE_DEFAULTS_FILE" 2>/dev/null || echo "")
        if [[ -n "$perms" && "$perms" != "600" ]]; then
            log_error "Restore defaults file permissions are $perms, must be 600: $MYSQL_RESTORE_DEFAULTS_FILE"
            return 1
        fi

        return 0
    fi

    if [[ -z "${MYSQL_RESTORE_PASSWORD:-}" ]]; then
        log_error "Privileged restore credentials not provided"
        log_info "Set MYSQL_RESTORE_DEFAULTS_FILE or MYSQL_RESTORE_PASSWORD before running restore"
        return 1
    fi

    return 0
}

db_restore() {
    local backup_file="$1"
    local restore_user="${MYSQL_RESTORE_USER:-root}"

    db_load_config || return 1
    db_restore_credentials || return 1

    if [[ -n "${MYSQL_RESTORE_DEFAULTS_FILE:-}" ]]; then
        gunzip -c "$backup_file" 2>/dev/null | mysql --defaults-file="$MYSQL_RESTORE_DEFAULTS_FILE" 2>/dev/null
        return $?
    fi

    gunzip -c "$backup_file" 2>/dev/null \
        | MYSQL_PWD="$MYSQL_RESTORE_PASSWORD" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$restore_user" 2>/dev/null
}
