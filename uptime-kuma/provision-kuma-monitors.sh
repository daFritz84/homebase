#!/usr/bin/env bash
set -euo pipefail

## Seed Uptime Kuma monitors directly into the SQLite DB. Kuma 2.x has NO REST
## API (the UI uses Socket.IO), and it caches monitors in memory, so the unit is
## STOPPED for the write and started after (clean WAL checkpoint). Idempotent:
## skips a monitor whose name already exists. The status page is left to the
## browser (Kuma 2.x links status pages via tags, not a hand-writable table).
##
## Run from the uptime-kuma directory on the server (needs the ./data:/app/data
## volume fix so ./data/kuma.db is the live DB).

cd "$(dirname "$(readlink -f "$0")")"

DB="./data/kuma.db"
[ -f "${DB}" ] || { echo "[ERR] ${DB} missing — apply the ./data:/app/data volume fix + migrate first"; exit 1; }

echo "[*] Stopping uptime-kuma (flush the in-memory monitor cache before the DB write)..."
systemctl --user stop podman-compose@uptime-kuma

python3 - "${DB}" <<'PY'
import sqlite3, sys
db = sys.argv[1]
c = sqlite3.connect(db)
row = c.execute("select id from user order by id limit 1").fetchone()
if not row:
    sys.exit("[ERR] no admin user in the DB — create the Kuma admin first")
admin = row[0]
# (name, type, url, port). The host check is TCP:22, NOT ping — rootless Podman
# cannot grant CAP_NET_RAW, so an ICMP ping monitor fails EPERM in the container.
monitors = [
    ("Authelia",         "http", "https://authelia.sseifried.link",   None),
    ("Homepage",         "http", "https://homepage.sseifried.link",   None),
    ("AdGuard",          "http", "https://adguard.sseifried.link",    None),
    ("Wanderer",         "http", "https://wanderer.sseifried.link",   None),
    ("Home Assistant",   "http", "https://homeassistant.sseifried.link", None),
    ("Navidrome",        "http", "https://navidrome.sseifried.link",  None),
    ("Jellyfin",         "http", "https://jellyfin.sseifried.link",   None),
    ("Stirling PDF",     "http", "https://stirling.sseifried.link",   None),
    ("BookOrbit",        "http", "https://bookorbit.sseifried.link",  None),
    ("Cockpit",          "http", "https://cockpit.sseifried.link",    None),
    ("Status (self)",    "http", "https://status.sseifried.link",     None),
    ("Metrics (self)",   "http", "https://metrics.sseifried.link",    None),
    ("Host",             "tcp",  "192.168.178.249",                   22),
]
added = 0
for name, mtype, url, port in monitors:
    if c.execute("select 1 from monitor where name=?", (name,)).fetchone():
        print("[*] exists:", name)
        continue
    c.execute(
        "insert into monitor (name, type, url, user_id, interval, active, port) values (?,?,?,?,60,1,?)",
        (name, mtype, url, admin, port))
    added += 1
    print("[+] add:", name)
# self-heal: the host check must be tcp:22 — rootless Podman has no CAP_NET_RAW,
# so a seeded ICMP ping row fails EPERM. Repair it in place.
c.execute("update monitor set type='tcp', port=22, url='192.168.178.249' where name='Host' and type!='tcp'")
if c.execute("select changes()").fetchone()[0]:
    print("[+] fixed Host monitor -> tcp:22 (rootless has no CAP_NET_RAW for ping)")
c.commit()
print("[+] %d added; total monitors now %d" % (added, c.execute("select count(*) from monitor").fetchone()[0]))
PY

echo "[*] Starting uptime-kuma..."
systemctl --user start podman-compose@uptime-kuma
echo "[✓] Monitors seeded. Browser: Settings -> Status Pages -> Add (slug 'homebase'),"
echo "    add the monitors -> that slug is HOMEPAGE_VAR_KUMA_SLUG."
