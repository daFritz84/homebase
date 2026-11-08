#!/usr/bin/env bash
set -euo pipefail

## Back up Stirling PDF data (configs/ + storage/ + customFiles/ + pipeline/)
## to a timestamped tar.gz. data/configs is the irreplaceable,
## secret-bearing artifact: settings.yml, the built-in user DB, nightly DB
## backups and the generated keys live in it — losing it means a fresh
## instance (see docs/operations.md, "Stirling PDF data backups"). Run it
## right after admin/account setup and **before every image bump** (DB
## migrations are forward-only).
##
## data/logs is excluded: application logs are rebuildable.
##
## The service is stopped while archiving for a consistent snapshot (sqlite
## user DB) and is restarted afterwards, even if the archive fails.
##
## Run from the service checkout (the directory containing compose.yaml and
## data/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/stirling-pdf/backups"
ARCHIVE="${BACKUP_DIR}/stirling-pdf-data-$(date +%F-%H%M).tar.gz"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (user DB, generated keys) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  podman-compose up -d
}
trap restore_service EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] Archiving data/ (excluding data/logs) -> ${ARCHIVE}"
# podman unshare: the app (uid 1000) creates dirs mode 700 owned by
# container uid 1000 (= subuid 100999) — the host user cannot read them;
# namespace uid 0 has DAC override over the whole mapped range (navidrome
# pattern).
podman unshare tar czf "${ARCHIVE}" --exclude='data/logs' data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
