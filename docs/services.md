# Core Services

Each core service runs from its own `compose.yaml` via `podman-compose` and is managed as a user
systemd unit. Prerequisites (Podman, firewalld, unprivileged ports, linger) are covered in
[host-setup.md](host-setup.md).

- [Autostart: podman-compose systemd units (shared pattern)](#autostart-podman-compose-systemd-units-shared-pattern)
- [Development workflow](#development-workflow)
- [Caddy](#caddy)
- [Cockpit](#cockpit)
- [AdGuard Home (DNS-Server)](#adguard-home-dns-server)
- [Wanderer (Trail Database)](#wanderer-trail-database)
- [Home Assistant (Home Automation)](#home-assistant-home-automation)

For the stack update procedure and backups see [operations.md](operations.md).

## Autostart: podman-compose systemd units (shared pattern)

Install the system-wide systemd unit template for `podman-compose` files **once**:

```bash
sudo podman-compose systemd -a create-unit
```

Then, in the directory containing the project's `compose.yaml`, run:

```bash
podman-compose systemd
```

This creates a `podman-compose@<project>` unit that can be controlled **without `sudo`**:

```bash
systemctl --user enable --now 'podman-compose@<project>'
systemctl --user status 'podman-compose@<project>'
journalctl --user -xeu 'podman-compose@<project>'
```

For the unit to work outside a login session, linger must be enabled once
(see [Enable linger](host-setup.md#enable-linger)):

```bash
sudo loginctl enable-linger 'chef'
```

Inspect the resulting pod with podman:

```bash
podman pod ps
podman pod stats 'pod_<project>'
podman pod logs --tail=10 -f 'pod_<project>'
```

The remainder of this document only lists the service-specific steps; autostart always follows
this pattern with the project name given in each section.

## Development workflow

All runtime management is systemd user units; development happens on the workstation in a local
clone, on a branch, tested with podman-compose directly:

1. **Branch & edit** on the workstation: `git checkout -b <topic>`.
2. **Validate before pushing** — the same checks CI runs:
   - Test a stack locally: `podman-compose up -d` / `podman-compose down` in the
     stack directory (requires the `caddy-proxy` network and the stack's `.env` files)
   - Caddyfile: `podman run --rm --env-file .env homebase-caddy:2.11.7 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`
3. **Commit & push** — the server deploy key is read-only; commits always
   originate from the workstation (see [host-setup.md](host-setup.md#git-deployment)).
4. **Deploy on the server**: `git pull --rebase --autostash`, then restart the
   systemd unit (`systemctl --user restart podman-compose@<project>`) — for every
   project, core services and stacks alike.
5. **AdGuard drift**: UI changes on the server rewrite `AdGuardHome.yaml` —
   sync the server file back to the workstation, review, commit, push
   (see [operations.md](operations.md)).

## Caddy

Reverse proxy + TLS. Compose file: `caddy/compose.yaml`. Unit: `podman-compose@caddy`.

TLS uses Let's Encrypt wildcard certificates (`sseifried.link` + `*.sseifried.link`) issued via the
**DNS-01 ACME challenge** with the official Cloudflare DNS plugin. No inbound port-forwarding is
needed: Caddy proves domain control by publishing `_acme-challenge` TXT records through the
Cloudflare API. LAN clients reach the services through AdGuard Home split DNS
(see [AdGuard Home](#adguard-home-dns-server)). The image is a **local build** from
`caddy/Dockerfile` (official `caddy:2.11.7-builder` + `caddy-dns/cloudflare`), because the official
`caddy` image does not contain the DNS plugin.

### Cloudflare API token

Create the token under **My Profile → API Tokens → Create Custom**:

- Permissions: `Zone / DNS / Edit`
- Zone Resources: `Specific / sseifried.link`
- **No IP restriction** — the residential IP is dynamic; restricting it breaks renewals

Store it in Bitwarden as item `caddy-cloudflare-token` (password field). Do **not** create public
A/AAAA records: DNS-01 does not need them and the homelab stays unadvertised.

### Firewall

Update firewall rules to allow caddy ports to be accessible

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=443/udp
sudo firewall-cmd --reload
```

Also add `dns` for later (used by AdGuard Home)

```bash
sudo firewall-cmd --add-service=dns --permanent
sudo firewall-cmd --reload
```

### First run

1. Provision the Caddy env file from Bitwarden (requires an unlocked Bitwarden CLI):

```bash
cd caddy
ACME_EMAIL="you@example.com" ./provision-caddy-secrets.sh
```

This writes `caddy/.env` (gitignored, mode `0600`) with `CF_API_TOKEN` and `ACME_EMAIL`.

2. Create the shared external network that Caddy and every proxied stack join
(`caddy-proxy` is declared `external: true` in all compose files, so a fresh
`podman-compose up` fails without it):

```bash
./caddy/ensure_proxy_network.sh
```

3. Build the plugin-enabled image, then deploy with the shared pattern above
(unit: `podman-compose@caddy`):

```bash
cd caddy
podman-compose build
```

The first certificate issuance takes 1–2 minutes (the plugin polls Cloudflare for TXT-record
propagation). The CA is pinned to Let's Encrypt via `ACME_CA` in `caddy/.env` (Caddy's defaults
would also try ZeroSSL), and DNS-01 is enabled by the `tls issuer acme { dns cloudflare }` block
on each site — the global `dns` shorthand alone does **not** wire `dns_challenge` into the issuer
in Caddy 2.11, which silently falls back to http-01/tls-alpn-01. To avoid production rate limits
during bring-up, set `ACME_CA` to the staging CA (see `.env.example`), verify against the staging
issuer, then set it back and restart.

## Cockpit

Web management UI — host package (apt), not a container. Cockpit gives a human-readable
overview of system health (Overview/Metrics pages), a journalctl UI (Logs page), and full
control of systemd units: the Services page has a toggle for **user instances**, which is
where the `podman-compose@<project>` units appear (start/stop/restart/enable + per-unit
journal). The `cockpit-podman` extension adds a rootless Podman page for the logged-in
user: containers, pods, images, volumes, per-container logs and a container terminal
(`podman exec` in the browser). Cockpit also ships a web terminal for the host.

### Install

```bash
sudo apt install -y cockpit cockpit-podman
sudo systemctl enable --now cockpit.socket
```

Cockpit listens on `:9090` and authenticates against host accounts (PAM) — add TOTP for
the admin user.

### Reverse proxy

Served at `https://cockpit.sseifried.link` through Caddy:
`reverse_proxy 192.168.178.249:9090` — the AdGuard/HA pattern (rootless containers cannot
reach host services by name, see the note under [AdGuard Home](#adguard-home-dns-server)).
Caddy passes WebSocket connections through, which Cockpit requires. Cockpit validates the
`Origin` header, so the public origin must be allowed in `/etc/cockpit/cockpit.conf`:

```ini
[WebService]
AllowOrigin = https://cockpit.sseifried.link
```

### Firewall

No firewalld rule for `9090` — the port stays closed to the LAN. Caddy reaches Cockpit
from the podman-managed (firewalld-trusted) bridge, the same path AdGuard `:8095` and
Home Assistant `:8123` use.

### Usage

- **Services** page → toggle *User instances* → control the `podman-compose@<project>` units.
- **Podman** page (cockpit-podman) → container logs, terminal, start/stop — rootless, the
  logged-in user's engine (same containers as `podman ps`).
- **Logs** page → journalctl UI, system and user journal.
- From the workstation, **Podman Desktop** connects to the same rootless engine over SSH
  (see [podman.md](podman.md)).
- Planned: OIDC single sign-on via Authentik (see [operations.md](operations.md) TODO).

## AdGuard Home (DNS-Server)

DNS server with blocking & filtering. Compose file: `adguard-home/compose.yaml`. Unit: `podman-compose@adguard-home`.

Runs as a `podman-compose` systemd user unit like Caddy (shared pattern above).
It uses `network_mode: host` and binds `:53` (DNS) and `:8095` (web UI),
which requires the unprivileged-port sysctl and the `dns` firewalld service from
[host-setup.md](host-setup.md).

### Split DNS for `*.sseifried.link`

The public Cloudflare zone for `sseifried.link` intentionally has **no A/AAAA records** — the
homelab is LAN-only. LAN clients resolve the services through an AdGuard Home rewrite:

```
*.sseifried.link → homebase.fritz.box → IP address
```

The TLS certificates are valid for these names (issued via DNS-01), so browsers show a padlock
on the LAN. Clients that do **not** use AdGuard as their DNS (e.g. Fritzbox DHCP handing out the
Fritzbox, IPv6 DNS leaking to extern) get NXDOMAIN for `sseifried.link` — ensure LAN clients use
AdGuard (`192.168.178.249`) as their DNS server.

> **Hardcoded host IP:** `192.168.178.249` (the Fritzbox-assigned static IP, see
> [host-setup.md](host-setup.md#static-ip-address)) is referenced in `caddy/Caddyfile`
> (AdGuard, Home Assistant and Cockpit `reverse_proxy`),
> `stacks/homepage/config/services.yaml` (AdGuard widget),
> `stacks/homeassistant/config/configuration.yaml` (`internal_url`) and
> `docs/podman.md` (Podman Desktop connection). Rootless containers cannot reach
> host services by name, so the IP is hardcoded — if the static IP ever changes,
> update all of these files.
>
> **Do not use `host.containers.internal` here:** the name lives only in the container's
> `/etc/hosts` (so `getent` resolves it), Caddy's `reverse_proxy` resolves upstreams via
> DNS and gets NXDOMAIN, and the pasta gateway (`169.254.1.2`) refuses forwarded
> connections to host services (tested: `Connection refused`). The LAN IP is the only
> working target — verified 2026-10-25.

#### Configure Upstreams in AdGuard Home

Add the following upstreams under Settings → DNS → Upstream DNS servers
(still required — `homebase.fritz.box` itself is resolved by the Fritzbox):

```
[/fritz.box/]192.168.178.1
[/178.168.192.in-addr.arpa/]192.168.178.1
```

#### Create DNS Rewrite Rules

Add the wildcard rewrite for `*.sseifried.link` under Filters → DNS Rewrites.

Recommended CNAME approach:

```
Domain: *.sseifried.link
Target: homebase.fritz.box
```

This should automatically resolve to a `CNAME` record.

> **Live config drift:** AdGuard Home rewrites `config/AdGuardHome.yaml` on every UI change.
> Make rewrite changes in the UI **on the server**, then sync the file back to the workstation,
> review, commit, push (see [operations.md](operations.md)).

#### Verification

Run from any LAN client:

```bash
dig cockpit.sseifried.link
dig homebase.fritz.box
dig +trace cockpit.sseifried.link   # public resolution: NXDOMAIN is expected
```

## Wanderer (Trail Database)

Self-hosted trail database ([wanderer](https://github.com/open-wanderer/wanderer)).
Compose file: `stacks/wanderer/compose.yaml`. Unit: `podman-compose@wanderer`
(shared pattern above — like Caddy/AdGuard/Homepage).

Three services: `web` (SvelteKit UI — the only one on `caddy-proxy`, alias `wanderer`),
`db` (PocketBase) and `search` (Meilisearch) on the internal `wanderer-internal` network.
No host ports: the UI is served through Caddy at `https://wanderer.sseifried.link`.
The instance is private (`PUBLIC_PRIVATE_INSTANCE: "true"`) — users only see their own trails.

### First run

The steps below run in the stack checkout — on the server that is the
`~/src/homebase` clone.

1. Provision the secrets (requires an unlocked Bitwarden CLI):

```bash
cd stacks/wanderer
./provision-wanderer-secrets.sh
```

The script fetches the three keys from the Bitwarden items `wanderer-meili-key`,
`wanderer-pb-encryption-key` and `wanderer-pb-proxy-secret` (password field) into
`.env.secret` (gitignored, mode `0600`). On the first run the items do not exist yet:
the script generates the keys and prints them — save them to Bitwarden under those
names. **`POCKETBASE_ENCRYPTION_KEY` encrypts trail data at rest; rotating it after
data exists makes the database unreadable.**

2. Rootless bind-mount ownership: `meilisearch` and the web app run as container
uid 1000, which rootless Podman maps into the subuid range — a `data/` directory
owned by the host user is not writable for them. Pre-create and chown once:

```bash
mkdir -p data/pb_data data/uploads data/data.ms data/plugins
podman unshare chown 1000:1000 data/data.ms data/uploads
```

PocketBase runs as root — container root maps to the host user, so `pb_data` and
`plugins` need no chown. Skipping this step shows up as permission-denied crashes
in the search/web containers on first start.

3. Open `https://wanderer.sseifried.link` and create your account — signup is
enabled by design. The instance is private (`PUBLIC_PRIVATE_INSTANCE: "true"`), so new
accounts only ever see their own trails, and the box is LAN-only (no public DNS
records). To close registration later, set `PUBLIC_DISABLE_SIGNUP: "true"` in
`compose.yaml`, commit and redeploy.

4. Deploy with the shared pattern above (unit: `podman-compose@wanderer`):

```bash
podman-compose systemd
systemctl --user enable --now podman-compose@wanderer
```

5. Verify:

```bash
podman pod ps
curl -k https://wanderer.sseifried.link
podman logs --tail=20 wanderer-search-1   # Meilisearch must come up healthy
```

### Meilisearch upgrades

The `data.ms` format is **not forward-compatible** — a newer engine refuses to
open an older index directory and crash-loops. On a version bump: set
`MEILI_UPGRADE_DB: "true"` on the search service, restart the unit once
(`systemctl --user restart podman-compose@wanderer` — the engine upgrades
`data.ms` in place), then remove the flag and restart again.
Fallback if the in-place upgrade fails: wipe `data/data.ms` (recreate +
`podman unshare chown 1000:1000 data/data.ms`) — the index rebuilds from
PocketBase; if PocketBase's `init_meilisearch` migration is already recorded
as applied, wipe all of `data/` (fresh start, re-create the account).
Dependabot bumps for Meilisearch are allowed; merge them only together with
this procedure.

### Valhalla (optional, not deployed)

Route planning falls back to the public endpoint `https://valhalla1.openstreetmap.de`
(`VALHALLA_URL` default). Self-hosting Valhalla (multi-GB OSM extract, extra RAM/disk)
is a future option — see the commented block in the upstream `docker-compose.yml`.

## Home Assistant (Home Automation)

Home automation platform ([home-assistant](https://www.home-assistant.io/)).
Compose file: `stacks/homeassistant/compose.yaml`. Unit: `podman-compose@homeassistant`
(shared pattern above — like Caddy/AdGuard/Homepage/Wanderer).

Single service in **Container** install mode — the only mode viable under
Podman (no Supervisor, no add-ons; MQTT, ZHA etc. come as integrations).
`network_mode: host` (like AdGuard Home) — required for local device discovery
(mDNS/SSDP/UPnP, HomeKit, inbound integrations). No host ports are opened for
LAN access: clients reach the UI only through Caddy at
`https://homeassistant.sseifried.link` (Caddy proxies the hardcoded host IP
`192.168.178.249:8123` — rootless containers cannot reach host services by
name, see the AdGuard note above); `:8123` stays closed to the LAN (no
firewalld rule — by design).

### First run

The steps below run in the stack checkout — on the server that is the
`~/src/homebase` clone.

1. Deploy with the shared pattern above (unit: `podman-compose@homeassistant`):

```bash
cd stacks/homeassistant
podman-compose systemd
systemctl --user enable --now podman-compose@homeassistant
```

2. Open `https://homeassistant.sseifried.link` and complete the onboarding
   wizard — create the owner account, set the location to Vienna
   (lat 48.1680783, lon 16.3197505, `Europe/Vienna` — matches the dashboard).

3. Verify:

```bash
podman ps
curl -k https://homeassistant.sseifried.link/   # onboarding HTML
podman logs --tail=20 homeassistant-homeassistant-1
```

Logging in **through Caddy** must work — that proves `trusted_proxies` in
`config/configuration.yaml` matches the live caddy-proxy subnet (see below).

### Reverse proxy (trusted_proxies)

HA sits behind Caddy: `http: use_x_forwarded_for: true` plus
`trusted_proxies: [10.89.0.0/24]` in `config/configuration.yaml`. Caddy
connects from the `caddy-proxy` bridge subnet; that network is created
**unpinned** (`caddy/ensure_proxy_network.sh`) and its subnet has changed
before (10.88.0.0/16 → 10.89.0.0/24). After any network recreation, verify
with `podman network inspect caddy-proxy` and update the entry — symptom of a
stale entry is login failures via the proxy (see
[operations.md](operations.md) troubleshooting).

### Config drift (committed YAML, gitignored state)

`config/` is committed to git (AdGuard drift pattern) — **YAML files only**:

- committed: `configuration.yaml`, `automations.yaml`, `scripts.yaml`, `scenes.yaml`
- gitignored: `.storage/` (UI-managed state: integrations, dashboards, users,
  long-lived access tokens) and `secrets.yaml` (credentials, referenced via `!secret`)

UI changes to the YAML files (YAML-mode automations, YAML dashboards) rewrite
them on the server — sync the server files back to the workstation, review,
commit, push (same ritual as `AdGuardHome.yaml`, see
[operations.md](operations.md)). `.storage/` and `secrets.yaml` are data, not
code: they are covered by `./backup-ha-config.sh` (see
[operations.md](operations.md)).

### USB radios (future toggle)

ZHA / Zigbee2MQTT via a USB dongle needs privileged mode + device passthrough —
intentionally **not** set in the initial setup (keeps `no-new-privileges`).
To enable: attach the dongle to the VM (Proxmox USB passthrough), add
`privileged: true` and `devices: [/dev/ttyUSB0]` to the service, redeploy.

### Ownership

HA runs as root inside the container; rootless Podman maps it to the host user,
so a host-user-owned `config/` is writable — no `podman unshare chown` needed
(unlike Wanderer's uid-1000 services).
