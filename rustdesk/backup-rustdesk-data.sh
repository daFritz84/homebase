#!/usr/bin/env bash
set -euo pipefail

## Back up rustdesk data to a timestamped tar. ./data is the irreplaceable,
## secret-bearing artifact: id_ed25519 (PRIVATE key) + id_ed25519.pub (the
## client-config key), db_v2.sqlite3 (client ID registry) and tailscale/
## (node-key state) — losing it means reconfiguring every client (keypair
## rotation) and re-registering IDs (see docs/operations.md, "RustDesk data
## backups"). Run it right after first start and **before every image bump**
## (sqlite migrations are forward-only).
##
## The service is stopped while archiving for a consistent SQLite snapshot and
## is restarted afterwards, even if the archive fails.
##
## The images run as root and rootless Podman maps container root to the host
## user, so ./data is host-user-owned — a plain tar reads it (no `podman
## unshare` needed, uptime-kuma/beszel pattern; ownership probed 2026-11-15,
## see docs/services.md).
##
## Run from the service checkout (the directory containing compose.yaml and
## data/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/rustdesk/backups"
ARCHIVE="${BACKUP_DIR}/rustdesk-data-$(date +%F-%H%M).tar"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains the server PRIVATE key + tailscale node key — owner-only.
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
tar cf "${ARCHIVE}" data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
