#!/usr/bin/env bash
set -euo pipefail

## Fritzbox UPnP textfile exporter — WAN metrics for the FRITZ!Box 7530
## (192.168.178.1) on the node_exporter textfile collector.
##
## Talks plain UPnP/IGD SOAP on :49000 (the same surface Homepage's `fritzbox`
## widget uses): NO credentials, NO TR-064 device user — verified working
## unauthenticated from the LAN 2026-11-15 (GetStatusInfo, GetExternalIPAddress,
## GetCommonLinkProperties, GetTotalBytesReceived/Sent all answered; the DSL
## actions return empty because this 7530 is an Ethernet WAN uplink, so no
## sync-rate/attenuation metrics exist on this line).
##
## Prereq (Fritzbox UI, Home Network -> Network -> Network Settings -> Access
## Settings in the Home Network): "Allow access for applications" + "Transmit
## status information over UPnP" — a firmware update can reset these toggles
## (docs/operations.md).
##
## Writes fritzbox.prom to node_exporter's textfile dir (same dir + atomic
## replace as export-podman-stats.sh); the existing `node` scrape job picks it
## up — no new exporter, no new image, fully gitops.
##
## Driven by systemd/user/fritzbox-stats-export.{service,timer} (every 60s —
## the Fritzbox web server throttles rapid SOAP). Run from anywhere; needs
## python3 (present on the server).

TEXTFILE_DIR="${TEXTFILE_DIR:-${HOME}/.local/share/node-exporter/textfile}"
FRITZBOX_URL="${FRITZBOX_URL:-http://192.168.178.1:49000}"
mkdir -p "${TEXTFILE_DIR}"

command -v python3 >/dev/null || { echo "[ERR] python3 not found"; exit 1; }

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

FRITZBOX_URL="${FRITZBOX_URL}" python3 > "${out}" <<'PY'
import os, re, sys, time
import urllib.request, urllib.error
import xml.etree.ElementTree as ET

BASE = os.environ['FRITZBOX_URL'].rstrip('/')

def soap(service, action, control):
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:%s xmlns:u="urn:schemas-upnp-org:service:%s"/></s:Body></s:Envelope>'
        % (action, service)
    )
    req = urllib.request.Request(
        BASE + control,
        data=body.encode(),
        headers={
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPACTION': '"urn:schemas-upnp-org:service:%s#%s"' % (service, action),
        },
        method='POST',
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        xml = r.read()
    root = ET.fromstring(xml)
    return {el.tag.split('}')[-1]: (el.text or '').strip() for el in root.iter() if el.tag.split('}')[-1].startswith('New')}

metrics = []
ok = 0

def add(name, value, labels=''):
    metrics.append('fritzbox_%s%s %s' % (name, ('{%s}' % labels) if labels else '', value))

try:
    st = soap('WANIPConnection:1', 'GetStatusInfo', '/igdupnp/control/WANIPConn1')
    add('wan_uptime_seconds', int(st.get('NewUptime', '0')))
    add('wan_connection_status', 1 if st.get('NewConnectionStatus') == 'Connected' else 0)
    add('wan_last_connection_error', 0, 'error="%s"' % st.get('NewLastConnectionError', 'UNKNOWN'))
    ok = 1

    ip = soap('WANIPConnection:1', 'GetExternalIPAddress', '/igdupnp/control/WANIPConn1')
    add('wan_external_ip_info', 1, 'ip="%s"' % ip.get('NewExternalIPAddress', ''))

    link = soap('WANCommonInterfaceConfig:1', 'GetCommonLinkProperties', '/igdupnp/control/WANCommonIFC1')
    add('wan_physical_link_up', 1 if link.get('NewPhysicalLinkStatus') == 'Up' else 0)
    add('wan_access_type_info', 1, 'type="%s"' % link.get('NewWANAccessType', ''))
    for k, m in (('NewLayer1DownstreamMaxBitRate', 'wan_layer1_downstream_max_bps'),
                 ('NewLayer1UpstreamMaxBitRate', 'wan_layer1_upstream_max_bps')):
        v = link.get(k, '')
        if v.isdigit():
            add(m, int(v))

    rx = soap('WANCommonInterfaceConfig:1', 'GetTotalBytesReceived', '/igdupnp/control/WANCommonIFC1')
    tx = soap('WANCommonInterfaceConfig:1', 'GetTotalBytesSent', '/igdupnp/control/WANCommonIFC1')
    add('wan_bytes_received_total', int(rx.get('NewTotalBytesReceived', '0')))
    add('wan_bytes_sent_total', int(tx.get('NewTotalBytesSent', '0')))
except Exception as e:
    print('[ERR] SOAP failed: %s' % e, file=sys.stderr)

add('exporter_last_scrape_timestamp', int(time.time()))
add('exporter_up', ok)
print('\n'.join(metrics))
PY

# Atomic replace (node_exporter reads the dir on each scrape).
mv -f "${out}" "${TEXTFILE_DIR}/fritzbox.prom"
trap - EXIT
echo "[+] wrote ${TEXTFILE_DIR}/fritzbox.prom ($(grep -c '^fritzbox_' "${TEXTFILE_DIR}/fritzbox.prom") series)"
