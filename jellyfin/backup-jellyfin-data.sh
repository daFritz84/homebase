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
## data/metadata (nfo + artwork cache, ~2.5 GB) and data/log are excluded
## too — a library scan rebuilds them; the archive stays ~80 MB so restic
## dedup keeps the offsite repo small.
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
ARCHIVE="${BACKUP_DIR}/jellyfin-data-$(date +%F-%H%M).tar"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (password hashes, API keys) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  # The media dirs (/srv/media/{filme,serien}) are CIFS automounts and are
  # NOT in the archive (data/ only). With the NAS offline the container's
  # /srv/media binds cannot mount, so the start fails — expected, NOT a
  # backup failure: the data/ archive is already written. Tolerate it and
  # tell the operator to start the service once the NAS is online.
  podman-compose up -d \
    || echo "[!] Service did not start (NAS media mounts offline?) — the backup is safe; once the NAS is online: systemctl --user start podman-compose@jellyfin"
}
trap restore_service EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] Archiving data/ -> ${ARCHIVE}"
# data/metadata (2.5 GB of nfo/artwork — rebuildable by a library scan) and
# data/log are EXCLUDED: the irreplaceable artifact is data/data (jellyfin.db:
# users, password hashes, API keys, watch state) + config + root.
tar cf "${ARCHIVE}" --exclude='data/metadata' --exclude='data/log' data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
