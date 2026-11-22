#!/usr/bin/env bash
set -euo pipefail

## Monthly offsite repo maintenance — the orchestrator behind
## systemd/user/backup-verify.{service,timer} (1st ~04:15, Persistent=true).
##
##   1. restic prune — the ONLY destructive remote op (deletes expired
##      snapshots' pack data; WebDAV DELETE lands in the Nextcloud trashbin,
##      whose retention is set to 7 d in the Storage Share web UI —
##      docs/operations.md, "Backups"). Runs monthly, not weekly: every prune
##      rewrites the index and deletes packs, each creating a file version +
##      trashbin entry, so weekly would multiply the quota churn 4x.
##   2. restic check --read-data — reads the WHOLE repo (trivial at MB-scale):
##      integrity proof immediately after the destructive op, catching
##      quota/versioning corruption.
##   3. refresh the repo-size cache + the verify timestamp (exporter inputs).
##
## Run from anywhere (the systemd unit runs it from %h/src/homebase/backup).

cd "$(dirname "$(readlink -f "$0")")"

# shellcheck disable=SC1091
. ./backup.conf
[ -f .env.secret ] || { echo "[ERR] .env.secret missing — run ./provision-backup-secrets.sh"; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env.secret
set +a

STATE_DIR="${HOME}/.local/share/backup"
mkdir -p "${STATE_DIR}"

echo "[*] Monthly verify started $(date -Is)"

echo "[*] restic prune"
restic prune

echo "[*] restic check --read-data (full repo read)"
restic check --read-data

restic stats --mode raw-index --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_size"])' \
  > "${STATE_DIR}/repo-size" || echo "[!] repo-size cache refresh FAILED" >&2
printf '%s\n' "$(date +%s)" > "${STATE_DIR}/verify-last-success-timestamp"

./export-backup-stats.sh || echo "[!] export-backup-stats.sh failed (backup.prom not refreshed)" >&2

echo
echo "[✓] Monthly verify complete $(date -Is)"
