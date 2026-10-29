#!/usr/bin/env bash
# shellcheck source=lib/common.sh
#
# Install-layout guards.
#
# Both of these mistakes are one typo away on a real host, and both destroy a
# working installation without ever asking:
#
#   1. Installing the *manager* into a realm root (`PREFIX=/opt/mangos`). The
#      manager writes its own Makefile, VERSION and build-info into its prefix,
#      and a realm root has a Makefile of its own. The old one is gone before
#      the command finishes.
#   2. Installing a *realm* inside the manager's prefix (a root of
#      `/opt/mangos/manager`, or anything under it). The documented layout is
#      the opposite — realm at /opt/mangos, manager at /opt/mangos/manager —
#      and inverting it means a manager update or uninstall reaches into the
#      realm tree, and `config detect` can no longer tell the two apart.
#
# Neither guard is about permissions: an operator with the rights to do either
# is exactly the operator who will.
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Things that only exist once a VMaNGOS realm has been installed at a root.
INSTALL_GUARD_REALM_MARKERS=(
    bin/mangosd
    bin/realmd
    run/etc/mangosd.conf
    run/etc/realmd.conf
    .install-checkpoints
)

install_guard_is_realm_root() {
    local root="${1:-}"
    local marker

    [[ -n "$root" ]] || return 1
    for marker in "${INSTALL_GUARD_REALM_MARKERS[@]}"; do
        if [[ -e "$root/$marker" ]]; then
            return 0
        fi
    done
    return 1
}

# Absolute, symlink-free form of a path, for comparison only. Paths that do not
# exist yet are normal here (an install root is usually about to be created),
# so the parent is resolved and the remainder re-attached.
install_guard_normalize() {
    local path="${1:-}"
    local parent leaf

    [[ -n "$path" ]] || return 1
    [[ "$path" == /* ]] || return 1
    if parent=$(realpath -- "$path" 2>/dev/null); then
        printf '%s' "$parent"
        return 0
    fi
    parent=$(realpath -- "$(dirname "$path")" 2>/dev/null) || return 1
    leaf=$(basename -- "$path")
    [[ "$parent" == "/" ]] && printf '/%s' "$leaf" || printf '%s/%s' "$parent" "$leaf"
    return 0
}

# True when the candidate is the parent directory or lives somewhere inside it.
install_guard_is_inside() {
    local candidate parent

    candidate=$(install_guard_normalize "${1:-}") || return 1
    parent=$(install_guard_normalize "${2:-}") || return 1
    [[ -n "$candidate" && -n "$parent" ]] || return 1
    [[ "$candidate" == "$parent" || "$candidate" == "$parent"/* ]]
}

# Guard 1: the manager's own prefix must not be a realm install.
install_guard_refuse_realm_prefix() {
    local root="${1:-}"

    if [[ -z "$root" ]]; then
        log_error "Install guard: no installation prefix was given."
        return 1
    fi
    if install_guard_is_realm_root "$root"; then
        log_error "Refusing to install the manager into $root: that directory is a VMaNGOS realm install."
        log_error "The manager writes its own Makefile, VERSION and build-info into its prefix, which would replace files belonging to the realm."
        log_error "Install the manager inside the realm root instead, for example: PREFIX=$root/manager"
        return 1
    fi
    return 0
}

# Guard 2: a realm install root must not be the manager's prefix or live
# inside it. An empty prefix argument means the caller cannot say where the
# manager lives (a sourced library with no CLI around), so there is nothing to
# compare against and the guard stays out of the way.
install_guard_refuse_root_inside_manager() {
    local root="${1:-}"
    local manager_prefix="${2:-${MANAGER_ROOT:-}}"

    [[ -n "$manager_prefix" ]] || return 0
    [[ -n "$root" ]] || return 0
    if [[ "$root" != /* ]]; then
        # A relative root would be resolved against the install unit's working
        # directory, which is not where the operator typed it.
        log_error "Install root must be an absolute path: $root"
        return 1
    fi
    if install_guard_is_inside "$root" "$manager_prefix"; then
        log_error "Refusing to install a realm at $root: it is the manager's own prefix, or inside it."
        log_error "A later manager update or uninstall would touch the realm tree, and the two installs could no longer be told apart."
        log_error "Install the realm at a root that contains the manager instead, for example: INSTALLROOT=$(dirname "$manager_prefix")"
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        check-manager-prefix)
            shift
            install_guard_refuse_realm_prefix "${1:-}"
            ;;
        check-realm-root)
            shift
            install_guard_refuse_root_inside_manager "${1:-}" "${2:-}"
            ;;
        *)
            printf 'usage: install_guard.sh check-manager-prefix PATH | check-realm-root PATH MANAGER_PREFIX\n' >&2
            exit 2
            ;;
    esac
fi
