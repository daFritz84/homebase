#!/usr/bin/env bash
set -euo pipefail

## Back up the Grafana data (the sqlite DB) to a timestamped tar.gz. ./data/grafana
## holds the admin prefs, service-account API keys (the Homepage grafana widget's
## key), folders and non-provisioned dashboards. Dashboards under
## monitoring/grafana/dashboards/ are in git (provisioned), so this archive is
## the irreplaceable part: the API keys + settings. Run right after setup and
## before every image bump.
##
## The service is stopped while archiving for a consistent sqlite snapshot and is
## restarted afterwards, even if the archive fails.
##
## Archives via `podman unshare tar cf` (navidrome/stirling pattern): the
## image runs as the grafana user (uid 472) and creates the runtime dirs
## data/grafana/{csv,png,pdf} owned by the mapped subuid, mode-restricted
## against the host user — a plain tar fails on them (observed 2026-11-22:
## "open failed: Keine Berechtigung"); namespace uid 0 has DAC override over
## the mapped range.
##
## Run from the service checkout (the directory containing compose.yaml and
## data/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/monitoring/backups"
ARCHIVE="${BACKUP_DIR}/grafana-data-$(date +%F-%H%M).tar"

[ -d data/grafana ] || { echo "[ERR] No data/grafana directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (API keys, admin prefs) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"

restore_service() {
  echo "[*] Starting the service"
  podman-compose up -d
}
trap restore_service EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] Archiving data/grafana -> ${ARCHIVE}"
podman unshare tar cf "${ARCHIVE}" data/grafana/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
