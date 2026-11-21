#!/usr/bin/env bash
set -euo pipefail

## TrueNAS JSON-RPC textfile exporter — pool state + disk temperatures for the
## TrueNAS SCALE box (192.168.178.58) on the node_exporter textfile collector.
##
## The 25.x graphite stream (graphite-exporter, the system-metrics source)
## carries NO pool state and NO disk temps (the 25.x collectd graphite export
## loads no zfs-pool/smart plugins — verified against the live stream
## 2026-11-15). These two are the safety-critical signals, so they come from
## the supported JSON-RPC 2.0 over WebSocket API with the READONLY key
## (Bitwarden `truenas-api-key`, rendered to vm/secrets/truenas-api-key by
## provision-monitoring-secrets.sh):
##   wss://<host>/api/current  auth.login_with_api_key [key]
##   pool.query [[]]            -> [{name, status}]  (ONLINE)
##   disk.temperatures [[], false] -> {dev: celsius}
##
## NOT the deprecated REST API: TrueNAS 25.10 warns per-authentication about it
## and removes it in 26.04. JSON-RPC is WebSocket-only on 25.10.8 (HTTP POST to
## /api/current -> 405, probed 2026-11-21), and the server has no `websockets`
## python module, so the WS client below is stdlib-only (socket/ssl/struct/
## base64) — no new dependency, no new image, fully gitops. Params are
## positional ARRAYS (named params -> -32600). One connection + one login per
## run (the REST exporter authenticated twice per run).
##
## Writes truenas.prom to node_exporter's textfile dir (same atomic-replace
## pattern as export-fritzbox-stats.sh); the existing `node` scrape job picks
## it up. Metric names/labels are unchanged, so vmalert rules, the Grafana
## network dashboard and the homepage card need no changes.
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
import base64, json, os, socket, ssl, struct, sys, time, urllib.parse

URL = urllib.parse.urlparse(os.environ['TRUENAS_URL'])
HOST = URL.hostname
PORT = URL.port or (443 if URL.scheme == 'https' else 80)
TLS = URL.scheme != 'http'
KEY = open(os.environ['KEY_FILE']).read().strip()
PATH = '/api/current'
TIMEOUT = 15


class WS:
    """Minimal JSON-RPC 2.0-over-WebSocket client (stdlib only, RFC 6455)."""

    def __init__(self, host, port, path, tls):
        sock = socket.create_connection((host, port), TIMEOUT)
        if tls:
            ctx = ssl._create_unverified_context()  # self-signed middleware cert
            sock = ctx.wrap_socket(sock, server_hostname=host)
        self.sock = sock
        self.buf = b''
        self.id = 0
        handshake = base64.b64encode(os.urandom(16)).decode()
        sock.sendall(('GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n'
                      'Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n'
                      'Sec-WebSocket-Version: 13\r\n\r\n' % (path, host, handshake)).encode())
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = sock.recv(4096)
            if not chunk:
                raise RuntimeError('handshake: connection closed')
            head += chunk
        head, self.buf = head.split(b'\r\n\r\n', 1)
        status = head.split(b'\r\n', 1)[0].decode(errors='replace')
        if ' 101 ' not in status + ' ':
            raise RuntimeError('handshake: %s' % status)

    def _send(self, opcode, payload):
        frame = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            frame.append(0x80 | n)
        elif n < 0x10000:
            frame.append(0x80 | 126)
            frame += n.to_bytes(2, 'big')
        else:
            frame.append(0x80 | 127)
            frame += n.to_bytes(8, 'big')
        mask = os.urandom(4)
        frame += mask + bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        self.sock.sendall(bytes(frame))

    def _recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError('connection closed by server')
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def _recv_text(self):
        parts = b''
        while True:
            head = self._recv_exact(2)
            fin, opcode, length = head[0] & 0x80, head[0] & 0x0F, head[1] & 0x7F
            if head[1] & 0x80:
                raise RuntimeError('masked frame from server')
            if length == 126:
                length = struct.unpack('>H', self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack('>Q', self._recv_exact(8))[0]
            payload = self._recv_exact(length)
            if opcode == 0x9:
                self._send(0xA, payload)  # ping -> pong
                continue
            if opcode == 0x8:
                raise RuntimeError('close frame from server')
            parts += payload
            if fin:
                return parts.decode()

    def call(self, method, params):
        self.id += 1
        self._send(0x1, json.dumps({'jsonrpc': '2.0', 'id': self.id,
                                    'method': method, 'params': params}).encode())
        while True:
            msg = json.loads(self._recv_text())
            if msg.get('id') == self.id:  # skip notifications (no id)
                if 'error' in msg:
                    raise RuntimeError('%s: %s' % (method, msg['error'].get('message')))
                return msg.get('result')

    def close(self):
        try:
            self._send(0x8, b'')
        except Exception:
            pass
        self.sock.close()


metrics = []
ok = 0


def add(name, value, labels=''):
    metrics.append('truenas_%s%s %s' % (name, ('{%s}' % labels) if labels else '', value))


try:
    ws = WS(HOST, PORT, PATH, TLS)
except Exception as e:
    print('[ERR] websocket connect failed: %s' % e, file=sys.stderr)
    ws = None

if ws is not None:
    try:
        try:
            if ws.call('auth.login_with_api_key', [KEY]) is not True:
                raise RuntimeError('no session')
        except Exception as e:
            print('[ERR] auth failed: %s' % e, file=sys.stderr)
            raise
        try:
            for pool in ws.call('pool.query', [[]]) or []:
                add('pool_status', 1 if pool.get('status') == 'ONLINE' else 0,
                    'name="%s",state="%s"' % (pool.get('name', ''), pool.get('status', '')))
            ok = 1
        except Exception as e:
            print('[ERR] pool query failed: %s' % e, file=sys.stderr)
        try:
            for dev, temp in (ws.call('disk.temperatures', [[], False]) or {}).items():
                if isinstance(temp, (int, float)):
                    add('disk_temperature_celsius', float(temp), 'disk="%s"' % dev)
        except Exception as e:
            print('[ERR] disk temperatures query failed: %s' % e, file=sys.stderr)
    finally:
        ws.close()

add('exporter_last_scrape_timestamp', int(time.time()))
add('exporter_up', ok)
print('\n'.join(metrics))
PY

# Atomic replace (node_exporter reads the dir on each scrape).
mv -f "${out}" "${TEXTFILE_DIR}/truenas.prom"
trap - EXIT
echo "[+] wrote ${TEXTFILE_DIR}/truenas.prom ($(grep -c '^truenas_' "${TEXTFILE_DIR}/truenas.prom") series)"
