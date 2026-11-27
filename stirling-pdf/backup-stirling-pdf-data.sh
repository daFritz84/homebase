#!/usr/bin/env bash
set -euo pipefail

## Back up Stirling PDF data (configs/ + storage/ + customFiles/ + pipeline/)
## to a timestamped tar. data/configs is the irreplaceable,
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
## Stop/start go through the systemd unit (`systemctl --user stop/start
## podman-compose@stirling-pdf`) so the unit keeps owning the pod: a bare
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

BACKUP_DIR="${HOME}/.local/share/stirling-pdf/backups"
ARCHIVE="${BACKUP_DIR}/stirling-pdf-data-$(date +%F-%H%M).tar"

[ -d data ] || { echo "[ERR] No data/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (user DB, generated keys) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  systemctl --user start podman-compose@stirling-pdf
}
trap restore_service EXIT

echo "[*] Stopping the service"
systemctl --user stop podman-compose@stirling-pdf
# `systemctl stop` is a no-op on a failed/inactive unit (systemd skips
# ExecStop), leaving containers running -> a hot tar of a live DB. Stop the
# pod directly (idempotent) and refuse to archive if any container is up.
podman pod stop pod_stirling-pdf >/dev/null 2>&1 || true
if [ -n "$(podman ps --filter name=^stirling-pdf_ --format '{{.Names}}')" ]; then
  echo "[ERR] stirling-pdf containers still running after stop — refusing to archive a live DB"
  exit 1
fi

echo "[*] Archiving data/ (excluding data/logs) -> ${ARCHIVE}"
# podman unshare: the app (uid 1000) creates dirs mode 700 owned by
# container uid 1000 (= subuid 100999) — the host user cannot read them;
# namespace uid 0 has DAC override over the whole mapped range (navidrome
# pattern).
podman unshare tar cf "${ARCHIVE}" --exclude='data/logs' data/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
