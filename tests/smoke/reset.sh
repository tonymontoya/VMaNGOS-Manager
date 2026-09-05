#!/usr/bin/env bash
#
# reset.sh — tear down the smoke container and prepare for a fresh run.
#
# Removes the smoke container (and its ephemeral state: the installed manager,
# the venv, the install root, the secrets) but KEEPS the client-data cache on
# the host, so the next run re-mounts the same MPQ files and the long extraction
# / db-import work is reproducible without re-downloading anything.
#
# Usage:
#   tests/smoke/reset.sh [--container NAME] [--image NAME] [--keep-image]
#
set -euo pipefail

CONTAINER_NAME="${SMOKE_CONTAINER_NAME:-vmangos-wizard-smoke}"
IMAGE_NAME="${SMOKE_IMAGE_NAME:-vmangos-smoke-base}"
KEEP_IMAGE=0

log() { printf '[reset] %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)  CONTAINER_NAME="${2:-}"; shift 2 ;;
        --image)      IMAGE_NAME="${2:-}"; shift 2 ;;
        --keep-image) KEEP_IMAGE=1; shift ;;
        -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            log "unknown arg: $1"; exit 2 ;;
    esac
done

command -v docker >/dev/null 2>&1 || { log "docker is not on PATH"; exit 1; }

log "removing container $CONTAINER_NAME (if present)"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

if (( KEEP_IMAGE )); then
    log "--keep-image set: keeping $IMAGE_NAME"
else
    log "removing image $IMAGE_NAME (if present)"
    docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
fi

log "done. The client-data cache on the host is untouched; re-run wizard_smoke.sh for a fresh smoke."
