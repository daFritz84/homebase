#!/usr/bin/env bash
set -euo pipefail

## Back up wanderer data (PocketBase db, GPX uploads, Meili index) to a
## timestamped tar.gz. The trails are irreplaceable user data — run this
## regularly (see docs/operations.md, "Database backups").
##
## The stack is stopped while archiving for a consistent snapshot and is
## restarted afterwards, even if the archive fails.
##
## Run from the stack checkout (the directory containing compose.yaml and
## data/) — on the server that is the Komodo periphery checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/wanderer/backups"
ARCHIVE="${BACKUP_DIR}/wanderer-data-$(date +%F-%H%M).tar.gz"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the stack checkout"; exit 1; }

mkdir -p "${BACKUP_DIR}"

restore_stack() {
  echo "[*] Starting the stack"
  podman-compose up -d
}
trap restore_stack EXIT

echo "[*] Stopping the stack"
podman-compose down

echo "[*] Archiving data/ -> ${ARCHIVE}"
tar czf "${ARCHIVE}" data/

trap - EXIT
restore_stack

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
