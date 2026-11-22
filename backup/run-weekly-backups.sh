#!/usr/bin/env bash
set -euo pipefail

## Weekly offsite backup run — the orchestrator behind
## systemd/user/backup-all.{service,timer} (Sun ~03:15, Persistent=true).
##
## Pipeline (docs/operations.md, "Backups" — retention contract + cleanup
## strategy live there):
##   1. run every service's backup-*.sh (each stops its service, archives,
##      restarts); a failure is recorded, the rest continue, exit non-zero;
##   2. restic backup of the local archive dirs (encrypted, deduplicated,
##      incremental -> Hetzner Storage Share over WebDAV);
##   3. restic check (metadata + cache);
##   4. local prune ONLY if 2+3 succeeded (the local safety net must never
##      shrink exactly when the offsite upload failed);
##   5. restic forget $RESTIC_KEEP_FLAGS — metadata-only, NO --prune here:
##      prune is the only destructive remote op and runs monthly in
##      backup-verify.{service,timer}, right before restic check --read-data;
##   6. cache the repo size (restic stats) for export-backup-stats.sh;
##   7. write backup.prom on BOTH paths (trap) — the quota/staleness alerts
##      need the failure signal.
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

REPO_ROOT="$(cd .. && pwd)"
STATE_DIR="${HOME}/.local/share/backup"
mkdir -p "${STATE_DIR}"

# service dir : archive prefix (the prefix is what the local prune matches)
SERVICES=(
  "authelia:authelia"
  "wanderer:wanderer-data"
  "navidrome:navidrome-data"
  "jellyfin:jellyfin-data"
  "stirling-pdf:stirling-pdf-data"
  "bookorbit:bookorbit-data"
  "homeassistant:ha-config"
  "rustdesk:rustdesk-data"
  "monitoring:grafana-data"
)

# The exporter reads these state files; the trap writes backup.prom on both
# the success and the failure path.
write_prom() {
  printf '%s\n' "${RUN_OK}" > "${STATE_DIR}/last-run-status"
  printf '%s\n' "$(date +%s)" > "${STATE_DIR}/last-run-timestamp"
  ./export-backup-stats.sh || echo "[!] export-backup-stats.sh failed (backup.prom not refreshed)" >&2
}
RUN_OK=0
trap write_prom EXIT

echo "[*] Weekly backup run started $(date -Is)"

# --- 1. service archives -----------------------------------------------------
FAILED=""
for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"
  script="$(find "${REPO_ROOT}/${svc}" -maxdepth 1 -name 'backup-*.sh' -print -quit)"
  [ -n "${script}" ] || { echo "[ERR] no backup-*.sh in ${svc}/"; FAILED="${FAILED} ${svc}"; continue; }
  echo "[*] ${svc}: $(basename "${script}")"
  if ! (cd "${REPO_ROOT}/${svc}" && "./$(basename "${script}")"); then
    echo "[!] ${svc}: backup script FAILED (continuing with the rest)" >&2
    FAILED="${FAILED} ${svc}"
  fi
done

# --- 2. restic backup ---------------------------------------------------------
BACKUP_DIRS=()
for entry in "${SERVICES[@]}"; do
  d="${HOME}/.local/share/${entry%%:*}/backups"
  if [ -d "${d}" ]; then
    BACKUP_DIRS+=("${d}")
  fi
done
[ "${#BACKUP_DIRS[@]}" -gt 0 ] || { echo "[ERR] no local backup dirs to upload"; exit 1; }

UPLOAD_OK=0
CHECK_OK=0
echo "[*] restic backup (${#BACKUP_DIRS[@]} archive dirs)"
if restic backup "${BACKUP_DIRS[@]}"; then
  UPLOAD_OK=1
else
  echo "[!] restic backup FAILED (offsite unreachable? token expired? quota full?)" >&2
fi

# --- 3. restic check ----------------------------------------------------------
if [ "${UPLOAD_OK}" = 1 ]; then
  echo "[*] restic check"
  if restic check; then
    CHECK_OK=1
  else
    echo "[!] restic check FAILED — repo integrity suspect" >&2
  fi
fi

# --- 4. local prune (ONLY after a verified upload — data-loss guard) ----------
if [ "${UPLOAD_OK}" = 1 ] && [ "${CHECK_OK}" = 1 ]; then
  for entry in "${SERVICES[@]}"; do
    svc="${entry%%:*}"
    prefix="${entry##*:}"
    d="${HOME}/.local/share/${svc}/backups"
    [ -d "${d}" ] || continue
    mapfile -t archives < <(find "${d}" -maxdepth 1 -name "${prefix}-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ "${#archives[@]}" -le "${LOCAL_KEEP}" ]; then
      continue
    fi
    for a in "${archives[@]:${LOCAL_KEEP}}"; do
      echo "[*] local prune: ${a}"
      rm -f -- "${a}"
    done
  done
else
  echo "[*] local prune SKIPPED (upload/check not verified — keeping all local archives)"
fi

# --- 5. restic forget (metadata-only; prune lives in the monthly verify) ------
if [ "${CHECK_OK}" = 1 ]; then
  read -ra KEEP_ARR <<< "${RESTIC_KEEP_FLAGS}"
  echo "[*] restic forget ${RESTIC_KEEP_FLAGS}"
  restic forget "${KEEP_ARR[@]}" || echo "[!] restic forget FAILED (retention not applied this run)" >&2
fi

# --- 6. repo size cache (exporter reads it; never run restic per scrape) ------
if [ "${CHECK_OK}" = 1 ]; then
  restic stats --mode raw-index --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_size"])' \
    > "${STATE_DIR}/repo-size" || echo "[!] repo-size cache refresh FAILED" >&2
fi

# --- result -------------------------------------------------------------------
if [ -z "${FAILED}" ] && [ "${UPLOAD_OK}" = 1 ] && [ "${CHECK_OK}" = 1 ]; then
  RUN_OK=1
  echo
  echo "[✓] Weekly backup run complete $(date -Is)"
  restic snapshots --last 3 || true
  exit 0
fi

echo
echo "[ERR] Weekly backup run INCOMPLETE: failed:${FAILED} upload:${UPLOAD_OK} check:${CHECK_OK}" >&2
exit 1
