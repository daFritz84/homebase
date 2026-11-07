# Services

Each service runs from its own `compose.yaml` via `podman-compose` and is managed as a user
systemd unit. Prerequisites (Podman, firewalld, unprivileged ports, linger) are covered in
[host-setup.md](host-setup.md).

- [Autostart: podman-compose systemd units (shared pattern)](#autostart-podman-compose-systemd-units-shared-pattern)
- [Development workflow](#development-workflow)
- [Caddy](#caddy)
- [Cockpit](#cockpit)
- [AdGuard Home (DNS-Server)](#adguard-home-dns-server)
- [Wanderer (Trail Database)](#wanderer-trail-database)
- [Home Assistant (Home Automation)](#home-assistant-home-automation)
- [Authelia (SSO)](#authelia-sso)
- [Cloudflare Tunnel (cloudflared)](#cloudflare-tunnel-cloudflared)

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
   - Test a service locally: `podman-compose up -d` / `podman-compose down` in the
     service directory (requires the `caddy-proxy` network and the service's `.env` files)
   - Caddyfile: `podman run --rm --env-file .env homebase-caddy:2.11.7 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`
3. **Commit & push** — the server deploy key is read-only; commits always
   originate from the workstation (see [host-setup.md](host-setup.md#git-deployment)).
4. **Deploy on the server**: `git pull --rebase --autostash`, then restart the
   service's containers (`podman restart <container>` — a unit restart can be a
   no-op on a running pod, see [operations.md](operations.md)) — for every project.
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
Caddy passes WebSocket connections through, which Cockpit requires. Cockpit validates both
the browser `Origin` and the `Host` header (only `localhost`, the machine hostname and
`AllowOrigin` hosts pass — a bare `curl` to the host IP returns an empty response), so the
site must forward the public Host: `header_up Host cockpit.sseifried.link`. Allow the public
origin in `/etc/cockpit/cockpit.conf`:

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
- **Out of scope for Authelia SSO** (user decision): Cockpit keeps PAM + TOTP, VPN/LAN only.
  As a host management tool its authentication never depends on a hosted identity
  provider — no OIDC, no oauth2-proxy, no SSO.
- **Never via Cloudflare** (user decision): Cockpit is **never** added to the
  tunnel ingress (`cloudflared/config.yml`), has **no public DNS record**
  (NXDOMAIN from the internet), and is not exposed through Cloudflare Access
  in any form. LAN/VPN + PAM + TOTP unchanged — the 4-fold enforcement is
  documented under [Cloudflare Tunnel](#cloudflare-tunnel-cloudflared).

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

> **Host services from bridge containers:** Caddy's `reverse_proxy` upstreams for
> AdGuard (`:8095`), Home Assistant (`:8123`) and Cockpit (`:9090`), and the AdGuard
> widget in `homepage/config/services.yaml`, target `host.containers.internal` —
> podman injects it into `/etc/hosts` as `169.254.1.2` (pasta `--map-guest-addr`),
> which relays to the host loopback, so the upstream connection arrives from
> `127.0.0.1` and is firewalld-trusted. Verified 2026-11-05.
>
> **Do not target the LAN IP (`192.168.178.249`) from bridge containers:** the
> connection lands in the firewalld `public` zone and is rejected on ports that are
> not permanently opened there (this broke all walled apps after the 2026-11-05
> reboot when firewalld lost netavark's runtime bridge trust; see
> [operations.md](operations.md) troubleshooting). The LAN IP stays correct for
> **LAN-facing** references: the AdGuard DNS rewrite (`*.sseifried.link`), HA
> `internal_url`, and the Podman Desktop SSH connection (see
> [host-setup.md](host-setup.md#static-ip-address)).

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
Compose file: `wanderer/compose.yaml`. Unit: `podman-compose@wanderer`
(shared pattern above — like Caddy/AdGuard/Homepage).

Three services: `web` (SvelteKit UI — the only one on `caddy-proxy`, alias `wanderer`),
`db` (PocketBase) and `search` (Meilisearch) on the internal `wanderer-internal` network.
No host ports: the UI is served through Caddy at `https://wanderer.sseifried.link`.
The instance is private (`PUBLIC_PRIVATE_INSTANCE: "true"`) — users only see their own trails.

### First run

The steps below run in the service checkout — on the server that is the
`~/src/homebase` clone.

1. Provision the secrets (requires an unlocked Bitwarden CLI):

```bash
cd wanderer
./provision-wanderer-secrets.sh
```

The script fetches four keys from the Bitwarden items `wanderer-meili-key`,
`wanderer-pb-encryption-key`, `wanderer-pb-proxy-secret` and
`wanderer-pocketbase-admin` (password field) into `.env.secret` (gitignored,
mode `0600`). On the first run the items do not exist yet: the script
generates the keys and prints them — save them to Bitwarden under those
names. `POCKETBASE_ADMIN_EMAIL`/`POCKETBASE_ADMIN_PASSWORD` make PocketBase
upsert the superuser (`admin@sseifried.link`) at every container start, so
the admin account and the SSO script's API access survive a full stack
recreation. **`POCKETBASE_ENCRYPTION_KEY` encrypts trail data at rest;
rotating it after data exists makes the database unreadable.**

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

3. Open `https://wanderer.sseifried.link` and create your account. The
instance is private (`PUBLIC_PRIVATE_INSTANCE: "true"`), so accounts only
ever see their own trails. Registration is now closed
(`PUBLIC_DISABLE_SIGNUP: "true"` — the app is internet-published via
Cloudflare Access and accounts arrive through Authelia OIDC, which creates
records server-side and is unaffected by the flag; set it back to `"false"`
to reopen signup, e.g. for a new person's first account).

4. Deploy with the shared pattern above (unit: `podman-compose@wanderer`):

```bash
podman-compose systemd
systemctl --user enable --now podman-compose@wanderer
```

5. Verify:

```bash
podman pod ps
curl -k https://wanderer.sseifried.link
podman logs --tail=20 wanderer_search_1   # Meilisearch must come up healthy
```

### Wanderer SSO (Authelia OIDC via PocketBase)

Wanderer's own account system (PocketBase) federates to Authelia via generic
OIDC: the login page gets an **Authelia button**, and because the
`authelia_session` cookie covers `sseifried.link`, the OIDC redirect is
authorized **silently** — one login end to end (internet via Access, LAN via
split DNS). The wall (forward_auth) and the app login are separate layers;
this closes the second one.

- **Authelia client:** `wanderer` in `authelia/config/configuration.yml`
  (confidential, PKCE S256, `client_secret_post` — PocketBase posts
  credentials in the token body; argon2 digest from `.env.secret`, RAW
  secret = Bitwarden `authelia-oidc-wanderer-secret`, printed by
  `provision-authelia-secrets.sh`). Redirect:
  `https://wanderer.sseifried.link/login/redirect` (PocketBase's fixed
  callback path).
- **PocketBase admin UI** (the `db` service has no host port — bridge
  containers can't reach host services, so the admin UI is reached through a
  throwaway socat container on `wanderer-internal`, bound to the server's
  loopback only; `podman port-forward` does not exist on the server's podman
  version):

```bash
podman run -d --rm --name pb-admin-proxy --network wanderer-internal \
  -p 127.0.0.1:8090:8090 docker.io/alpine/socat \
  TCP-LISTEN:8090,fork TCP-CONNECT:db:8090
# workstation: ssh -L 8090:localhost:8090 chef@192.168.178.249
# browser: http://localhost:8090/_/
# done: podman stop pb-admin-proxy
```

  The provider config lives in the PocketBase DB (not in a file), so it is
  scripted: start the socat proxy above, unlock Bitwarden, then run
  `./provision-wanderer-sso.sh` from `wanderer/` on the server. It reads the
  RAW client secret from Bitwarden `authelia-oidc-wanderer-secret`
  (`PB_CLIENT_SECRET=…` env override for testing), the superuser credentials
  from `.env.secret` (`provision-wanderer-secrets.sh` creates them), and
  upserts the `oidc` slot via the REST API — idempotent, re-runnable after
  stack recreation.
- **API shape gotchas** (flomp/wanderer-db vendors PocketBase 0.38.0 core —
  registry slots `oidc|oidc2|oidc3` — but the fork's users collection carries
  a custom top-level `oauth2` field, not 0.23+ `options.authMethods`). The
  provider struct is FLAT and REDUCED: `name`, `displayName` (login-button
  label), `clientId`, `clientSecret` (write-only, GET masks it), `authURL`,
  `tokenURL`, `userInfoURL`, `pkce`, `extra` — unknown keys are silently
  dropped, and the 400 bodies name the surviving keys. The slot `name` MUST
  be a registry key (`oidc`), not a free-form label. Claim attrs (`email` /
  `preferred_username` / `email_verified`), scopes (`openid profile email`,
  overridable per slot via the `OIDC_SCOPES` env var) and the S256 PKCE
  method are PocketBase core defaults the fork does not expose.
- **Account migration (do this BEFORE the first OIDC login):** OIDC logins
  create NEW PocketBase users — accounts are never linked by email, and
  trails belong to the user record. Log in once via OIDC (creates a fresh
  account), open it in the admin UI, copy its **Provider ID** (= Authelia's
  `sub` claim), attach that credential (auth-method `oidc` + Provider ID)
  to your EXISTING account, delete the fresh account. Your trails stay
  on the old account. The partner needs no migration — their first OIDC
  login creates their account (username `partner`, own trails).
- **Optional:** disable PocketBase password auth (users → Options →
  Identity/Password toggle) once SSO works — keep it as break-glass if
  Authelia-down app access matters.

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
Compose file: `homeassistant/compose.yaml`. Unit: `podman-compose@homeassistant`
(shared pattern above — like Caddy/AdGuard/Homepage/Wanderer).

Single service in **Container** install mode — the only mode viable under
Podman (no Supervisor, no add-ons; MQTT, ZHA etc. come as integrations).
`network_mode: host` (like AdGuard Home) — required for local device discovery
(mDNS/SSDP/UPnP, HomeKit, inbound integrations). No host ports are opened for
LAN access: clients reach the UI only through Caddy at
`https://homeassistant.sseifried.link` (Caddy proxies
`host.containers.internal:8123`, see the AdGuard note above); `:8123`
stays closed to the LAN (no firewalld rule — by design). Auth is HA's own
OIDC login against Authelia — see "HA SSO (hass-oidc-auth)" under Authelia.

> **Rootless capability limits (expected):** `aiodhcpwatcher` (DHCP discovery) and
> `habluetooth` log `Operation not permitted` / `Missing NET_ADMIN/NET_RAW capabilities` —
> AF_PACKET in the host netns is not grantable to a rootless container, so those two
> integrations stay unavailable. mDNS/SSDP/UPnP discovery works without extra capabilities;
> do not add `cap_add` (it cannot work rootless). `exit code 100` in the entrypoint log is
> HA's normal restart request (e.g. after onboarding); a `Pending HTTP config was not
> confirmed` warning after that restart is a dropped wizard session — reload the page.

### First run

The steps below run in the service checkout — on the server that is the
`~/src/homebase` clone.

1. Deploy with the shared pattern above (unit: `podman-compose@homeassistant`):

```bash
cd homeassistant
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
podman logs --tail=20 homeassistant_homeassistant_1
```

Logging in **through Caddy** must work — that proves `trusted_proxies` (UI-managed,
see below) lists the host IP Caddy proxies from.

### Reverse proxy (trusted_proxies)

HA sits behind Caddy with `use_x_forwarded_for: true` and
`trusted_proxies: [127.0.0.1, ::1]`. HA is `network_mode: host` and Caddy
reaches it via `host.containers.internal` (pasta relay), so HA sees the proxy
source as the host loopback — **not** the host LAN IP and **not** the
`caddy-proxy` bridge subnet (the old `192.168.178.249` / `10.89.0.0/24` values
are wrong here; a stale/missing entry shows up as login failures via the proxy,
see [operations.md](operations.md) troubleshooting).

This setting is **UI-managed**, not in `configuration.yaml`: HA migrated the
`http:` block into `.storage/http` (`yaml_migration_done`) and now ignores any
`http:` block in `configuration.yaml` (a hard error in 2027.2.0). Manage it under
**Settings → System → Network → Trusted Proxies / X-Forwarded-For**; the value
lives in `.storage/http` (gitignored, covered by `./backup-ha-config.sh`).

### Config drift (committed YAML, gitignored state)

`config/` is committed to git (AdGuard drift pattern) — **YAML files only**:

- committed: `configuration.yaml`, `automations.yaml`, `scripts.yaml`, `scenes.yaml`
- gitignored: `.storage/` (UI-managed state: integrations, dashboards, users,
  long-lived access tokens, **and the `http:`/trusted_proxies config**) and
  `secrets.yaml` (credentials, referenced via `!secret`)

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

## Authelia (SSO)

Single self-hosted identity layer: **Authelia** (login portal, 2FA, OIDC IdP)
+ **OpenLDAP** (user store). Compose file: `authelia/compose.yaml`. Unit:
`podman-compose@authelia` (shared pattern above).

```
Browser (LAN, AdGuard split DNS)
  │ https://<app>.sseifried.link
  ▼
Remote (public internet, no VPN)
   │ https://wanderer|authelia.sseifried.link — ONLY these two, via Cloudflare
   │ Access (Authelia OIDC federation login) + cloudflared tunnel
  ▼
Caddy (wildcard cert)
  ├─ homepage.sseifried.link ──► homepage:3000 (native OIDC gate → Authelia)
  ├─ homeassistant.sseifried.link ──► host.containers.internal:8123 (native OIDC client → Authelia (gate))
  ├─ adguard|wanderer ──► forward_auth authelia:9091 (wall) ──► upstream
  ├─ cockpit.sseifried.link ──► unchanged (PAM + TOTP, no Authelia, LAN/VPN-only)
  └─ authelia.sseifried.link ──► authelia:9091 (login + portal + OIDC IdP;
       internet-published via the tunnel — federation login + wall redirects)

authelia stack: authelia (9091) ── authelia-internal ── openldap (389)
                sqlite db + openldap data in named volumes
```

Policies (`access_control` in `authelia/config/configuration.yml`):
**default deny**; `one_factor` for `group:homebase-admins` on AdGuard and for
`group:homebase-admins` **or** `group:homebase-users` on Wanderer (the
internet-published app, shared with the partner); no rules for the Authelia
portal (its endpoints are exempt from ACL), Homepage (no forward_auth — its
own OIDC gate enforces auth: Authelia authorizes the `homepage` OIDC client,
and Homepage admits any identity Authelia authorizes) or Home Assistant (no
forward_auth — gated by its OIDC client's `authorization_policy` + the
component's `roles`: only `homebase-admins` is admitted, admins-only as the
old wall rule). Cockpit has **no rule and no forward_auth** — it stays
outside Authelia entirely. Session cookie domain `sseifried.link` → one
login, all walled apps (true SSO). OIDC clients: `homepage`, `homeassistant`,
`wanderer` (PocketBase app-level SSO — see "Wanderer SSO") and
    `cloudflare-access` (Cloudflare Access federation — the raw client
    secret goes to the Access IdP form, the argon2 digest to `.env.secret`;
    `scopes: openid/email/profile`). Second factors: TOTP + WebAuthn passkeys, enrolled at
`https://authelia.sseifried.link/portal` — **optional for now**: policies run
`one_factor`; flip the walled-app rules + the `homepage`/`homeassistant`/
`cloudflare-access` OIDC clients' `authorization_policy` to `two_factor`
after enrolling (passkeys work through the tunnel: rp_id `sseifried.link`,
real domain).

### First run

The steps below run in the service checkout — on the server that is the
`~/src/homebase` clone.

1. Provision the secrets (requires an unlocked Bitwarden CLI; the shared
   `caddy-proxy` network must exist — `./caddy/ensure_proxy_network.sh`):

```bash
cd authelia
./provision-authelia-secrets.sh
```

   The script fetches/generates the `AUTHELIA_*` secrets + the LDAP admin
   password into `.env.secret` (gitignored, mode `0600`), plus more
   entries: the argon2 digests of the Homepage, Home Assistant and
   Cloudflare Access OIDC client secrets — as
   `HOMEPAGE_OIDC_CLIENT_SECRET_HASH` / `HA_OIDC_CLIENT_SECRET_HASH` /
   `CLOUDFLARE_OIDC_CLIENT_SECRET_HASH`, injected into `configuration.yml`
   by the `template` filter (indexed `AUTHELIA_..._CLIENTS_0_...` env
   overrides are NOT supported — 4.39 rejects them), so the committed file
   keeps its placeholders — and the generated Authelia **login passwords**
   (`LDIF_LOGIN_PASSWORD` for `uid=sseifried`, `LDIF_PARTNER_PASSWORD` for
   `uid=partner`, printed on first generation: save them to Bitwarden as
   `authelia-login-password` / `authelia-partner-login-password`). It also
   prints the **raw** OIDC client secrets: for `homepage/.env` as
   `HOMEPAGE_OIDC_CLIENT_SECRET`, for `homeassistant/config/secrets.yaml`
   as `ha_oidc_client_secret` (gitignored — never commit), and as the
   client secret of the Authelia OIDC IdP in the Cloudflare Access
   dashboard (see "Cloudflare Tunnel"). Save generated items to Bitwarden
   (the HA client secret is item `authelia-oidc-homeassistant-secret`, the
   Cloudflare one `authelia-oidc-cloudflare-secret`).

2. Generate the OIDC RSA signing key pair (gitignored, covered by
   `backup-authelia.sh`):

```bash
mkdir -p config/keys
podman run --rm -v "$(pwd)/config/keys:/keys" docker.io/authelia/authelia:4.39.28 \
  authelia crypto pair rsa generate --bits 2048 --directory /keys \
  --file.private-key oidc.key --file.public-key oidc.pub
```

   Then render the LDIF: `config/bootstrap.ldif` is a committed **template**
   whose `{REPLACE_ME}` `userPassword` placeholders are deployment secrets —
   `./render-ldif.sh` fills them with `{SSHA}` hashes computed from
   `.env.secret` with `python3` `hashlib` (SHA1(pw+salt)‖salt — the exact
   scheme slapd verifies; never the openldap image's `slappasswd`, whose
   output slapd 2.4.57 rejects on simple bind, see "4.39 schema notes")
   into the gitignored `config/bootstrap.rendered.ldif`:

```bash
./render-ldif.sh
```

   The LDIF `userPassword` must be a scheme **slapd** can verify — Authelia
   authenticates by binding as the user, so OpenLDAP checks the hash, and
   osixia 1.5.0's OpenLDAP 2.4.57 cannot verify argon2 (a bare `$argon2id$…`
   digest is treated as plaintext → login "password is wrong"). The
   `{scheme}` prefix on the placeholders makes slapd reject the unreplaced
   template, so applying it by accident fails closed. The `cn=admin` entry
   gets the hash of the LDAP admin bind password
   (`authelia-ldap-admin-password` = `LDAP_ADMIN_PASSWORD` in `.env.secret`):
   osixia 1.5.0 never creates the `cn=admin` entry (it only sets `olcRootPW`
   in `cn=config`), so without it every simple bind as `cn=admin` fails with
   "Invalid credentials (49)".

3. Validate the config **offline**, before the stack starts. With a missing
   `config/keys/oidc.key` (the `template` filter's `fileContent` read)
   authelia exits at startup and crash-loops (`restart: unless-stopped`), so
   validating via `podman exec` into the container started in step 4 fails
   exactly when validation is needed — while the walled apps 502. The
   `--env-file` is required: the config's secrets (session secret, storage
   encryption key, OIDC HMAC secret, and the OIDC client secret digest
   injected into the committed placeholder by the `template` filter) are
   read from `.env.secret` via env vars, and the validator hard-fails on
   missing required options:

```bash
podman run --rm --env-file .env.secret -v "$(pwd)/config:/config" \
  -e X_AUTHELIA_CONFIG_FILTERS=template \
  docker.io/authelia/authelia:4.39.28 \
  authelia config validate --config /config/configuration.yml --config.experimental.filters template
```

4. Start the stack and load the directory (the LDIF creates the `cn=admin`
   entry osixia never creates — the bind must succeed before `ldapadd` can
   run, so the rendered file from step 2 must exist).
   podman-compose **ignores**
   `depends_on: condition: service_healthy` (start ordering only), so on
   first start authelia starts while slapd is still bootstrapping, fails its
   LDAP connection, and crash-loops for ~30s until slapd answers —
   `restart: unless-stopped` self-heals it; the openldap healthcheck is for
   podman's own visibility. The LDIF is **piped from the host checkout**: the
   openldap container has no `./config` mount (only the authelia service
   binds `config/`), so `-f /config/...` inside it is "No such file":

```bash
podman-compose up -d
podman exec -i authelia_openldap_1 ldapadd -x \
  -D "cn=admin,dc=sseifried,dc=link" -W < config/bootstrap.rendered.ldif
```

   `-W` prompts for the LDAP admin password (Bitwarden item
   `authelia-ldap-admin-password`). Re-runnable with `ldapadd -c` for new
   users/groups only — it cannot change EXISTING entries (group membership
   needs `ldapmodify`, see "User management").

5. Deploy with the shared pattern (unit: `podman-compose@authelia`):

```bash
podman-compose -f compose.yaml systemd
systemctl --user enable --now podman-compose@authelia
```

6. Wire the consumers: add the Homepage auth vars to `homepage/.env`
   (see `homepage/.env.example`), restart `podman-compose@homepage`, and
   restart `podman-compose@caddy` after the Caddyfile changes (validate the
   Caddyfile first — shared pattern).

7. Verify:

```bash
curl -ki https://adguard.sseifried.link | head -n 5   # 302 → authelia.sseifried.link
podman logs --tail=20 authelia_authelia_1
```

   Then in a browser: log in at `https://authelia.sseifried.link/portal`
   (enroll TOTP + a passkey), open AdGuard → lands back authenticated; open
   Home Assistant → its login page redirects to Authelia → lands in HA as
   admin (**no second login** — native OIDC SSO, see "HA SSO").

### User management (LDIF ritual)

Users/groups are **gitops**: `authelia/config/bootstrap.ldif` is the source of
truth (no admin UI). Add a user → edit the LDIF, commit, push, then on the
server (from `~/src/homebase/authelia`) `./render-ldif.sh` and
`podman exec -i authelia_openldap_1
ldapadd -c -x -D "cn=admin,dc=sseifried,dc=link" -W <
config/bootstrap.rendered.ldif` — piped from the host checkout, because the openldap
container has no `./config` mount (AdGuard drift pattern: the committed file
is authoritative, the directory is the runtime copy — covered by
`backup-authelia.sh`). `ldapadd` only issues ADD ops: existing entries are
skipped by `-c`, so it **cannot grant group membership** — the `member:`
values live in the existing group entry, its add is skipped, and the new
member is silently NOT applied (the user exists, every `subject: group:...`
rule still denies it). Grant membership with `ldapmodify`:

```bash
podman exec -i authelia_openldap_1 ldapmodify -x \
  -D "cn=admin,dc=sseifried,dc=link" -W <<EOF
dn: cn=homebase-users,ou=groups,dc=sseifried,dc=link
changetype: modify
add: member
member: uid=partner,ou=users,dc=sseifried,dc=link
EOF
```

Password changes = re-render (`./render-ldif.sh`) + `ldapmodify`
(`replace: userPassword` with the freshly rendered `{SSHA}` hash).
`uid=partner` (homebase-users) is in the LDIF — the Wanderer-sharing partner
account (internet access via Cloudflare Access, see "Cloudflare Tunnel");
its login password is Bitwarden `authelia-partner-login-password`, handed
out out-of-band.

### HA SSO (hass-oidc-auth)

HA is **not** walled by Caddy `forward_auth`: it is a native Authelia **OIDC
client** (like Homepage), using the vendored, pinned
[hass-oidc-auth](https://github.com/christiaangoossens/hass-oidc-auth)
integration — v1.2.1, unpacked from the release zip into
`homeassistant/config/custom_components/auth_oidc/` (tracked in git, no
HACS). The `homeassistant` client is registered in
`authelia/config/configuration.yml` (confidential + PKCE S256, argon2
digest from `.env.secret`); the HA side is the `auth_oidc:` block in
`homeassistant/config/configuration.yaml` (secret via `!secret
ha_oidc_client_secret` in gitignored `secrets.yaml`).

- **Login flow:** `features.default_redirect: true` sends browsers straight
  to Authelia; after the portal login the OIDC callback lands in HA. The
  `sseifried.link` session cookie makes it SSO: one portal login → HA.
- **Admins-only policy** (reproduces the old wall rule
  `group:homebase-admins`): `roles.admin: 'homebase-admins'` **and**
  `roles.user: 'homebase-admins'` — configuring `roles.user` makes the
  component **reject** identities in neither group. Phase 2 `uid=partner`
  (homebase-users) stays out of HA until a role is added then.
- **Account migration (done):** `features.automatic_user_linking: true`
  (TEMPORARY) links the first OIDC login to the existing HA user whose
  username credential exactly matches the `preferred_username` claim (LDAP
  uid, e.g. `sseifried`). The owner was linked this way on 2026-11-07 and
  the flag was **removed** afterwards — the username match bypasses MFA, so
  it stays enabled only for a one-time link. Re-enable it (restart the unit)
  if a future user needs the same one-time link, then remove it again.
- **HA's own login stays enabled** as break-glass (Companion tokens, direct
  host access, Authelia down). Backup form:
  `https://homeassistant.sseifried.link/?skip_oidc_redirect=true`; from the
  host: `http://127.0.0.1:8123/?skip_oidc_redirect=true`.
- **Companion app / Bearer-token API clients:** talk to HA directly — HA
  validates its own long-lived access tokens. The old Caddyfile bypasses
  (`@companion` UA matcher, `@bearer` handle) existed only to dodge the
  wall; with the wall gone they are removed, and the "Companion UA
  spoofing" residual risk is **retired** (nothing left to evade). Keep
  long-lived tokens scoped and revocable.
- **Webhooks** (`/api/webhook/<id>`, no `Authorization` header): keep
  calling them on the LAN address (`192.168.178.249:8123`); they also work
  via the domain now that nothing walls it.
- **Exposure change:** HA's login page is reachable by anything that
  resolves the domain (LAN + VPN via split DNS — no change in *who*
  resolves it). Brute force against the HA form is not covered by
  Authelia's portal rate limiting; accepted for LAN-only (optional
  follow-up: `trusted_networks` provider for loopback).

**Upgrade procedure (vendored component):** fetch the release zip from the
upstream releases page → replace the contents of
`homeassistant/config/custom_components/auth_oidc/` → **review the diff**
(the `.gitleaks.toml` allowlist covers this tree, so the diff review is the
security gate) → commit → restart `podman-compose@homeassistant`. Check
upstream releases/issues **before bumping the HA core image**: the
integration injects frontend assets and can break on core updates; HA's
own login is the fallback.

### Break-glass

Authelia down = walled apps (AdGuard UI, Wanderer) unreachable (502).
Home Assistant keeps serving (native OIDC client, not walled) — only its
login redirect to Authelia fails; existing HA sessions keep working, and
the break-glass form is `http://127.0.0.1:8123/?skip_oidc_redirect=true`
from the host. Cockpit, Homepage, VPN and SSH are unaffected. Recovery: SSH in →
`systemctl --user restart podman-compose@authelia`. Lockout guard: TOTP
secrets live in Bitwarden, factors in the sqlite DB, users in LDAP — the
factors DB and users are covered by `backup-authelia.sh`, the
`AUTHELIA_STORAGE_ENCRYPTION_KEY` that decrypts the factors DB is
**Bitwarden-only** (not in the archive): a restore needs
`./provision-authelia-secrets.sh` (unlocked vault) to recreate
`.env.secret`, see [operations.md](operations.md), "Authelia backups".

### 4.39 schema notes

The integration plan predates the Authelia 4.38 config rewrite; the committed
files use the current (4.39.28) schema:

- `server.trusted_proxies` **removed** — proxy trust lives in Caddy
  (`forward_auth trusted_proxies`, must match the `caddy-proxy` subnet, see
  [operations.md](operations.md) troubleshooting).
- ACL rules have no `bypass_credentials`/user-agent criteria → moot: HA is
  a native OIDC client (no wall, no bypasses) and the remaining walled apps
  need none.
- Legacy `/api/authelia/validate?rd=` endpoint → `/api/authz/forward-auth`;
  the portal URL comes from `session.cookies[].authelia_url`.
- OIDC issuer is derived from `authelia_url` (no explicit `issuer` key); the
  signing key pair is injected into `configuration.yml` via the `template`
  config filter (`fileContent` of the gitignored `config/keys/oidc.key`).
- `authelia hash-password` → `authelia crypto hash generate argon2`;
  `authelia validate` → `authelia config validate`. The CLI reads the
  password from an interactive **tty** only — stdin is NOT supported — so
  non-interactive use needs `--random` (prints plaintext + digest) or
  `--password` (transient argv).
- LDAP `userPassword` schemes: Authelia logs users in by **binding as them**,
  so SLAPD verifies the hash. osixia 1.5.0 ships OpenLDAP 2.4.57 — no argon2
  support — so LDIF passwords use `{SSHA}` — `./render-ldif.sh` hashes with
  `python3` `hashlib` (SHA1(pw+salt)‖salt, 4-byte salt) from `.env.secret`
  into the gitignored rendered LDIF. **Never hash via the openldap image's
  `slappasswd`**: its `{SSHA}` payload is self-consistent under
  `slappasswd -v` (offline checks pass) but slapd 2.4.57 rejects it on
  simple bind — every user login 49s, while the `cn=admin` entry appears
  fine because osixia's startup rewrites the admin password with slapd's
  internal pw module (diagnosed 2026-11-07: manual SHA1(pw+salt) ≠ payload
  of the image's hashes). Argon2 digests are only for the OIDC
  `client_secret`, injected into `configuration.yml` from `.env.secret` by
  the `template` filter (`{{ env "HOMEPAGE_OIDC_CLIENT_SECRET_HASH" }}` —
  indexed `AUTHELIA_..._CLIENTS_0_...` env overrides are rejected by 4.39:
  "configuration environment variable not expected"), which Authelia
  verifies itself.
- osixia 1.5.0 does not create the `cn=admin` entry (only `olcRootPW` in
  `cn=config`) — `bootstrap.ldif` adds it.
- The startup `level=error` line "Your LDAP Server supports TLS but you
  don't appear to be utilizing it" is **expected noise**: openldap is
  reachable only from the authelia container on the internal
  `authelia-internal` network (no host ports), so plain `ldap://` carries no
  traffic beyond that bridge, and osixia's self-signed cert would add no
  real security.
- The 4.39.28 rfc2307bis preset group filter ends with `!(!pwdReset=TRUE)`;
  `pwdReset` is undefined in osixia's schema set, so the clause excludes
  EVERY group — sessions get `groups=[]` and every `subject: group:...` rule
  403s (diagnosed via slapd access log, `LDAP_LOG_LEVEL: "128"`). Override:
  `authentication_backend.ldap.groups_filter` (4.39.28 key — `group.filter`
  and `group_filter` are rejected; user-DN placeholder `{dn}` —
  `{user_identifier}` is sent literally). Fixed upstream after 4.39.28.
- No SMTP: `password_reset.disable: true` + filesystem notifier
  (`/config/notifier/notification.txt`).

## Cloudflare Tunnel (cloudflared)

Outbound-only remote access for the **work laptop + partner** without a VPN:
a locally-managed Cloudflare Tunnel publishes **only**
`wanderer.sseifried.link` and `authelia.sseifried.link` (the portal is
required: the wall redirects there and the Access federation login lives
there) to the internet, gated by **Cloudflare Access** with **Authelia OIDC
federation only** (no email-OTP). Compose file: `cloudflared/compose.yaml`.
Unit: `podman-compose@cloudflared` (shared pattern above).

```
Work laptop / partner (public DNS, no VPN)
  │ https://wanderer.sseifried.link
  ▼
Cloudflare Edge ── Access policy (Accept + Authelia IdP login)
  │   └─ unauthenticated → Authelia portal (authelia.sseifried.link, same tunnel)
  ▼
cloudflared container (caddy-proxy) ── tunnel (outbound) ── CF Edge
  │ https://caddy:443 + originServerName (Full strict)
  ▼
Caddy ── forward_auth wall (authelia_session cookie from the federation
  │      login → passes: ONE login end to end)
  ▼
wanderer:3000 (PocketBase OIDC SSO → the Authelia button is silent, see
  "Wanderer SSO")

LAN path unchanged: AdGuard split DNS → Caddy :443 (LE wildcard cert).
```

The tunnel is a long-lived **outbound** connection from the container to the
Cloudflare edge — no host ports, no firewall rules, no ingress to the LAN.
Origin transport: cloudflared → `https://caddy:443` with a per-host
`originServerName` (Full-strict) — the LE wildcard cert is publicly valid,
so no Origin CA cert and no Caddy site changes are needed; an `http://`
ingress would hit Caddy's `:80` redirect and loop at the edge.

### Ingress allowlist doctrine

`cloudflared/config.yml` is the committed, auditable public-exposure
allowlist: **wanderer + authelia ONLY**, fallback `http_status:404`.
`cockpit`/`adguard`/`homepage`/`homeassistant` are deliberately absent —
**never add them** (user decision: admin tools stay LAN/VPN-only). Cockpit's
exclusion is enforced 4-fold: absent from the allowlist, 404 fallback, no
public DNS record (NXDOMAIN from the internet), TLS-only site + PAM.

### Workstation setup (one-time, manual)

The tunnel is created on the **workstation** (the server never receives the
account cert); install `cloudflared` there, then:

```bash
cloudflared tunnel login                      # browser → ~/.cloudflared/cert.pem
cloudflared tunnel create homebase            # → ~/.cloudflared/<uuid>.json
cloudflared tunnel route dns homebase wanderer.sseifried.link
cloudflared tunnel route dns homebase authelia.sseifried.link
```

Save `cert.pem` → Bitwarden item `cloudflared-account-cert`, the credentials
JSON → `cloudflared-tunnel-credentials` (password field, single-line JSON).
`route dns` creates proxied (orange-cloud) CNAMEs — the only public DNS
records this stack ever creates.

### Cloudflare Access setup (dashboard, one-time)

1. Zero Trust (free plan, 2 users): sign up, note the team domain —
   `green-mouse-0fd5.cloudflareaccess.com`.
2. Access → Authentication → **OIDC IdPs**: add "Authelia" — issuer
   `https://authelia.sseifried.link` (discovery), client_id
   `cloudflare-access`, client secret = the RAW value printed by
   `authelia/provision-authelia-secrets.sh` (Bitwarden
   `authelia-oidc-cloudflare-secret`). Requires the portal public → do this
   after the tunnel is up.
3. Access → **Applications**: self-hosted `wanderer.sseifried.link`
   (session duration default 24h).
4. Access **policy** on the app: action **Accept**, usage **Login** with
   the Authelia IdP. No email-allowlist condition (user decision: the gate
   is the Authelia login itself — only authorized LDAP accounts exist),
   no WARP/service tokens, no email-OTP.
5. Zone → SSL/TLS → Edge Certificates → **Always Use HTTPS: on** —
   `http://<published>` requests otherwise reach the origin through the
   tunnel with `X-Forwarded-Proto: http` and the wall 400s them
   (Authelia rejects insecure redirect targets, fail-closed).

### First run (server)

1. Provision the credentials (requires an unlocked Bitwarden CLI):

```bash
cd cloudflared
./provision-cloudflared-secrets.sh
```

   Writes `credentials.json` (gitignored, mode `0600`, chowned to container
   uid 65532 via `podman unshare chown` — the image runs as nonroot uid
   65532 (the `-nonroot` variant was merged into the main tag) and rootless
   Podman maps it to a subuid that cannot read a host-user-owned 0600
   file).

2. Deploy with the shared pattern (unit: `podman-compose@cloudflared`):

```bash
podman-compose systemd
systemctl --user enable --now podman-compose@cloudflared
```

3. Verify:

```bash
podman logs --tail=50 cloudflared_cloudflared_1   # connector registered
```

   Dashboard → Networks → Tunnels → homebase → connector **online**. From a
   public network (no VPN): `dig +short wanderer.sseifried.link` →
   Cloudflare edge IPs; `curl -sI https://wanderer.sseifried.link` → 302 to
   `green-mouse-0fd5.cloudflareaccess.com`; `dig +short
   cockpit.sseifried.link adguard.sseifried.link homepage.sseifried.link
   homeassistant.sseifried.link` → **NXDOMAIN** (cockpit guarantee).

### Partner onboarding

Browser → `https://wanderer.sseifried.link` → Access → Authelia login
(`uid=partner`, password = Bitwarden `authelia-partner-login-password`,
handed out out-of-band) → wall passes → Wanderer login page → **Authelia
button** → account auto-created (username `partner`, own trails — private
instance). After onboarding set `PUBLIC_DISABLE_SIGNUP: "true"` in
`wanderer/compose.yaml`, commit and redeploy — email/password registration
is no longer needed and the app is now internet-published (OIDC logins keep
working; reversible).

### Rollback

Dashboard: delete the public hostname(s) (DNS records) → stop the unit
(`systemctl --user disable --now podman-compose@cloudflared`). Nothing else
changes: the LAN path never depended on the tunnel.

### Federation notes

- **Federation-only**: Authelia down ⇒ remote access down (Access cannot
  authenticate). LAN, VPN, SSH, Cockpit unaffected — break-glass unchanged.
- The portal is internet-published (inherent: the wall redirects + the
  federation login live there). The login page is the public auth surface;
  Authelia `regulation` rate-limits it. `one_factor` kept per user decision —
  flip to `two_factor` with the documented follow-up (enroll TOTP/passkeys).
- Session lifetime: Access 24h vs `authelia_session` 12h/2h inactivity → the
  wall re-prompts at the portal after Authelia expiry. Expected.
- PKCE: the `cloudflare-access` client requires `S256`; if the federation
  test shows Access sends no PKCE, drop `require_pkce`.
- Real client IPs: cloudflared sends `X-Forwarded-For`; Caddy trusts the
  `caddy-proxy` CIDR (`servers { trusted_proxies static 10.89.0.0/24 }` in
  the Caddyfile global block — 2.11 IP-range-source syntax;
  `trusted_proxies_static` is not a 2.11.7 option name) so Authelia
  `regulation` ip-mode bans are per client, not per shared tunnel source.
- `cert.pem` + credentials JSON are account-level secrets: Bitwarden-only,
  0600, gitignored; gitleaks guards the repo.
