#!/usr/bin/env bash
set -euo pipefail

## Back up Navidrome data (navidrome.db + covers) to a timestamped tar.gz.
## navidrome.db is the irreplaceable, secret-bearing artifact: users,
## playlists, share tokens and the auto-generated session/password secrets
## live in it — losing it means a fresh instance (see docs/operations.md,
## "Navidrome data backups"). Run it before every image bump (DB migrations
## are forward-only).
##
## data/cache is excluded: scan caches and transcoded audio are rebuildable
## and grow with the library.
##
## The service is stopped while archiving for a consistent SQLite snapshot and
## is restarted afterwards, even if the archive fails.
##
## Run from the service checkout (the directory containing compose.yaml and
## data/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/navidrome/backups"
ARCHIVE="${BACKUP_DIR}/navidrome-data-$(date +%F-%H%M).tar.gz"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  podman-compose up -d
}
trap restore_service EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] Archiving data/ (excluding data/cache) -> ${ARCHIVE}"
# podman unshare: the app creates dirs (data/plugins) mode 700 owned by
# container uid 1000 (= subuid 100999) — the host user cannot read them;
# namespace uid 0 has DAC override over the whole mapped range.
podman unshare tar czf "${ARCHIVE}" --exclude='data/cache' data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
