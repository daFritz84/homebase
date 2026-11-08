#!/usr/bin/env bash
set -euo pipefail

## Back up Jellyfin data (jellyfin.xml, users, password hashes, API keys,
## plugin DB) to a timestamped tar.gz. data/ is the irreplaceable,
## secret-bearing artifact: the admin user, password hashes, API keys and
## the VAAPI/transcoding settings live in it — losing it means a fresh
## instance (see docs/operations.md, "Jellyfin data backups"). Run it
## before every image bump (DB migrations are forward-only).
##
## cache/ (transcodes, artwork, plugin zips) is a sibling directory —
## excluded by construction: rebuildable and grows with the library.
##
## The service is stopped while archiving for a consistent snapshot and is
## restarted afterwards, even if the archive fails.
##
## No `podman unshare` needed: the image runs as root and rootless Podman
## maps container root to the host user, so data/ is host-user-owned
## (homeassistant pattern, unlike navidrome's uid-1000 dirs).
##
## Run from the service checkout (the directory containing compose.yaml and
## data/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/jellyfin/backups"
ARCHIVE="${BACKUP_DIR}/jellyfin-data-$(date +%F-%H%M).tar.gz"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (password hashes, API keys) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  podman-compose up -d
}
trap restore_service EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] Archiving data/ -> ${ARCHIVE}"
tar czf "${ARCHIVE}" data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
