#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
OUTPUT_DIR="${1:-$SCRIPT_DIR}"

DASHBOARD_PYTHON="${DASHBOARD_PYTHON:-/opt/mangos/manager/.venv-dashboard/bin/python}"
DASHBOARD_APP="${DASHBOARD_APP:-$REPO_ROOT/manager/lib/dashboard.py}"
MANAGER_BIN="${MANAGER_BIN:-/opt/mangos/manager/bin/vmangos-manager}"
MANAGER_CONFIG="${MANAGER_CONFIG:-/opt/mangos/manager/config/manager.conf}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-2}"
THEME_NAME="${THEME_NAME:-dark}"
SCREEN_COLUMNS="${SCREEN_COLUMNS:-140}"
SCREEN_LINES="${SCREEN_LINES:-52}"

mkdir -p "$OUTPUT_DIR"

SNAPSHOT_FILE="$OUTPUT_DIR/dashboard-demo-snapshot.json"
python3 "$SCRIPT_DIR/generate_dashboard_demo.py" --output "$SNAPSHOT_FILE"

for view_name in overview monitor accounts backups config logs operations; do
    COLUMNS="$SCREEN_COLUMNS" LINES="$SCREEN_LINES" \
    "$DASHBOARD_PYTHON" "$DASHBOARD_APP" \
        --manager-bin "$MANAGER_BIN" \
        --config "$MANAGER_CONFIG" \
        --snapshot-file "$SNAPSHOT_FILE" \
        --refresh "$REFRESH_INTERVAL" \
        --theme "$THEME_NAME" \
        --view "$view_name" \
        --screenshot "$OUTPUT_DIR/dashboard-$view_name.svg"
done
