#!/usr/bin/env bash
set -euo pipefail

## Back up wanderer data (PocketBase db, GPX uploads) to a timestamped
## tar. The trails are irreplaceable user data — run this regularly (see
## docs/operations.md, "Wanderer data backups").
##
## data/data.ms is excluded: the Meili index is rebuildable from PocketBase
## (compose.yaml) and grows with the library — the offsite repo stays slim.
##
## The service is stopped while archiving for a consistent snapshot and is
## restarted afterwards, even if the archive fails.
##
## Run from the service checkout (the directory containing compose.yaml and
## data/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/wanderer/backups"
ARCHIVE="${BACKUP_DIR}/wanderer-data-$(date +%F-%H%M).tar"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  podman-compose up -d
}
trap restore_service EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] Archiving data/ (excluding data/data.ms) -> ${ARCHIVE}"
tar cf "${ARCHIVE}" --exclude='data/data.ms' data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
