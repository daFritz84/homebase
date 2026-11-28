#!/usr/bin/env bash
set -euo pipefail

## Back up the Homepage runtime assets (config/images/ — the active wallpaper
## jpg is gitignored: a server-resident runtime asset, not GitOps state; the
## settings.yaml and the wallpaper.svg fallback stay in git).
##
## No service stop: config/images/ holds static files that Homepage reads at
## container start (image discovery) — a tar of a static jpg needs no quiesce,
## and stopping the dashboard for a wallpaper backup is a needless outage.
##
## Run from the service checkout (the directory containing compose.yaml) — on
## the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/homepage/backups"
ARCHIVE="${BACKUP_DIR}/homepage-data-$(date +%F-%H%M).tar"

[ -d config/images ] || { echo "[ERR] No config/images/ next to compose.yaml — run from the service checkout"; exit 1; }

mkdir -p "${BACKUP_DIR}"

echo "[*] Archiving config/images/ -> ${ARCHIVE}"
tar cf "${ARCHIVE}" config/images/

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
