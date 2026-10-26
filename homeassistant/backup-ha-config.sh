#!/usr/bin/env bash
set -euo pipefail

## Back up the Home Assistant config/ (including .storage/ and secrets.yaml —
## the UI-managed state that is gitignored) to a timestamped tar.gz.
## .storage/ holds integrations, dashboards, users and tokens — it is
## irreplaceable, run this after significant changes (see docs/operations.md,
## "Home Assistant config backups").
##
## The service is stopped while archiving for a consistent snapshot and is
## restarted afterwards, even if the archive fails.
##
## Run from the service checkout (the directory containing compose.yaml and
## config/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/homeassistant/backups"
ARCHIVE="${BACKUP_DIR}/ha-config-$(date +%F-%H%M).tar.gz"

[ -d config ] || { echo "[ERR] No config/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (.storage/ tokens, secrets.yaml) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  podman-compose up -d
}
trap restore_service EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] Archiving config/ -> ${ARCHIVE}"
tar czf "${ARCHIVE}" config/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
