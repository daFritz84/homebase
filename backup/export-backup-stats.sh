#!/usr/bin/env bash
set -euo pipefail

## Backup textfile exporter — offsite-backup freshness + quota metrics for the
## node_exporter textfile collector (the fritzbox/truenas exporter pattern:
## same dir + atomic replace; the existing `node` scrape job picks it up —
## no new exporter, no new image, fully gitops).
##
## Written by run-weekly-backups.sh (both paths, via trap) and run-verify.sh —
## NOT on a fast timer: the quota OCS probe hits the Storage Share over the
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
##   nextcloud_quota_available_bytes / nextcloud_quota_used_bytes via the
##       OCS endpoint /ocs/v2.php/cloud/user (WebDAV PROPFIND has NO quota
##       properties on Storage Share — 404 in propstat; unlimited quota
##       (-3 sentinel) => available -1, the quota rules require >= 0, so a
##       FINITE exhausted quota (free <= 0) fires Critical while unlimited
##       stays silent) + nextcloud_quota_info 1|0 (probe health; the quota
##       rules require it).

cd "$(dirname "$(readlink -f "$0")")"

STATE_DIR="${HOME}/.local/share/backup"
TEXTFILE_DIR="${TEXTFILE_DIR:-${HOME}/.local/share/node-exporter/textfile}"
mkdir -p "${TEXTFILE_DIR}" "${STATE_DIR}"

# SERVICES (service dir : archive prefix) — single source of truth, shared
# with run-weekly-backups.sh.
# shellcheck disable=SC1091
. ./backup.conf

if [ -f .env.secret ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.secret
  set +a
fi

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

# --- quota via the Nextcloud OCS endpoint ------------------------------------
# Storage Share exposes NO quota properties over WebDAV: PROPFIND of the DAV
# home returns oc:/nc:quota-* as 404 in propstat (observed 2026-11-22). The
# quota source is GET /ocs/v2.php/cloud/user (data.quota). Storage Share
# reports an UNLIMITED quota: free/total = -3 sentinel, used = account-wide
# bytes. Unlimited => quota_available_bytes -1 (the rules' >= 0 gate keeps
# them silent); a FINITE quota exhausted to free <= 0 emits the real value
# and fires NextcloudQuotaCritical — 0 would conflate the two.
quota_avail=-1
quota_used=0
quota_info=0
if [ -n "${NEXTCLOUD_WEBDAV_URL:-}" ] && [ -n "${NEXTCLOUD_APP_TOKEN:-}" ] && command -v curl >/dev/null; then
  ocs_host="${NEXTCLOUD_WEBDAV_URL%%/remote.php*}"
  # The credential goes in via curl's --config on STDIN: `-u user:token`
  # would be world-readable in /proc/<pid>/cmdline for the process lifetime.
  json="$(curl -fsS --max-time 30 --config - \
    -H 'OCS-APIRequest: true' -H 'Accept: application/json' \
    "${ocs_host}/ocs/v2.php/cloud/user?format=json" <<CURLCFG 2>/dev/null || true
user = "${NEXTCLOUD_USER}:${NEXTCLOUD_APP_TOKEN}"
CURLCFG
)"
  if [ -n "${json}" ]; then
    parsed="$(printf '%s' "${json}" | python3 -c '
import sys, json
d = json.load(sys.stdin)["ocs"]["data"]["quota"]
free = int(d.get("free", -1))
used = int(d.get("used", -1))
# -3/-1 = unlimited/unknown (Storage Share sentinel) -> -1; a finite quota
# keeps its real free (<= 0 when exhausted, so the Critical rule fires).
avail = free if free >= 0 else -1
print("%d %d 1" % (avail, used))
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
