#!/usr/bin/env bash
set -euo pipefail

## podman-stats textfile exporter — the container-stats source (replaces
## podman-exporter, which is ghcr-only and the server's ghcr.io token endpoint is
## 403-blocked; podman's built-in metrics endpoint does not initialize on podman
## 5.4.2 — both probed 2026-11-15).
##
## Runs `podman stats --no-stream` + `podman ps -a` (rootless, as chef, reads
## chef's own engine) and writes Prometheus textfile metrics to node_exporter's
## textfile collector dir. node_exporter (a host process) then exposes
## podman_container_* on host.containers.internal:9100 — no external image, no
## ghcr, fully gitops (this script is in git).
##
## Driven by systemd/user/podman-stats-export.{service,timer} (every 15s).
## Run from anywhere; needs podman + python3 (both present on the server).

TEXTFILE_DIR="${TEXTFILE_DIR:-${HOME}/.local/share/node-exporter/textfile}"
mkdir -p "${TEXTFILE_DIR}"

command -v podman >/dev/null || { echo "[ERR] podman not found"; exit 1; }
command -v python3 >/dev/null || { echo "[ERR] python3 not found"; exit 1; }

stats_json="$(podman stats --no-stream --format json 2>/dev/null || echo '[]')"
ps_json="$(podman ps -a --format json 2>/dev/null || echo '[]')"

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

# podman 5.4.2 JSON keys (probed 2026-11-15): stats = name, cpu_percent,
# mem_usage, mem_percent (snake_case); ps -a = Names (list), State.
STATS_JSON="${stats_json}" PS_JSON="${ps_json}" python3 > "${out}" <<'PY'
import json, os, sys, re

def esc(name):
    return name.replace('\\', '\\\\').replace('"', '\\"')

def parse_bytes(s):
    # podman MemUsage: "28.87MB / 134.2MB" -> (used, limit) in bytes (1024-based)
    s = s.strip()
    if '/' in s:
        parts = s.split('/')
    else:
        parts = [s, '']
    units = {'B':1,'KB':1024,'KIB':1024,'MB':1024**2,'MIB':1024**2,
             'GB':1024**3,'GIB':1024**3,'TB':1024**4,'TIB':1024**4,'PB':1024**5,'PIB':1024**5}
    def one(t):
        t = t.strip()
        m = re.match(r'([0-9.]+)\s*([A-Za-z]+)', t)
        if not m:
            return None
        val = float(m.group(1)); unit = m.group(2).upper()
        return int(val * units.get(unit, 1))
    return one(parts[0]), (one(parts[1]) if len(parts) > 1 else None)

def pct(s):
    m = re.match(r'([0-9.]+)', s.strip())
    return float(m.group(1)) if m else 0.0

stats = json.loads(os.environ['STATS_JSON'])
ps = json.loads(os.environ['PS_JSON'])

by_name = {}
for c in ps:
    names = c.get('Names') or []
    name = names[0] if names else ''
    state = (c.get('State') or '').lower()
    by_name[name] = 1 if state == 'running' else 0

# running containers: emit up=1 + stats
for c in stats:
    name = c.get('name', '')
    n = esc(name)
    used, limit = parse_bytes(c.get('mem_usage', ''))
    print('podman_container_up{name="%s"} 1' % n)
    print('podman_container_cpu_percent{name="%s"} %g' % (n, pct(c.get('cpu_percent', ''))))
    print('podman_container_mem_percent{name="%s"} %g' % (n, pct(c.get('mem_percent', ''))))
    if used is not None:
        print('podman_container_mem_used_bytes{name="%s"} %d' % (n, used))
    if limit is not None:
        print('podman_container_mem_limit_bytes{name="%s"} %d' % (n, limit))
    by_name[name] = 1

# non-running containers (in ps, not in stats): emit up=0
for name, up in by_name.items():
    if up == 0:
        print('podman_container_up{name="%s"} 0' % esc(name))
PY

# Atomic replace (node_exporter reads the dir on each scrape).
mv -f "${out}" "${TEXTFILE_DIR}/podman.prom"
trap - EXIT
echo "[+] wrote ${TEXTFILE_DIR}/podman.prom ($(grep -c '^podman_container' "${TEXTFILE_DIR}/podman.prom") series)"
