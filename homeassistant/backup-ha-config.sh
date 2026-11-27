#!/usr/bin/env bash
set -euo pipefail

## Back up the Home Assistant config/ (including .storage/ and secrets.yaml —
## the UI-managed state that is gitignored) to a timestamped tar.
## .storage/ holds integrations, dashboards, users and tokens — it is
## irreplaceable, run this after significant changes (see docs/operations.md,
## "Home Assistant config backups").
##
## The service is stopped while archiving for a consistent snapshot and is
## restarted afterwards, even if the archive fails.
##
## Stop/start go through the systemd unit (`systemctl --user stop/start
## podman-compose@homeassistant`) so the unit keeps owning the pod: a bare
## `podman-compose down` removes the containers the unit's `podman-compose
## wait` tracks and races it into a `failed` exit (observed 2026-11-22:
## rustdesk's 3-container pod -> exit 125 -> system degraded).
##
## Run from the service checkout (the directory containing compose.yaml and
## config/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/homeassistant/backups"
ARCHIVE="${BACKUP_DIR}/ha-config-$(date +%F-%H%M).tar"

[ -d config ] || { echo "[ERR] No config/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (.storage/ tokens, secrets.yaml) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  systemctl --user start podman-compose@homeassistant
}
trap restore_service EXIT

echo "[*] Stopping the service"
systemctl --user stop podman-compose@homeassistant

echo "[*] Archiving config/ -> ${ARCHIVE}"
tar cf "${ARCHIVE}" config/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
