#!/usr/bin/env bash
#
# Convenience installer for VMANGOS Manager from a source checkout.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="/opt/mangos/manager"
DESTDIR=""
RUN_TESTS=false

usage() {
    cat <<'EOF'
Usage: install_manager.sh [--prefix PATH] [--destdir PATH] [--run-tests]

Options:
  --prefix PATH   Installation prefix (default: /opt/mangos/manager)
  --destdir PATH  Staging root for packaging/tests
  --run-tests     Run `make test` before installation
  -h, --help      Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            PREFIX="${2:-}"
            shift 2
            ;;
        --destdir)
            DESTDIR="${2:-}"
            shift 2
            ;;
        --run-tests)
            RUN_TESTS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$PREFIX" ]]; then
    echo "Error: --prefix requires a path" >&2
    exit 2
fi

if [[ "$RUN_TESTS" == "true" ]]; then
    make -C "$SCRIPT_DIR" test
fi

make -C "$SCRIPT_DIR" install DESTDIR="$DESTDIR" PREFIX="$PREFIX"
