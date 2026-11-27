#!/usr/bin/env bash
set -euo pipefail

## Back up the Grafana data (the sqlite DB) to a timestamped tar. ./data/grafana
## holds the admin prefs, service-account API keys (the Homepage grafana widget's
## key), folders and non-provisioned dashboards. Dashboards under
## monitoring/grafana/dashboards/ are in git (provisioned), so this archive is
## the irreplaceable part: the API keys + settings. Run right after setup and
## before every image bump.
##
## The service is stopped while archiving for a consistent sqlite snapshot and is
## restarted afterwards, even if the archive fails.
##
## Stop/start go through the systemd unit (`systemctl --user stop/start
## podman-compose@monitoring`) so the unit keeps owning the pod: a bare
## `podman-compose down` removes the containers the unit's `podman-compose
## wait` tracks and races it into a `failed` exit (observed 2026-11-22:
## rustdesk's 3-container pod -> exit 125 -> system degraded). `systemctl
## stop` is a no-op on a failed/inactive unit, so the script also
## `podman pod stop`s the pod (idempotent) and refuses to archive if any
## container is still up — guaranteeing a quiesced snapshot.
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
  systemctl --user start podman-compose@monitoring
}
trap restore_service EXIT

echo "[*] Stopping the service"
systemctl --user stop podman-compose@monitoring
# `systemctl stop` is a no-op on a failed/inactive unit (systemd skips
# ExecStop), leaving containers running -> a hot tar of a live DB. Stop the
# pod directly (idempotent) and refuse to archive if any container is up.
podman pod stop pod_monitoring >/dev/null 2>&1 || true
if [ -n "$(podman ps --filter name=^monitoring_ --format '{{.Names}}')" ]; then
  echo "[ERR] monitoring containers still running after stop — refusing to archive a live DB"
  exit 1
fi

echo "[*] Archiving data/grafana -> ${ARCHIVE}"
podman unshare tar cf "${ARCHIVE}" data/grafana/

trap - EXIT
restore_service

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
