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
## Stop/start go through the systemd unit (`systemctl --user stop/start
## podman-compose@wanderer`) so the unit keeps owning the pod: a bare
## `podman-compose down` removes the containers the unit's `podman-compose
## wait` tracks and races it into a `failed` exit (observed 2026-11-22:
## rustdesk's 3-container pod -> exit 125 -> system degraded). `systemctl
## stop` is a no-op on a failed/inactive unit, so the script also
## `podman pod stop`s the pod (idempotent) and refuses to archive if any
## container is still up — guaranteeing a quiesced snapshot.
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
  systemctl --user start podman-compose@wanderer
}
trap restore_service EXIT

echo "[*] Stopping the service"
systemctl --user stop podman-compose@wanderer
# `systemctl stop` is a no-op on a failed/inactive unit (systemd skips
# ExecStop), leaving containers running -> a hot tar of a live DB. Stop the
# pod directly (idempotent) and refuse to archive if any container is up.
podman pod stop pod_wanderer >/dev/null 2>&1 || true
if [ -n "$(podman ps --filter name=^wanderer_ --format '{{.Names}}')" ]; then
  echo "[ERR] wanderer containers still running after stop — refusing to archive a live DB"
  exit 1
fi

echo "[*] Archiving data/ (excluding data/data.ms) -> ${ARCHIVE}"
tar cf "${ARCHIVE}" --exclude='data/data.ms' data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
