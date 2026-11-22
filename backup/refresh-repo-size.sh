#!/usr/bin/env bash
set -euo pipefail

## Refresh the repo-size cache (~/.local/share/backup/repo-size) that
## export-backup-stats.sh reads for restic_repo_size_bytes. Shared by
## run-weekly-backups.sh and run-verify.sh — the `restic stats` flags live
## HERE only (restic 0.20 renamed raw-index -> raw-data and the fix had to
## be applied in both callers once; keep it single-sourced).
##
## Requires RESTIC_REPOSITORY/RESTIC_PASSWORD in the environment (callers
## source .env.secret) and restic on PATH (~/.local/bin).

cd "$(dirname "$(readlink -f "$0")")"

STATE_DIR="${HOME}/.local/share/backup"
mkdir -p "${STATE_DIR}"

restic stats --mode raw-data --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_size"])' \
  > "${STATE_DIR}/repo-size" \
  || { echo "[!] repo-size cache refresh FAILED" >&2; exit 1; }
