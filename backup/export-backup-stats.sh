#!/usr/bin/env bash
set -euo pipefail

## Backup textfile exporter — offsite-backup freshness + quota metrics for the
## node_exporter textfile collector (the fritzbox/truenas exporter pattern:
## same dir + atomic replace; the existing `node` scrape job picks it up —
## no new exporter, no new image, fully gitops).
##
## Written by run-weekly-backups.sh (both paths, via trap) and run-verify.sh —
## NOT on a fast timer: the quota PROPFIND hits the Storage Share over the
## WAN, and restic must never run per scrape (the repo size comes from the
## cache file the orchestrators refresh).
##
## Metrics (alerts: monitoring/vmalert/rules/backup.yml):
##   backup_last_success_timestamp_seconds{service="..."}  mtime of the newest
##       local archive per service — a failed service keeps its old mtime, so
##       BackupStale fires per service, not just per job.
##   backup_last_run_success 0|1 + backup_last_run_timestamp_seconds
##   backup_verify_last_success_timestamp_seconds (monthly prune + full check)
##   restic_repo_size_bytes  from the cached `restic stats --mode raw-data`
##       (PROPFIND folder size UNDERCOUNTS: Nextcloud file versions and the
##       trashbin are invisible to it — quota-used is the true signal)
##   nextcloud_quota_available_bytes / nextcloud_quota_used_bytes via PROPFIND
##       oc:quota-available-bytes (the only true quota signal) +
##       nextcloud_quota_info 1|0 (probe health; the quota rules require it).

cd "$(dirname "$(readlink -f "$0")")"

STATE_DIR="${HOME}/.local/share/backup"
TEXTFILE_DIR="${TEXTFILE_DIR:-${HOME}/.local/share/node-exporter/textfile}"
mkdir -p "${TEXTFILE_DIR}" "${STATE_DIR}"

if [ -f .env.secret ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.secret
  set +a
fi

# service dir : archive prefix (keep in sync with run-weekly-backups.sh)
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

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"
  prefix="${entry##*:}"
  newest="$(find "${HOME}/.local/share/${svc}/backups" -maxdepth 1 -name "${prefix}-*.tar" -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)"
  printf 'backup_last_success_timestamp_seconds{service="%s"} %s\n' "${svc}" "${newest:-0}" >> "${out}"
done

status=0
if [ -f "${STATE_DIR}/last-run-status" ]; then
  status="$(cat "${STATE_DIR}/last-run-status")"
fi
printf 'backup_last_run_success %s\n' "${status}" >> "${out}"

run_ts=0
if [ -f "${STATE_DIR}/last-run-timestamp" ]; then
  run_ts="$(cat "${STATE_DIR}/last-run-timestamp")"
fi
printf 'backup_last_run_timestamp_seconds %s\n' "${run_ts}" >> "${out}"

verify_ts=0
if [ -f "${STATE_DIR}/verify-last-success-timestamp" ]; then
  verify_ts="$(cat "${STATE_DIR}/verify-last-success-timestamp")"
fi
printf 'backup_verify_last_success_timestamp_seconds %s\n' "${verify_ts}" >> "${out}"

repo_size=0
if [ -f "${STATE_DIR}/repo-size" ]; then
  repo_size="$(cat "${STATE_DIR}/repo-size")"
fi
printf 'restic_repo_size_bytes %s\n' "${repo_size}" >> "${out}"

# --- quota via PROPFIND (oc:quota-available-bytes / oc:quota-used-bytes) ------
quota_avail=0
quota_used=0
quota_info=0
if [ -n "${NEXTCLOUD_WEBDAV_URL:-}" ] && [ -n "${NEXTCLOUD_APP_TOKEN:-}" ] && command -v curl >/dev/null; then
  xml="$(curl -fsS --max-time 30 -u "${NEXTCLOUD_USER}:${NEXTCLOUD_APP_TOKEN}" \
    -X PROPFIND -H 'Depth: 0' -H 'Content-Type: application/xml' \
    --data '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:quota-available-bytes/><oc:quota-used-bytes/></d:prop></d:propfind>' \
    "${NEXTCLOUD_WEBDAV_URL}" 2>/dev/null || true)"
  if [ -n "${xml}" ]; then
    parsed="$(printf '%s' "${xml}" | python3 -c '
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
vals = {}
for el in root.iter():
    tag = el.tag.split("}")[-1]
    if tag in ("quota-available-bytes", "quota-used-bytes") and (el.text or "").strip().lstrip("-").isdigit():
        vals[tag] = int(el.text.strip())
avail = vals.get("quota-available-bytes", -1)
used = vals.get("quota-used-bytes", -1)
# negative = unlimited/unknown quota (Storage Share reports a real number)
if avail >= 0 and used >= 0:
    print("%d %d 1" % (avail, used))
else:
    print("0 0 0")
' 2>/dev/null || true)"
    if [ -n "${parsed}" ]; then
      quota_avail="$(printf '%s' "${parsed}" | cut -d' ' -f1)"
      quota_used="$(printf '%s' "${parsed}" | cut -d' ' -f2)"
      quota_info="$(printf '%s' "${parsed}" | cut -d' ' -f3)"
    fi
  fi
fi
printf 'nextcloud_quota_available_bytes %s\n' "${quota_avail}" >> "${out}"
printf 'nextcloud_quota_used_bytes %s\n' "${quota_used}" >> "${out}"
printf 'nextcloud_quota_info %s\n' "${quota_info}" >> "${out}"

# Atomic replace (node_exporter reads the dir on each scrape).
mv -f "${out}" "${TEXTFILE_DIR}/backup.prom"
trap - EXIT
echo "[+] wrote ${TEXTFILE_DIR}/backup.prom ($(grep -c '^\(backup_\|restic_\|nextcloud_\)' "${TEXTFILE_DIR}/backup.prom") series)"
