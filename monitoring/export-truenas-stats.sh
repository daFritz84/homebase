#!/usr/bin/env bash
set -euo pipefail

## TrueNAS REST textfile exporter — pool state + disk temperatures for the
## TrueNAS SCALE box (192.168.178.58) on the node_exporter textfile collector.
##
## The 25.x graphite stream (graphite-exporter, the system-metrics source)
## carries NO pool state and NO disk temps (the 25.x collectd graphite export
## loads no zfs-pool/smart plugins — verified against the live stream
## 2026-11-15). These two are the safety-critical signals, so they come from
## the REST v2.0 compat API with the READONLY key (Bitwarden
## `truenas-api-key`, rendered to vm/secrets/truenas-api-key by
## provision-monitoring-secrets.sh):
##   GET  /api/v2.0/pool              -> [{name, status}]  (ONLINE)
##   POST /api/v2.0/disk/temperatures -> {dev: celsius}    (GET is 405)
##
## Writes truenas.prom to node_exporter's textfile dir (same atomic-replace
## pattern as export-fritzbox-stats.sh); the existing `node` scrape job picks
## it up — no new exporter, no new image, fully gitops.
##
## Driven by systemd/user/truenas-stats-export.{service,timer} (every 60s).
## Run from anywhere; needs python3 (present on the server).

TEXTFILE_DIR="${TEXTFILE_DIR:-${HOME}/.local/share/node-exporter/textfile}"
TRUENAS_URL="${TRUENAS_URL:-https://192.168.178.58}"
KEY_FILE="${KEY_FILE:-${HOME}/src/homebase/monitoring/vm/secrets/truenas-api-key}"
mkdir -p "${TEXTFILE_DIR}"

command -v python3 >/dev/null || { echo "[ERR] python3 not found"; exit 1; }
[ -r "${KEY_FILE}" ] || { echo "[ERR] cannot read ${KEY_FILE} (run provision-monitoring-secrets.sh)"; exit 1; }

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

TRUENAS_URL="${TRUENAS_URL}" KEY_FILE="${KEY_FILE}" python3 > "${out}" <<'PY'
import json, os, ssl, sys, time
import urllib.request

BASE = os.environ['TRUENAS_URL'].rstrip('/')
KEY = open(os.environ['KEY_FILE']).read().strip()
CTX = ssl._create_unverified_context()  # self-signed middleware cert

def api(path, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={'Authorization': 'Bearer ' + KEY,
                 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15, context=CTX) as r:
        return json.loads(r.read())

metrics = []
ok = 0

def add(name, value, labels=''):
    metrics.append('truenas_%s%s %s' % (name, ('{%s}' % labels) if labels else '', value))

try:
    for pool in api('/api/v2.0/pool'):
        add('pool_status', 1 if pool.get('status') == 'ONLINE' else 0,
            'name="%s",state="%s"' % (pool.get('name', ''), pool.get('status', '')))
    ok = 1
except Exception as e:
    print('[ERR] pool query failed: %s' % e, file=sys.stderr)

try:
    for dev, temp in api('/api/v2.0/disk/temperatures', method='POST', body={}).items():
        if isinstance(temp, (int, float)):
            add('disk_temperature_celsius', float(temp), 'disk="%s"' % dev)
except Exception as e:
    print('[ERR] disk temperatures query failed: %s' % e, file=sys.stderr)

add('exporter_last_scrape_timestamp', int(time.time()))
add('exporter_up', ok)
print('\n'.join(metrics))
PY

# Atomic replace (node_exporter reads the dir on each scrape).
mv -f "${out}" "${TEXTFILE_DIR}/truenas.prom"
trap - EXIT
echo "[+] wrote ${TEXTFILE_DIR}/truenas.prom ($(grep -c '^truenas_' "${TEXTFILE_DIR}/truenas.prom") series)"
