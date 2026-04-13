#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Account management module for VMANGOS Manager
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

ACCOUNT_CONFIG_LOADED=""
ACCOUNT_DB_HOST=""
ACCOUNT_DB_PORT=""
ACCOUNT_DB_USER=""
ACCOUNT_DB_PASS=""
ACCOUNT_AUTH_DB=""
ACCOUNT_PASSWORD_VALUE=""

account_load_config() {
    [[ "$ACCOUNT_CONFIG_LOADED" == "1" ]] && return 0

    config_load "$CONFIG_FILE" || {
        log_error "Failed to load configuration"
        return 1
    }

    ACCOUNT_DB_HOST="${CONFIG_DATABASE_HOST:-127.0.0.1}"
    ACCOUNT_DB_PORT="${CONFIG_DATABASE_PORT:-3306}"
    ACCOUNT_DB_USER="${CONFIG_DATABASE_USER:-mangos}"
    ACCOUNT_DB_PASS="${CONFIG_DATABASE_PASSWORD:-}"
    ACCOUNT_AUTH_DB="${CONFIG_DATABASE_AUTH_DB:-auth}"

    ACCOUNT_CONFIG_LOADED="1"
    return 0
}

account_normalize_value() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

validate_username() {
    local username="$1"
    [[ "$username" =~ ^[A-Za-z0-9]{2,32}$ ]]
}

validate_gm_level() {
    local level="$1"
    [[ "$level" =~ ^[0-3]$ ]]
}

validate_duration() {
    local duration="$1"
    [[ "$duration" =~ ^[1-9][0-9]*[smhdw]$ ]]
}

validate_ban_reason() {
    local reason="$1"
    [[ ${#reason} -ge 1 ]] && [[ ${#reason} -le 255 ]] && [[ "$reason" =~ ^[A-Za-z0-9]+([ ][A-Za-z0-9]+)*$ ]]
}

validate_password() {
    local password="$1"
    [[ ${#password} -ge 6 ]] && [[ ${#password} -le 32 ]]
}

account_get_current_uid() {
    id -u
}

account_get_sudo_uid() {
    printf '%s\n' "${SUDO_UID:-}"
}

account_get_file_owner_uid() {
    local file_path="$1"
    stat -c "%u" "$file_path" 2>/dev/null || stat -f "%u" "$file_path"
}

get_password_interactive() {
    local prompt="${1:-Password}"
    local password confirm

    if [[ ! -t 0 ]]; then
        log_error "Interactive password prompt requires a TTY"
        return 1
    fi

    read -r -s -p "$prompt: " password
    echo ""
    read -r -s -p "Confirm $prompt: " confirm
    echo ""

    if [[ "$password" != "$confirm" ]]; then
        log_error "Passwords do not match"
        return 1
    fi

    if ! validate_password "$password"; then
        log_error "Password must be between 6 and 32 characters"
        return 1
    fi

    printf '%s\n' "$password"
}

get_password_from_file() {
    local password_file="$1"
    local perms owner_uid current_uid sudo_uid password

    if [[ ! -f "$password_file" ]]; then
        log_error "Password file not found: $password_file"
        return 1
    fi

    owner_uid=$(account_get_file_owner_uid "$password_file") || {
        log_error "Unable to determine password file owner: $password_file"
        return 1
    }
    current_uid=$(account_get_current_uid)
    sudo_uid=$(account_get_sudo_uid)
    if [[ "$owner_uid" != "0" && "$owner_uid" != "$current_uid" && ( -z "$sudo_uid" || "$owner_uid" != "$sudo_uid" ) ]]; then
        log_error "Password file owner must be root, the current user, or the invoking sudo user"
        return 1
    fi

    perms=$(get_file_permissions "$password_file")
    if [[ "$perms" != "600" ]]; then
        log_error "Password file permissions must be 600"
        return 1
    fi

    IFS= read -r password < "$password_file" || true
    password="${password%$'\r'}"

    if ! validate_password "$password"; then
        log_error "Password in file must be between 6 and 32 characters"
        return 1
    fi

    printf '%s\n' "$password"
}

get_password_from_env() {
    local password="${VMANGOS_PASSWORD:-}"

    if [[ -z "$password" ]]; then
        log_error "VMANGOS_PASSWORD is not set"
        return 1
    fi

    if ! validate_password "$password"; then
        log_error "VMANGOS_PASSWORD must be between 6 and 32 characters"
        return 1
    fi

    unset VMANGOS_PASSWORD
    printf '%s\n' "$password"
}

account_acquire_password() {
    local mode="${1:-interactive}"
    local arg="${2:-}"

    case "$mode" in
        file)
            get_password_from_file "$arg"
            ;;
        env)
            get_password_from_env
            ;;
        interactive)
            get_password_interactive "$arg"
            ;;
        *)
            log_error "Unknown password mode: $mode"
            return 1
            ;;
    esac
}

account_resolve_password_value() {
    local mode="${1:-interactive}"
    local arg="${2:-}"
    local temp_file

    temp_file=$(mktemp_secure vmangos_account_password.XXXXXX)
    if ! account_acquire_password "$mode" "$arg" > "$temp_file"; then
        return 1
    fi

    IFS= read -r ACCOUNT_PASSWORD_VALUE < "$temp_file" || true
    ACCOUNT_PASSWORD_VALUE="${ACCOUNT_PASSWORD_VALUE%$'\r'}"
    return 0
}

hash_password() {
    local username="$1"
    local password="$2"
    local salt="${3:-}"

    if ! command -v python3 >/dev/null 2>&1; then
        log_error "python3 is required for password hashing"
        return 1
    fi

    printf '%s\n%s\n%s\n' "$username" "$password" "$salt" | python3 -c '
import hashlib
import os
import sys

N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
G = 7

parts = sys.stdin.read().splitlines()
username = parts[0].strip().upper()
password = parts[1].strip().upper()
salt = parts[2].strip().upper() if len(parts) > 2 else ""

if not salt:
    salt = os.urandom(32).hex().upper()

if len(salt) != 64:
    raise SystemExit(1)

password_hash = hashlib.sha1(f"{username}:{password}".encode("utf-8")).digest()
x_digest = hashlib.sha1(bytes.fromhex(salt)[::-1] + password_hash).digest()
x_value = int.from_bytes(x_digest[::-1], "big")
verifier = pow(G, x_value, N)
print(f"{salt}|{verifier:064X}")
'
}

duration_to_seconds() {
    local duration="$1"
    local value unit

    value="${duration%?}"
    unit="${duration: -1}"

    case "$unit" in
        s) printf '%s\n' "$value" ;;
        m) printf '%s\n' $((value * 60)) ;;
        h) printf '%s\n' $((value * 3600)) ;;
        d) printf '%s\n' $((value * 86400)) ;;
        w) printf '%s\n' $((value * 604800)) ;;
        *) return 1 ;;
    esac
}

account_mysql_query() {
    local database="$1"
    local query="$2"

    account_load_config || return 1

    if [[ -n "$ACCOUNT_DB_PASS" ]]; then
        mysql -h "$ACCOUNT_DB_HOST" -P "$ACCOUNT_DB_PORT" -u "$ACCOUNT_DB_USER" -p"$ACCOUNT_DB_PASS" -N -B -e "$query" "$database" 2>/dev/null
    else
        mysql -h "$ACCOUNT_DB_HOST" -P "$ACCOUNT_DB_PORT" -u "$ACCOUNT_DB_USER" -N -B -e "$query" "$database" 2>/dev/null
    fi
}

account_mysql_exec() {
    local database="$1"
    local query="$2"

    account_load_config || return 1

    if [[ -n "$ACCOUNT_DB_PASS" ]]; then
        mysql -h "$ACCOUNT_DB_HOST" -P "$ACCOUNT_DB_PORT" -u "$ACCOUNT_DB_USER" -p"$ACCOUNT_DB_PASS" -N -B -e "$query" "$database" >/dev/null 2>&1
    else
        mysql -h "$ACCOUNT_DB_HOST" -P "$ACCOUNT_DB_PORT" -u "$ACCOUNT_DB_USER" -N -B -e "$query" "$database" >/dev/null 2>&1
    fi
}

account_resolve_account_id() {
    local username="$1"
    account_load_config || return 1
    account_mysql_query "$ACCOUNT_AUTH_DB" "SELECT id FROM ${ACCOUNT_AUTH_DB}.account WHERE username = '${username}' LIMIT 1" | head -1
}

account_get_default_realm_id() {
    local realm_id
    account_load_config || return 1
    realm_id=$(account_mysql_query "$ACCOUNT_AUTH_DB" "SELECT COALESCE(MIN(id), 1) FROM ${ACCOUNT_AUTH_DB}.realmlist" | head -1 || true)
    if [[ "$realm_id" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$realm_id"
    else
        printf '1\n'
    fi
}

account_audit_log() {
    local action="$1"
    local target="$2"
    local details="${3:-}"
    local actor

    actor="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
    if [[ -n "$details" ]]; then
        log_info "AUDIT account.${action} actor=${actor} target=${target} ${details}"
    else
        log_info "AUDIT account.${action} actor=${actor} target=${target}"
    fi
}

account_emit_success() {
    local text_message="$1"
    local json_data="${2:-null}"

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "$json_data"
    else
        log_info "$text_message"
    fi
}

account_emit_error() {
    local code="$1"
    local message="$2"
    local suggestion="$3"

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output false "null" "$code" "$message" "$suggestion"
    else
        log_error "$message"
        [[ -n "$suggestion" ]] && log_info "$suggestion"
    fi
}

account_build_list_query() {
    local where_clause=""
    account_load_config || return 1
    if [[ "${1:-false}" == "true" ]]; then
        where_clause="WHERE a.online = 1"
    fi

    cat <<EOF
SELECT
  a.id,
  a.username,
  COALESCE(MAX(aa.gmlevel), a.gmlevel, 0) AS gmlevel,
  a.online,
  CASE
    WHEN MAX(CASE WHEN ab.active = 1 AND (ab.unbandate > UNIX_TIMESTAMP() OR ab.unbandate = ab.bandate) THEN 1 ELSE 0 END) = 1 THEN 1
    ELSE 0
  END AS banned
FROM ${ACCOUNT_AUTH_DB}.account a
LEFT JOIN ${ACCOUNT_AUTH_DB}.account_access aa ON aa.id = a.id
LEFT JOIN ${ACCOUNT_AUTH_DB}.account_banned ab ON ab.id = a.id
${where_clause}
GROUP BY a.id, a.username, a.gmlevel, a.online
ORDER BY a.id
EOF
}

account_list() {
    local online_only="${1:-false}"
    local query results

    account_load_config || {
        account_emit_error "CONFIG_ERROR" "Failed to load account configuration" "Check manager.conf and database settings"
        return 1
    }

    query=$(account_build_list_query "$online_only")
    results=$(account_mysql_query "$ACCOUNT_AUTH_DB" "$query") || {
        account_emit_error "DB_ERROR" "Failed to list accounts" "Check database connectivity and credentials"
        return 1
    }

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        local rows=()
        local id username gmlevel online banned escaped_username
        while IFS=$'\t' read -r id username gmlevel online banned; do
            [[ -n "${id:-}" ]] || continue
            escaped_username=$(json_escape "$username")
            rows+=("{\"id\":$id,\"username\":\"$escaped_username\",\"gm_level\":$gmlevel,\"online\":$( [[ "$online" == "1" ]] && echo true || echo false ),\"banned\":$( [[ "$banned" == "1" ]] && echo true || echo false )}")
        done <<< "$results"

        local joined=""
        if [[ ${#rows[@]} -gt 0 ]]; then
            joined=$(printf '%s,' "${rows[@]}")
            joined="[${joined%,}]"
        else
            joined="[]"
        fi

        json_output true "{\"accounts\":$joined}"
        return 0
    fi

    echo "Accounts:"
    printf '  %-6s %-32s %-8s %-8s %-8s\n' "ID" "USERNAME" "GM" "ONLINE" "BANNED"
    if [[ -z "$results" ]]; then
        echo "  No accounts found."
        return 0
    fi

    local id username gmlevel online banned
    while IFS=$'\t' read -r id username gmlevel online banned; do
        [[ -n "${id:-}" ]] || continue
        printf '  %-6s %-32s %-8s %-8s %-8s\n' \
            "$id" "$username" "$gmlevel" \
            "$( [[ "$online" == "1" ]] && echo yes || echo no )" \
            "$( [[ "$banned" == "1" ]] && echo yes || echo no )"
    done <<< "$results"
}

account_create() {
    local raw_username="$1"
    local password_mode="${2:-interactive}"
    local password_arg="${3:-}"
    local username password hash salt verifier account_id

    account_load_config || {
        account_emit_error "CONFIG_ERROR" "Failed to load account configuration" "Check manager.conf and database settings"
        return 1
    }

    username=$(account_normalize_value "$raw_username")
    if ! validate_username "$username"; then
        account_emit_error "INVALID_USERNAME" "Username must be alphanumeric and 2-32 characters" "Use only letters and numbers"
        return 1
    fi

    account_id=$(account_resolve_account_id "$username" || true)
    if [[ "$account_id" =~ ^[0-9]+$ ]] && [[ "$account_id" -gt 0 ]]; then
        account_emit_error "ACCOUNT_EXISTS" "Account already exists: $username" "Choose a different username"
        return 1
    fi

    account_resolve_password_value "$password_mode" "$password_arg" || return 1
    password="$ACCOUNT_PASSWORD_VALUE"
    password=$(account_normalize_value "$password")

    hash=$(hash_password "$username" "$password") || {
        account_emit_error "HASH_ERROR" "Failed to generate password verifier" "Check python3 availability"
        return 1
    }
    salt="${hash%%|*}"
    verifier="${hash##*|}"

    if ! account_mysql_exec "$ACCOUNT_AUTH_DB" "
INSERT INTO \`${ACCOUNT_AUTH_DB}\`.\`account\` (\`username\`, \`v\`, \`s\`, \`token_key\`, \`joindate\`) VALUES ('${username}', '${verifier}', '${salt}', '', NOW());
SET @account_id = LAST_INSERT_ID();
INSERT IGNORE INTO \`${ACCOUNT_AUTH_DB}\`.\`realmcharacters\` (\`realmid\`, \`acctid\`, \`numchars\`)
SELECT \`id\`, @account_id, 0
FROM \`${ACCOUNT_AUTH_DB}\`.\`realmlist\`;
"; then
        account_emit_error "DB_ERROR" "Failed to create account" "Check database connectivity and privileges"
        return 1
    fi

    account_id=$(account_resolve_account_id "$username" || true)
    account_audit_log "create" "$username" "id=${account_id:-unknown}"
    account_emit_success "Account created: $username" "{\"username\":\"$(json_escape "$username")\",\"id\":${account_id:-0}}"
}

account_setgm() {
    local raw_username="$1"
    local gm_level="$2"
    local username account_id

    account_load_config || {
        account_emit_error "CONFIG_ERROR" "Failed to load account configuration" "Check manager.conf and database settings"
        return 1
    }

    username=$(account_normalize_value "$raw_username")
    if ! validate_username "$username"; then
        account_emit_error "INVALID_USERNAME" "Username must be alphanumeric and 2-32 characters" "Use only letters and numbers"
        return 1
    fi

    if ! validate_gm_level "$gm_level"; then
        account_emit_error "INVALID_GM_LEVEL" "GM level must be between 0 and 3" "Use one of: 0, 1, 2, 3"
        return 1
    fi

    account_id=$(account_resolve_account_id "$username" || true)
    if [[ ! "$account_id" =~ ^[0-9]+$ ]] || [[ "$account_id" -eq 0 ]]; then
        account_emit_error "ACCOUNT_NOT_FOUND" "Account not found: $username" "Create the account first"
        return 1
    fi

    if [[ "$gm_level" == "0" ]]; then
        if ! account_mysql_exec "$ACCOUNT_AUTH_DB" "
UPDATE \`${ACCOUNT_AUTH_DB}\`.\`account\` SET \`gmlevel\` = 0 WHERE \`id\` = ${account_id};
DELETE FROM \`${ACCOUNT_AUTH_DB}\`.\`account_access\` WHERE \`id\` = ${account_id};
"; then
            account_emit_error "DB_ERROR" "Failed to clear GM level for $username" "Check database connectivity and privileges"
            return 1
        fi
    else
        if ! account_mysql_exec "$ACCOUNT_AUTH_DB" "
UPDATE \`${ACCOUNT_AUTH_DB}\`.\`account\` SET \`gmlevel\` = ${gm_level} WHERE \`id\` = ${account_id};
DELETE FROM \`${ACCOUNT_AUTH_DB}\`.\`account_access\` WHERE \`id\` = ${account_id};
INSERT INTO \`${ACCOUNT_AUTH_DB}\`.\`account_access\` (\`id\`, \`gmlevel\`, \`RealmID\`) VALUES (${account_id}, ${gm_level}, -1);
"; then
            account_emit_error "DB_ERROR" "Failed to set GM level for $username" "Check database connectivity and privileges"
            return 1
        fi
    fi

    account_audit_log "setgm" "$username" "id=${account_id} gm_level=${gm_level}"
    account_emit_success "GM level updated for $username: $gm_level" "{\"username\":\"$(json_escape "$username")\",\"id\":${account_id},\"gm_level\":${gm_level}}"
}

account_ban() {
    local raw_username="$1"
    local duration="$2"
    local reason="$3"
    local username account_id seconds realm_id actor

    account_load_config || {
        account_emit_error "CONFIG_ERROR" "Failed to load account configuration" "Check manager.conf and database settings"
        return 1
    }

    username=$(account_normalize_value "$raw_username")
    if ! validate_username "$username"; then
        account_emit_error "INVALID_USERNAME" "Username must be alphanumeric and 2-32 characters" "Use only letters and numbers"
        return 1
    fi

    if ! validate_duration "$duration"; then
        account_emit_error "INVALID_DURATION" "Duration must look like 1h, 7d, or 30m" "Use a positive integer followed by s, m, h, d, or w"
        return 1
    fi

    if ! validate_ban_reason "$reason"; then
        account_emit_error "INVALID_REASON" "Ban reason must use letters, numbers, and spaces only" "Avoid punctuation and special characters"
        return 1
    fi

    account_id=$(account_resolve_account_id "$username" || true)
    if [[ ! "$account_id" =~ ^[0-9]+$ ]] || [[ "$account_id" -eq 0 ]]; then
        account_emit_error "ACCOUNT_NOT_FOUND" "Account not found: $username" "Create the account first"
        return 1
    fi

    seconds=$(duration_to_seconds "$duration") || {
        account_emit_error "INVALID_DURATION" "Failed to parse duration: $duration" "Use a positive integer followed by s, m, h, d, or w"
        return 1
    }
    realm_id=$(account_get_default_realm_id)
    actor="${SUDO_USER:-$(id -un 2>/dev/null || echo manager)}"
    actor=$(printf '%s' "$actor" | tr -cd 'A-Za-z0-9 _-')
    [[ -n "$actor" ]] || actor="manager"

    if ! account_mysql_exec "$ACCOUNT_AUTH_DB" "
UPDATE \`${ACCOUNT_AUTH_DB}\`.\`account_banned\` SET \`active\` = 0 WHERE \`id\` = ${account_id};
INSERT INTO \`${ACCOUNT_AUTH_DB}\`.\`account_banned\` (\`id\`, \`bandate\`, \`unbandate\`, \`bannedby\`, \`banreason\`, \`active\`, \`realm\`)
VALUES (${account_id}, UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + ${seconds}, '${actor}', '${reason}', 1, ${realm_id});
"; then
        account_emit_error "DB_ERROR" "Failed to ban account: $username" "Check database connectivity and privileges"
        return 1
    fi

    account_audit_log "ban" "$username" "id=${account_id} duration=${duration} reason=${reason}"
    account_emit_success "Account banned: $username" "{\"username\":\"$(json_escape "$username")\",\"id\":${account_id},\"duration\":\"$(json_escape "$duration")\",\"reason\":\"$(json_escape "$reason")\"}"
}

account_unban() {
    local raw_username="$1"
    local username account_id

    account_load_config || {
        account_emit_error "CONFIG_ERROR" "Failed to load account configuration" "Check manager.conf and database settings"
        return 1
    }

    username=$(account_normalize_value "$raw_username")
    if ! validate_username "$username"; then
        account_emit_error "INVALID_USERNAME" "Username must be alphanumeric and 2-32 characters" "Use only letters and numbers"
        return 1
    fi

    account_id=$(account_resolve_account_id "$username" || true)
    if [[ ! "$account_id" =~ ^[0-9]+$ ]] || [[ "$account_id" -eq 0 ]]; then
        account_emit_error "ACCOUNT_NOT_FOUND" "Account not found: $username" "Create the account first"
        return 1
    fi

    if ! account_mysql_exec "$ACCOUNT_AUTH_DB" "UPDATE \`${ACCOUNT_AUTH_DB}\`.\`account_banned\` SET \`active\` = 0 WHERE \`id\` = ${account_id}"; then
        account_emit_error "DB_ERROR" "Failed to unban account: $username" "Check database connectivity and privileges"
        return 1
    fi

    account_audit_log "unban" "$username" "id=${account_id}"
    account_emit_success "Account unbanned: $username" "{\"username\":\"$(json_escape "$username")\",\"id\":${account_id}}"
}

account_password() {
    local raw_username="$1"
    local password_mode="${2:-interactive}"
    local password_arg="${3:-}"
    local username account_id password hash salt verifier

    account_load_config || {
        account_emit_error "CONFIG_ERROR" "Failed to load account configuration" "Check manager.conf and database settings"
        return 1
    }

    username=$(account_normalize_value "$raw_username")
    if ! validate_username "$username"; then
        account_emit_error "INVALID_USERNAME" "Username must be alphanumeric and 2-32 characters" "Use only letters and numbers"
        return 1
    fi

    account_id=$(account_resolve_account_id "$username" || true)
    if [[ ! "$account_id" =~ ^[0-9]+$ ]] || [[ "$account_id" -eq 0 ]]; then
        account_emit_error "ACCOUNT_NOT_FOUND" "Account not found: $username" "Create the account first"
        return 1
    fi

    account_resolve_password_value "$password_mode" "$password_arg" || return 1
    password="$ACCOUNT_PASSWORD_VALUE"
    password=$(account_normalize_value "$password")
    hash=$(hash_password "$username" "$password") || {
        account_emit_error "HASH_ERROR" "Failed to generate password verifier" "Check python3 availability"
        return 1
    }
    salt="${hash%%|*}"
    verifier="${hash##*|}"

    if ! account_mysql_exec "$ACCOUNT_AUTH_DB" "UPDATE \`${ACCOUNT_AUTH_DB}\`.\`account\` SET \`v\` = '${verifier}', \`s\` = '${salt}' WHERE \`id\` = ${account_id}"; then
        account_emit_error "DB_ERROR" "Failed to update password for $username" "Check database connectivity and privileges"
        return 1
    fi

    account_audit_log "password" "$username" "id=${account_id}"
    account_emit_success "Password updated for $username" "{\"username\":\"$(json_escape "$username")\",\"id\":${account_id}}"
}
