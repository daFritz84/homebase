#!/usr/bin/env bash
set -euo pipefail

## Back up the Beszel hub data (the PocketBase SQLite DB) to a timestamped
## tar.gz. ./data is the irreplaceable artifact: users, systems, alerts and API
## keys live in it (see docs/operations.md, "Beszel data backups"). Run it right
## after setup and **before every image bump** (DB migrations are forward-only).
## The agent is stateless (its KEY/TOKEN live in beszel/agent.env).
##
## The hub runs as root and rootless Podman maps container root to the host user,
## so ./data is host-user-owned — a plain tar reads it (no `podman unshare`
## needed, jellyfin/homeassistant pattern).
##
## The service is stopped while archiving for a consistent SQLite snapshot and is
## restarted afterwards, even if the archive fails.
##
## Run from the service checkout (the directory containing compose.yaml and
## data/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/beszel/backups"
ARCHIVE="${BACKUP_DIR}/beszel-data-$(date +%F-%H%M).tar.gz"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains the hub DB (users, API keys) — owner-only.
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
