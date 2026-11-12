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
- [Navidrome (Music Streaming)](#navidrome-music-streaming)
- [Jellyfin (Media Server)](#jellyfin-media-server)
- [Stirling PDF (PDF Editor)](#stirling-pdf-pdf-editor)
- [BookOrbit (Reading Space)](#bookorbit-reading-space)
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

### Boot ordering gate (required)

Linger starts the user manager at boot **before the host network is up**. The first
container then creates the rootless netns and pasta copies an address-less, route-less
host config, so `host.containers.internal` (`169.254.1.2`) and all outbound traffic
from bridge containers are dead until the stacks are recreated (see
[operations.md](operations.md) "pasta relay dead after reboot").

The repo tracks a user-scope oneshot gate (`systemd/user/podman-network-online.service`,
waits for a usable default route) plus a drop-in that orders every
`podman-compose@<project>` instance behind it
(`systemd/user/podman-compose@.service.d/network-online.conf`). Install once, as the
service user, from the repo root:

```bash
./systemd/install-user-units.sh
```

Verify:

```bash
systemctl --user is-enabled podman-network-online
systemctl --user show podman-compose@caddy -p After | tr ' ' '\n' | grep podman-network-online
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
  on the old account.
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

## Navidrome (Music Streaming)

Personal music streaming server ([navidrome](https://www.navidrome.org)),
Subsonic-API compatible — clients like Symfonium/dSub stream the library.
Compose file: `navidrome/compose.yaml`. Unit: `podman-compose@navidrome`
(shared pattern above — like Caddy/AdGuard/Homepage/Wanderer).

Single container on `caddy-proxy` (alias `navidrome`), no host ports — served
by Caddy at `https://navidrome.sseifried.link`. The image runs as **root**
(no `USER` directive; `PUID`/`PGID` are ignored by it), so the compose file
applies the upstream-recommended non-root posture: `user: "1000:1000"` +
`ND_ENFORCENONROOTUSER: "true"` (the app itself refuses uid 0). Folders and
port come from the image ENV (`ND_DATAFOLDER=/data`, `ND_MUSICFOLDER=/music`,
`ND_PORT=4533`).

**No Authelia wall, on purpose:** Subsonic API clients send their own Basic
auth per request and can never pass a `forward_auth` cookie wall — Navidrome's
own login is the gate. Exposure is LAN/VPN-only via AdGuard split DNS;
`*.sseifried.link` is already covered by the existing wildcard rewrite, so
AdGuard needs **no change**. `navidrome.sseifried.link` is absent from
`cloudflared/config.yml` — **never add it** (same doctrine as
cockpit/adguard/homepage/homeassistant).

Data that cannot be rebuilt: `navidrome/data/navidrome.db` — users,
playlists, share tokens **and the auto-generated session/password secrets**
live in the SQLite DB (there is no `.env.secret`, no Bitwarden provisioning).
Covered by `backup-navidrome-data.sh` (see
[operations.md](operations.md), "Navidrome data backups"); run it before every
image bump — DB migrations are forward-only.

### First run

The steps below run in the service checkout — on the server that is the
`~/src/homebase` clone.

1. Rootless bind-mount ownership (same ritual as the wanderer uid-1000
   services — container uid 1000 maps into the subuid range, a host-user-owned
   `data/` is not writable for it):

```bash
cd navidrome
mkdir -p data
podman unshare chown 1000:1000 data
```

2. Start and verify (the `caddy-proxy` network must exist —
   `../caddy/ensure_proxy_network.sh`):

```bash
podman-compose up -d
podman exec navidrome_navidrome_1 curl -fsS http://localhost:4533/ping  # -> "." (the body is a single dot)
podman healthcheck run navidrome_navidrome_1                            # exit 0
```

3. Open `https://navidrome.sseifried.link` — the first-run form creates the
   admin account (no `ND_ADMIN_PASSWORD` in any file; the credentials land in
   `navidrome.db`, so back up after this step). The library is the placeholder
   `./music` (empty) — a scan (Settings → Start Scan) completes with zero
   tracks.

4. Deploy with the shared pattern above (unit: `podman-compose@navidrome`):

```bash
podman-compose systemd
systemctl --user enable --now podman-compose@navidrome
```

### Music volume (follow-up)

`./music` is a **placeholder** on the VM disk — do NOT put music there. The
real music volume is a user decision; the plan: NFS export mounted on the VM
(fstab + `x-systemd.automount`), then swap the single `./music:/music:ro`
volume line in `navidrome/compose.yaml` to the mount point. Because the
`podman-compose@navidrome` unit is generated by `podman-compose systemd`, the
mount dependency goes into a drop-in override:
`RequiresMountsFor=<mount point>`. The Jellyfin media volume (CIFS automount,
see below) is the implemented variant of this pattern — a future music share
on the same NAS reuses it. Music files must be world-readable
(NFS `root_squash` → the container uid 1000 reads via `o+r`). Periodic scans
stay disabled by default (`ND_SCANNER_SCHEDULE` = `0`; cron/`@every` syntax) —
new files need a manual scan (Settings → Start Scan) unless the schedule is
set later. The in-container file watcher is on by default
(`ND_SCANNER_WATCHERWAIT` `5s`).

## Jellyfin (Media Server)

Media server ([jellyfin](https://jellyfin.org)) — movies & TV library with
transcoding. Compose file: `jellyfin/compose.yaml`. Unit:
`podman-compose@jellyfin` (shared pattern above).

Single container on `caddy-proxy` (alias `jellyfin`), no host ports — served
by Caddy at `https://jellyfin.sseifried.link`.

**No Authelia wall, on purpose:** Jellyfin API/mobile clients (Infuse,
Swiftfin, …) authenticate with `X-Emby-Token` / `Authorization` headers per
request and can never pass a `forward_auth` cookie wall — Jellyfin's own
login is the gate. Exposure is LAN/VPN-only via AdGuard split DNS;
`*.sseifried.link` is already covered by the existing wildcard rewrite, so
AdGuard needs **no change**. `jellyfin.sseifried.link` is absent from
`cloudflared/config.yml` — **never add it** (same doctrine as
cockpit/adguard/homepage/homeassistant/navidrome). Caddy passes WebSockets
through by default (required by the Jellyfin web client).

**Runs as root, on purpose (no `user:` directive, unlike navidrome):** the
official image has an empty `Config.User` (probe:
`podman image inspect jellyfin/jellyfin:12.4 --format "{{.Config.User}}"` →
empty). Under rootless Podman, container root maps to host `chef`, the only
mapping that can carry chef's supplementary groups to the render node
`/dev/dri/renderD128` (`root:render 660`); a uid-1000 (subuid) process
cannot open it. Consequence: `data/`/`cache/` are host-user-owned — **no
`podman unshare chown` ritual** (homeassistant pattern).

**`group_add: keep-groups` is required for VAAPI:** rootless Podman drops
the process's supplementary groups by default, so the `render` group never
reaches the container — `/dev/dri/renderD128` shows as `nobody:nogroup`
(host `root:render` is unmapped in chef's userns) and ffmpeg fails with
`No VA display found for device /dev/dri/renderD128` (DAC: mode 660,
owner/group unmapped → 65534). `keep-groups` passes chef's groups through:
`render` maps to the unmapped 65534 (`nogroup`) — exactly the node's group —
so group-rw opens it. Verified: `ffmpeg -vaapi_device /dev/dri/renderD128
... hwupload` succeeds on the bundled iHD driver; without the flag it fails.

**VAAPI (Intel Quick Sync):** `devices: [/dev/dri]`. The iGPU is an
**Intel HD Graphics 530 (Skylake, Gen9)** passed through to the VM
(`lspci`: `Intel Corporation HD Graphics 530 (rev 06)`; see
[host-setup.md](host-setup.md) "iGPU passthrough"). Gen9 codec set: H.264,
HEVC 8-bit (encode+decode), MPEG-2, VP8/VP9 low-power decode — **no AV1**
(Gen11+/TGL only). The image ships the Intel VA-API stack inside the
self-contained jellyfin-ffmpeg prefix (probe:
`ls /usr/lib/jellyfin-ffmpeg/lib/dri` → `iHD_drv_video.so` +
`i965_drv_video.so`, plus `libva`/`libva-drm`/`libigdgmm`/`libigfxcmrt`/
`libdrm_intel` in `/usr/lib/jellyfin-ffmpeg/lib`) — the system
`/usr/lib/x86_64-linux-gnu/dri` does NOT exist in the image; ffmpeg finds
its drivers via the bundled prefix, so no extra packages are needed.

**Host prerequisite (one-time):** `chef` must be in the `render` group and
the systemd **user manager** must pick it up — a plain re-login is not
enough for the user manager, reboot the VM (all units autostart, `onboot`):

```bash
sudo usermod -aG render chef
sudo reboot   # user manager + linger restart
```

Verify after reboot: `id chef` must list `render`. Without it the container's
root mapping lacks the group and ffmpeg logs
`/dev/dri/renderD128: Permission denied`.

Data that cannot be rebuilt: `jellyfin/data/` — `jellyfin.xml` (incl. the
VAAPI/transcoding settings), users, password hashes, API keys and the plugin
DB. Covered by `backup-jellyfin-data.sh` (see
[operations.md](operations.md), "Jellyfin data backups"); run it right after
admin creation and **before every image bump** — DB migrations are
forward-only. `cache/` (transcodes, artwork) is rebuildable.

### First run

The steps below run in the service checkout — on the server that is the
`~/src/homebase` clone.

1. Create the dirs (host-user-owned — no chown, see the root-mapping note
   above):

```bash
cd jellyfin
mkdir -p data cache
```

2. Start and verify (the `caddy-proxy` network must exist —
   `../caddy/ensure_proxy_network.sh`):

```bash
podman-compose up -d
podman exec jellyfin_jellyfin_1 curl -fsS http://localhost:8096/   # web root -> 302 to /web/ (login/setup page)
podman healthcheck run jellyfin_jellyfin_1                          # exit 0
ls -l data                                                          # files owned by chef (root→chef mapping)
```

3. Open `https://jellyfin.sseifried.link` — the setup wizard creates the
   admin, language, and the "Movies" + "Shows" libraries; point them at
   `/media/filme` and `/media/serien` (the CIFS automounts — see "Media
   volume" below; a scan completes with zero items while the NAS is offline).
   Disable Jellyfin's own remote connections (Settings → Network): the LAN
   path is Caddy.

4. Enable VAAPI: Dashboard → Playback → Transcoding → Hardware acceleration
   **VA-API**, device `/dev/dri/renderD128`, Intel presets; enable the codecs
   the Gen9 iGPU supports (H.264, HEVC, MPEG-2, VP8/VP9 low-power — no AV1).
   Save, restart the container. Prove it: force a transcode (web player,
   quality below source) — the dashboard "Now Playing" shows
   `(va-api)` and the CPU stays idle-ish.

5. Deploy with the shared pattern above (unit: `podman-compose@jellyfin`):

```bash
podman-compose systemd
systemctl --user enable --now podman-compose@jellyfin
```

6. Back up right after admin creation (the DB now holds the secrets):
   `./backup-jellyfin-data.sh`.

### Media volume (CIFS automount)

The media lives on the TrueNAS box as two subfolders of the SMB share `share`,
mounted **on demand** on the host: mount on first access (autofs), host-side
copies unmount after 60 s idle. The container-side lifecycle has a kernel-6.12
caveat that limits NAS power management — see "Verified mount lifecycle"
below. Host-side setup (packages, mDNS, firewalld `mdns` rule, credentials,
fstab, automount units): [host-setup.md](host-setup.md)
"NAS media mounts (CIFS automount)".

- fstab sources `//truenas.local/share/{Filme,Serien}` →
  `/srv/media/{filme,serien}` (CIFS, `ro`, `uid=1000,gid=1000` → ownership is
  `chef`, which the rootless container's root maps to;
  `x-systemd.automount` + `x-systemd.idle-timeout=60` +
  `x-systemd.mount-timeout=30`, `nofail` + `noauto`).
- `jellyfin/compose.yaml` binds them read-only and **rshared**:
  `/srv/media/filme:/media/filme:ro,rshared`,
  `/srv/media/serien:/media/serien:ro,rshared`. Volume changes require
  **container recreation** (`podman-compose up -d --force-recreate`), not a
  unit restart — binds are baked at container creation.
- **`rshared` (kernel ≥ 6.12):** the CIFS `upcall_target=app` mechanism
  mounts the share on-demand in the *accessing* process's mount namespace.
  `rshared` makes the container-triggered mount visible in the host mount
  table (so the host autofs expire manages the host copy and host tooling
  sees it); host-side mounts are visible in the container.
- **Verified mount lifecycle (kernel 6.12 + rootless Podman, 2026-11-09):**
  the container's own mount copy **persists for the container's lifetime**.
  Nothing can unmount it: the autofs expire's kernel shrink path is
  namespace-local (unmounts only the host copy), a plain host `umount`
  reaches only the host copy (the app-target mount is not a propagation
  peer), and `nsenter` umount from inside the container's namespace is
  refused on the autofs-managed dentry. Consequences:
  - The NAS's SMB session stays alive while Jellyfin runs (CIFS
    `echo_interval=60` is a session keepalive, no disk I/O) → the NAS
    **cannot fully power off** while the jellyfin unit is up.
  - **Disk spin-down still works** via TrueNAS idle disk settings: an idle
    session generates no disk I/O; the first access after spin-down pays
    the disk wake (~5–10 s) on top of the ~1–2 s mount.
  - Full NAS idle (no session): stop the service —
    `systemctl --user stop podman-compose@jellyfin` — the container's
    namespace and its mount copies go away.
  - Host-side accesses (`ls /srv/media/...`) keep working with the 60 s
    idle unmount; the container's persistent copy is unaffected.
- **Drop-in (required):** the `podman-compose@jellyfin` unit is generated by
  `podman-compose systemd`, so the mount dependency goes into
  `~/.config/systemd/user/podman-compose@jellyfin.service.d/media-mounts.conf`:

```ini
[Unit]
RequiresMountsFor=/srv/media/filme /srv/media/serien
```

  then `systemctl --user daemon-reload`. The `.automount` units are active
  regardless of NAS state, so jellyfin is never gated on the NAS; first
  access from inside the container triggers the mount via the kernel autofs
  upcall.
- Credentials: Bitwarden item `TrueNAS SMB` → `./provision-nas-credentials.sh`
  (uses sudo → run over `ssh -t`) → `/etc/samba/credentials.nas`
  (root:root 0600).
- **Jellyfin library setup (one-time, browser):** Dashboard → Libraries →
  **Movies → `/media/filme`**, **Series → `/media/serien`**; run a scan; then
  `./backup-jellyfin-data.sh` (`jellyfin.xml` now holds the library config).
- **CIFS inotify caveat:** real-time file monitoring does not work over CIFS
  (no inotify events from the NAS) → enable **periodic library scans** (e.g.
  daily). Every scan performs disk I/O and spins the NAS disks up (the
  container mount is persistent, see "Verified mount lifecycle") — pick the
  interval deliberately (see [operations.md](operations.md)
  "NAS media mounts").
- First access after an idle unmount costs ~1–2 s (CIFS mount) plus the
  TrueNAS disk wake (~5–10 s) when the disks have spun down — expected,
  not a fault.

## Stirling PDF (PDF Editor)

Self-hosted PDF editor/processor
([Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF)) — merge,
split, OCR, sign, convert. Compose file: `stirling-pdf/compose.yaml`. Unit:
`podman-compose@stirling-pdf` (shared pattern above).

Single container on `caddy-proxy` (alias `stirling`), container port 8080,
no host ports — served by Caddy at `https://stirling.sseifried.link`.

**No Authelia wall, on purpose:** Stirling's REST API authenticates with
per-request API keys (`X-API-Key`) that can never pass a `forward_auth`
cookie wall (navidrome/jellyfin doctrine). Stirling v3 is a **native
Authelia OIDC client** (Home Assistant pattern, see below) — the app's own
login gates access. Exposure is LAN/VPN-only via AdGuard split DNS;
`*.sseifried.link` is already covered by the existing wildcard rewrite, so
AdGuard needs **no change**. `stirling.sseifried.link` is absent from
`cloudflared/config.yml` — **never add it** (same doctrine as
cockpit/adguard/homepage/homeassistant/navidrome/jellyfin).

**Native Authelia OIDC client:** the `stirling-pdf` client is registered in
`authelia/config/configuration.yml` (confidential + PKCE S256, argon2 digest
from `authelia/.env.secret` via the template filter,
`STIRLING_OIDC_CLIENT_SECRET_HASH`); the app side is the `SECURITY_OAUTH2_*`
env in `stirling-pdf/compose.yaml` (issuer `https://authelia.sseifried.link`
with discovery, clientid `stirling-pdf`, the RAW client secret from
`.env.secret`). The OIDC callback URL is fixed by Spring Security:
`https://stirling.sseifried.link/login/oauth2/code/stirling` (provider name
`stirling`). `useAsUsername=preferred_username` maps the LDAP uid
(`sseifried`) to the local username; `autoCreateUser` creates the account on
first login. `loginMethod=all` keeps the app's password form reachable at
`/login?all` (break-glass), `ssoAutoLogin=true` sends browsers straight to
Authelia — one portal login end-to-end. No `access_control` rule: rules
apply only to walled (forward-auth) apps.

**Root entrypoint, app drops to uid 1000 — NO `user:` directive:** the
image's `Config.User` is empty (probe 2026-11-08: `podman image inspect
docker.io/stirlingtools/stirling-pdf:3.3.0 --format '{{.Config.User}}'`
→ empty) and the s6 entrypoint **must start as root**: with
`user: "1000:1000"` it dies crash-looping on `ln: failed to create
symbolic link '/usr/local/bin/diagnostics': Permission denied` (observed
2026-11-08, first start). The entrypoint writes `/usr/local/bin` symlinks
and chowns the app dirs as root, then setuid's the Java app to
`PUID`/`PGID` (image ENV default 1000, pinned in `compose.yaml`). Under
rootless Podman container root maps to host `chef` (jellyfin mapping);
the app process runs as uid 1000 = subuid range — chown `data/` once
before first start (`podman unshare chown -R 1000:1000 data`, navidrome
ritual).

Secrets: `stirling-pdf/.env.secret` (gitignored, 0600, provisioned by
`provision-stirling-pdf-secrets.sh` from Bitwarden) —
`SECURITY_INITIALLOGIN_USERNAME/PASSWORD` preset the first admin (the
upstream default `admin`/`stirling` must never survive; the keys are
**ignored once users exist**, so set them before the first start) and
`SECURITY_OAUTH2_CLIENTSECRET` (the RAW OIDC client secret; the argon2
digest lives in `authelia/.env.secret` — same Bitwarden item
`authelia-oidc-stirling-pdf-secret`).

Data that cannot be rebuilt:

| Path | Content |
| --- | --- |
| `stirling-pdf/data/configs/` | `settings.yml`, **built-in user DB**, nightly DB backups, generated keys |
| `stirling-pdf/data/storage/` | user-saved files (app "saved files" feature, on by default) |

`data/logs` is rebuildable. Covered by `backup-stirling-pdf-data.sh` (see
[operations.md](operations.md), "Stirling PDF data backups"); run it right
after admin/account setup and **before every image bump** — DB migrations
are forward-only.

Non-secret settings live in `compose.yaml` as env (every env key maps to a
`settings.yml` key): `SYSTEM_ENABLEANALYTICS=false` kills the PostHog/Scarf
telemetry; `SYSTEM_BACKENDURL`/`SYSTEM_FRONTENDURL` must match the public
URL. Memory limit **4g** (upstream recommendation): the JVM heap defaults to
~25% of the limit, and the LibreOffice/OCR subprocesses run **outside** the
JVM — watch for OOM-kills on large scans and raise the limit if needed.
Free plan: 5 users max, OIDC on every plan.

### First run

The steps below run in the service checkout — on the server that is the
`~/src/homebase` clone.

1. Probe + dirs + chown (the `caddy-proxy` network must exist —
   `../caddy/ensure_proxy_network.sh`):

```bash
cd stirling-pdf
podman pull docker.io/stirlingtools/stirling-pdf:3.3.0
podman image inspect docker.io/stirlingtools/stirling-pdf:3.3.0 --format '{{.Config.User}}'  # probed 2026-11-08: empty (root) — see the uid note above
free -h  # probed 2026-11-08: 15 GiB total, ~13 GiB available — 4g limit has headroom
mkdir -p data/configs data/logs data/customFiles data/pipeline data/storage data/tessdata
podman unshare chown -R 1000:1000 data
```

2. Provision secrets (Bitwarden unlocked). The OIDC client must exist in
   Authelia **before** Stirling starts (issuer discovery at startup):
   re-run `../authelia/provision-authelia-secrets.sh` (writes
   `STIRLING_OIDC_CLIENT_SECRET_HASH`), then **`podman-compose up -d
   --force-recreate`** in `authelia/` (new `.env.secret` key — a unit
   restart does NOT re-read env), verify the portal is healthy, then:

```bash
cd ../stirling-pdf && ./provision-stirling-pdf-secrets.sh
```

3. Start and verify:

```bash
podman-compose up -d
podman exec stirling-pdf_stirling-pdf_1 curl -fsS http://localhost:8080/api/v1/info/status  # JSON (no sign-in endpoint)
podman healthcheck run stirling-pdf_stirling-pdf_1                                          # exit 0
podman exec stirling-pdf_stirling-pdf_1 ls /usr/share/tessdata  # probe: see the tessdata note below
```

4. Caddy last: validate + restart `podman-compose@caddy`. Verify:

```bash
curl -k https://stirling.sseifried.link  # -> 302 to /login (SSO auto-login -> Authelia portal)
```

5. Browser: open `https://stirling.sseifried.link` → Authelia portal (2FA)
   → lands in Stirling, account `sseifried` auto-created. Break-glass:
   `/login?all` → `admin` / Bitwarden `stirling-pdf-admin-password`; as
   admin, promote `sseifried` to **Admin** (Settings → Workspace → Users).

6. Deploy with the shared pattern above (unit: `podman-compose@stirling-pdf`):

```bash
podman-compose systemd
systemctl --user enable --now podman-compose@stirling-pdf
```

7. Back up right after account setup (configs/ now holds keys + user DB):
   `./backup-stirling-pdf-data.sh`.

8. Homepage: the card appears; restart `podman-compose@homepage` (config is
   bind-mounted).

**tessdata probe:** if `ls /usr/share/tessdata` is empty and OCR fails,
drop the `./data/tessdata:/usr/share/tessdata` bind — the mount can hide
the image's bundled `eng.traineddata`. Add `deu.traineddata` to that dir
for German OCR.

### Upgrade procedure

Pin the tag in `compose.yaml`; `./backup-stirling-pdf-data.sh` **before
every bump** (DB migrations are forward-only); `podman-compose pull` + unit
restart.

### Troubleshooting

- **ssoAutoLogin × loginMethod contradiction:** the upstream OAuth-SSO docs
  say auto-login redirects **only when `loginMethod` is `oauth2`/`saml2`**,
  while the v3.3.0 release notes say it works with password login enabled.
  The stack ships `loginMethod=all` + `ssoAutoLogin=true` and step 4 expects
  `302 → Authelia`. If it returns a 200 login page instead: set
  `SECURITY_LOGINMETHOD=oauth2` and **verify `/login?all` still reaches the
  password form** (release notes promise it) before accepting — never "fix"
  the missing redirect by removing the break-glass form.
- **Spring↔Authelia quirks:** if the callback 400s on PKCE, drop
  `require_pkce` from the client; if a claim is null ("Attribute value for
  … cannot be null"), set `SECURITY_OAUTH2_DEBUGLOGGING=true` once, inspect
  the claims, pick a present `useAsUsername`, turn it off.
  `preferred_username` arrives via Authelia's UserInfo endpoint (Spring
  merges it) — no `claims_policy` needed.
- **Issuer down at Stirling startup** → startup issuer error/crash-loop;
  `restart: unless-stopped` self-heals once authelia is up
  (authelia-before-stirling ordering, same as walled apps).
- **`SECURITY_INITIALLOGIN_*` are ignored once users exist** — set them
  before the first start.
- **API-key clients work** (proves no wall): create a key in Settings,
  `curl -H "X-API-Key: …" -F "file=@x.pdf" https://stirling.sseifried.link/api/v1/...`.

## BookOrbit (Reading Space)

Self-hosted reading space ([BookOrbit](https://bookorbit.app),
[repo](https://github.com/bookorbit/bookorbit), AGPL-3.0) — ebooks,
audiobooks, comics, PDFs. Compose file: `bookorbit/compose.yaml`. Unit:
`podman-compose@bookorbit` (shared pattern above).

**No Authelia wall, on purpose:** OPDS/KOReader/Kobo clients send their own
credentials per request (feed auth, device tokens) and can never pass a
`forward_auth` cookie wall — BookOrbit's own
[auth-proxies docs](https://bookorbit.app/auth-proxies/) document the
failure (navidrome/jellyfin/stirling doctrine). BookOrbit is a **native
Authelia OIDC client** (stirling/HA pattern, see "BookOrbit SSO" below) —
the app's own login gates access. Exposure is LAN/VPN-only via AdGuard
split DNS; `*.sseifried.link` is already covered by the existing wildcard
rewrite, so AdGuard needs **no change**. `bookorbit.sseifried.link` is
absent from `cloudflared/config.yml` — **never add it** (same doctrine as
cockpit/adguard/homepage/homeassistant/navidrome/jellyfin/stirling-pdf).

**Topology:** `app` + `postgres`; only `app` joins `caddy-proxy` (alias
`bookorbit`, container port 3000), postgres stays on the internal
`bookorbit-internal` network. No host ports — served by Caddy at
`https://bookorbit.sseifried.link`. podman-compose names:
`bookorbit_app_1`, `bookorbit_postgres_1`. podman-compose ignores
`depends_on: condition: service_healthy` (start ordering only) — on first
start the app may crash-loop ~30s until postgres answers;
`restart: unless-stopped` self-heals (authelia/openldap precedent).

**Root entrypoint, app drops to uid 1000 — NO `user:` directive:** the app
entrypoint starts as root (`BOOKORBIT_FIX_PERMISSIONS=true`, pinned
explicitly — upstream default) and repairs `/data` ownership to PUID/PGID
1000 at startup (caps `CHOWN`/`DAC_OVERRIDE`/`FOWNER`/`SETGID`/`SETUID`),
then drops to uid 1000. `read_only: true` rootfs + tmpfs `/tmp` (upstream
posture): if the app needs to write outside `/data` and `/tmp` (watch the
first-start logs for EACCES/EROFS), drop `read_only` and **record the
deviation here** (what failed, which path, why the drop is required) — not
an undocumented compose edit.

Secrets: `bookorbit/.env.secret` (gitignored, 0600, provisioned by
`provision-bookorbit-secrets.sh` from Bitwarden):

| Key | Bitwarden item | Notes |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | `bookorbit-postgres-password` | rotation needs `ALTER USER` in the running DB — the image applies the password only at first init of an empty data dir |
| `JWT_SECRET` | `bookorbit-jwt-secret` | rotation invalidates all sessions (everyone logged out) |
| `SETUP_BOOTSTRAP_TOKEN` | `bookorbit-setup-token` | gates the one-time setup wizard — keep it in Bitwarden after first use |

Data that cannot be rebuilt:

| Path | Content |
| --- | --- |
| `bookorbit/data/postgres/` | pgvector DB: users, libraries, reading progress, highlights, OIDC links |
| `bookorbit/data/app/` | covers, Book Dock staging, derived data (partially rebuildable via rescan) |

Covered by `backup-bookorbit-data.sh` (see
[operations.md](operations.md), "BookOrbit data backups"); run it right
after setup and **before every image bump** — DB migrations are
forward-only. The `books/` library volume is NOT covered (same as
navidrome music/ / jellyfin media/).

### Ownership

- `books/` must be writable by container uid 1000 (uploads/Book Dock
  finalize): `podman unshare chown 1000:1000 books` once before first
  start (navidrome ritual).
- `data/app` is **auto-repaired** at every start by
  `BOOKORBIT_FIX_PERMISSIONS` — no chown ritual needed.
- `data/postgres` is chef-owned: the postgres image runs as root and
  rootless Podman maps container root to host `chef` (jellyfin mapping) —
  no chown.

### First run

The steps below run in the service checkout — on the server that is the
`~/src/homebase` clone.

1. **Authelia first** (the OIDC client must exist before BookOrbit's
   provider test): re-run `../authelia/provision-authelia-secrets.sh`
   (writes `BOOKORBIT_OIDC_CLIENT_SECRET_HASH`; save a generated
   `authelia-oidc-bookorbit-secret` to Bitwarden), validate the config
   offline, then **`podman-compose up -d --force-recreate`** in
   `authelia/` (new `.env.secret` key — a unit restart does NOT re-read
   env), verify the portal is healthy. If validation rejects the
   `bookorbit://oauth2-callback` custom scheme, DROP that redirect URI
   (iOS app out of scope) and re-validate — never skip validation.
2. Dirs + books chown (the `caddy-proxy` network must exist —
   `../caddy/ensure_proxy_network.sh`):

```bash
cd bookorbit
mkdir -p data/app data/postgres books
podman unshare chown 1000:1000 books
```

3. Provision secrets (Bitwarden unlocked):

```bash
./provision-bookorbit-secrets.sh
```

4. Start and verify (expect ~30s app crash-loop until postgres is healthy):

```bash
podman-compose up -d
podman healthcheck run bookorbit_postgres_1                      # exit 0
podman exec bookorbit_app_1 sh -c 'command -v curl wget'         # probe: fills the compose.yaml healthcheck note
```

5. App image probe (done 2026-11-12, first start): the image ships busybox
   `wget`, **no curl**; `/api/health` 404s, `/` is 200. Healthcheck added to
   `compose.yaml` (`CMD-SHELL wget -q -O /dev/null http://127.0.0.1:3000/` —
   127.0.0.1, not `localhost`: the app listens IPv4-only and busybox wget
   resolves `::1` first → connection refused).
6. Caddy last: validate + restart `podman-compose@caddy`. Verify:

```bash
curl -k https://bookorbit.sseifried.link              # -> app HTML (200)
curl -kI https://bookorbit.sseifried.link/api/v1/opds # -> 401 + www-authenticate (device auth reaches the app — proves no wall; BookOrbit's own verification recipe)
```

7. Browser: open `https://bookorbit.sseifried.link` → setup wizard → paste
   `SETUP_BOOTSTRAP_TOKEN` (read from `.env.secret` on the server, never
   print) → create admin.
8. OIDC provider (in-app): Settings → OIDC/SSO → Add Provider — slug
   `authelia`, issuer `https://authelia.sseifried.link`, client ID
   `bookorbit`, client secret = RAW value (Bitwarden
   `authelia-oidc-bookorbit-secret`), scopes `openid profile email` →
   **Test** must show Connected → enable **Auto-provision users** +
   **Allow local account linking** → save.
9. Link + verify SSO: log out → login via the Authelia button → the admin
   account is linked by `preferred_username` (`sseifried`) → one portal
   login end-to-end. Keep the password as break-glass.
10. Library: create a library pointing at `/books` (picker root is
    `/books`); the scan finds 0 books (placeholder).
11. Deploy with the shared pattern above (unit: `podman-compose@bookorbit`)
    and back up (the DB now holds users + OIDC links):

```bash
podman-compose systemd
systemctl --user enable --now podman-compose@bookorbit
./backup-bookorbit-data.sh
```

12. Homepage: the card appears; restart `podman-compose@homepage` (config
    is bind-mounted).

### BookOrbit SSO (Authelia OIDC)

BookOrbit is a native Authelia OIDC client — the provider is configured
**in-app** (Settings → OIDC/SSO), like Wanderer's PocketBase UI: the RAW
client secret is pasted into the app, never stored in env. The `bookorbit`
client is registered in `authelia/config/configuration.yml` (confidential
+ PKCE S256, `authorization_policy: two_factor`, argon2 digest from
`authelia/.env.secret` via the template filter,
`BOOKORBIT_OIDC_CLIENT_SECRET_HASH`). Redirect URIs:
`https://bookorbit.sseifried.link/oauth2-callback` (browser) +
`bookorbit://oauth2-callback` (custom scheme for the BookOrbit iOS app's
in-app OIDC login — exact per docs, do not modify; drop it if Authelia's
config validator rejects the scheme). `OIDC_ALLOW_LOCAL_ISSUERS=true` is
required: the issuer (`authelia.sseifried.link`) resolves to the LAN IP
from the server and the app's discovery refuses private addresses without
the flag (the app reaches :443 through the firewalld-opened port, stirling
precedent). Auto-provision creates accounts on first login; **Allow local
account linking** links the OIDC identity to the existing local admin by
`preferred_username` (`sseifried`). The app's password form stays
break-glass (`DISABLE_LOCAL_AUTH` stays false). No `access_control` rule:
rules apply only to walled (forward-auth) apps.

Troubleshooting:

- **Token endpoint method:** if the token exchange fails, read the
  **Authelia log** for the method-mismatch line (cloudflare-access
  precedent: "request … using 'client_secret_basic', client configured for
  'client_secret_post'") and pin the observed
  `token_endpoint_auth_method` — not trial-and-error UI clicks.
- **Claims delivery:** Authelia 4.39's minimal ID token carries no email
  (the cloudflare-access client needed a `claims_policy` for exactly this
  — the `configuration.yml` claims_policies block). If the BookOrbit OIDC
  login fails with null claims ("Your account has not been set up" /
  missing email), add a `claims_policy` for the `bookorbit` client putting
  `email`, `email_verified`, `preferred_username` in the ID token
  (cloudflare-access precedent) — verify with BookOrbit's **Preview
  Claims** button before and after.

### Books volume (follow-up)

`./books` is a **placeholder** on the VM disk — do NOT put the library
there. The real books volume is a user decision; the plan: NFS export
mounted on the VM (fstab + `x-systemd.automount`), then swap the
`./books:/books` volume line in `bookorbit/compose.yaml` to the mount
point (navidrome music plan; the Jellyfin CIFS automount is the
implemented variant). World-readable is enough for scanning (NFS
`root_squash` → the container uid 1000 reads via `o+r`); uploads/Book Dock
finalization needs write access — NFS permission work, documented
follow-up (same as navidrome/jellyfin).

### Upgrade procedure

Pin the app tag in `compose.yaml` (ghcr tags have no `v` prefix);
`./backup-bookorbit-data.sh` **before every bump** (DB migrations are
forward-only); `podman-compose pull` + unit restart.
`pgvector/pgvector:pg18` is a **rolling major tag** — no finer pin exists
upstream; a PG major bump refuses to open an old data dir (upstream
documents the dump/restore path; staying on pg18 is fine).

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
**default deny**; `two_factor` for `group:homebase-admins` on AdGuard and
Wanderer (the internet-published app — admins-only since the partner
account was removed, 2026-11-08); no rules for the Authelia
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
`scopes: openid/email/profile`). Second factors: **enforced** — every rule
and all four OIDC clients run `two_factor`: a **WebAuthn passkey stored in
Bitwarden** (primary, registered from the desktop Chrome/Edge Bitwarden
extension; asserted via the vault on mobile) plus a **TOTP backup factor**,
enrolled in the login's 2FA step — see "MFA enrollment".
`enable_passkey_login` stays false: login remains password + second factor,
not passwordless. Passkeys work through the tunnel: rp_id `sseifried.link`,
real domain. Recovery: [operations.md](operations.md), "Authelia MFA
recovery".

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
   keeps its placeholders — and the generated Authelia **login password**
   (`LDIF_LOGIN_PASSWORD` for `uid=sseifried`, printed on first generation:
   save it to Bitwarden as `authelia-login-password`). It also
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
   (the 2FA step of a walled-app login offers TOTP + passkey registration,
   see "MFA enrollment"), open AdGuard → lands back authenticated; open
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
dn: cn=homebase-admins,ou=groups,dc=sseifried,dc=link
changetype: modify
add: member
member: uid=<uid>,ou=users,dc=sseifried,dc=link
EOF
```

Password changes = re-render (`./render-ldif.sh`) + `ldapmodify`
(`replace: userPassword` with the freshly rendered `{SSHA}` hash).

### MFA enrollment

Two factors are enforced (`two_factor` on all walled-app rules + all four
OIDC clients). The portal console offers device registration **only when a
`two_factor` policy applies to the session** — with zero registered methods
the **login's 2FA step** presents the registration prompt (the portal's
"Two factor authentication" page alone just lists the 2FA-protected apps,
it registers nothing). Enrollment therefore happens in the login flow:
open a walled app (e.g. `https://adguard.sseifried.link`), log in
(`uid=sseifried`, password = Bitwarden `authelia-login-password`), and at
the method-selection step choose **register a device**:

- **Passkey (primary):** desktop Chrome/Edge with the Bitwarden extension
  (vault unlocked, WebAuthn/passkey support enabled in the extension
  settings). Choose the WebAuthn security-key registration → description
  `Bitwarden`. Device registration requires **elevation** (4.38+): a
  one-time code is sent via the notifier — with the filesystem notifier it
  lands in `authelia/config/notifier/notification.txt` on the server. Open
  a second SSH window and `tail -f` that file **before** starting the
  ceremony (the elevation OTP TTL is ~2 minutes), submit the code promptly,
  and the browser WebAuthn picker offers **Bitwarden** — the credential is
  created inside the vault (discoverable + backup-eligible, so the mobile
  Bitwarden app can assert it after vault sync).
- **TOTP (backup):** choose the one-time-password registration → elevation
  (same OTP mechanism) → scan the QR with an authenticator app → **save the
  secret to a Bitwarden item** (`authelia-totp-sseifried`, per the existing
  convention) → confirm the code. Losing the passkey → log in with TOTP;
  losing both → CLI factor reset, see [operations.md](operations.md),
  "Authelia MFA recovery".

With factors enrolled and the `two_factor` policies active, the portal
console (avatar menu → Two factor authentication) lists the protected apps
and offers device management (register more / delete — deletes also require
elevation, OTP to the same notifier file).

Config notes (`webauthn:` in `configuration.yml`):
`attestation_conveyance_preference: 'none'` (Bitwarden self-attests); the
FIDO metadata service stays **disabled** (the Bitwarden AAGUID is not in
MDS3 — enabling `validate_entry` would likely reject registration);
`prohibit_backup_eligibility` must stay false (Bitwarden passkeys are
synced/backup-eligible). `enable_passkey_login` stays false: login remains
password + second factor, not passwordless.

Verify server-side: `authelia storage user webauthn list sseifried` (CLI
pattern in [operations.md](operations.md), "Authelia MFA recovery"; 4.39 has
no `totp list` — check TOTP in the portal UI). After enrollment run
`./backup-authelia.sh` — the sqlite DB now holds the irreplaceable factors.

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
  component **reject** identities in neither group.
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
`systemctl --user restart podman-compose@authelia`. Lockout guard: the
passkey lives in the **Bitwarden vault** and the TOTP secret in a Bitwarden
item (`authelia-totp-sseifried`), the factor records in the sqlite DB, users
in LDAP — the factors DB and users are covered by `backup-authelia.sh`, the
`AUTHELIA_STORAGE_ENCRYPTION_KEY` that decrypts the factors DB is
**Bitwarden-only** (not in the archive): a restore needs
`./provision-authelia-secrets.sh` (unlocked vault) to recreate
`.env.secret`, see [operations.md](operations.md), "Authelia backups".
Losing both factors → [operations.md](operations.md), "Authelia MFA
recovery" (SSH CLI reset); SSH, Cockpit and the HA break-glass form stay
outside Authelia, so lockout is never total.

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

Outbound-only remote access for the **work laptop** without a VPN:
a locally-managed Cloudflare Tunnel publishes **only**
`wanderer.sseifried.link` and `authelia.sseifried.link` (the portal is
required: the wall redirects there and the Access federation login lives
there) to the internet, gated by **Cloudflare Access** with **Authelia OIDC
federation only** (no email-OTP). Compose file: `cloudflared/compose.yaml`.
Unit: `podman-compose@cloudflared` (shared pattern above).

```
Work laptop (public DNS, no VPN)
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
`cockpit`/`adguard`/`homepage`/`homeassistant`/`navidrome`/`jellyfin`/
`stirling` are deliberately absent — **never add them** (user decision:
admin tools stay LAN/VPN-only; navidrome/jellyfin/stirling additionally
gate on their own app logins, which a cookie wall could not serve).
Cockpit's exclusion is enforced 4-fold: absent from the allowlist, 404
fallback, no public DNS record (NXDOMAIN from the internet), TLS-only site
+ PAM.

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
3. Access → **Applications**: self-hosted public hostname
   `wanderer.sseifried.link` (session duration default 24h), identity
   provider: **Authelia only**, **Apply instant authentication: on**
   (single IdP → browsers redirect straight to the Authelia login, no
   Cloudflare login page).
4. Access **policy** on the app: action **Accept**, usage **Login** with
   the Authelia IdP, condition: **email domain `@sseifried.link`** — the
   only LDAP `mail` domain (single-user stack; the partner's `@gmx.at`
   address left with the account). No per-address allowlist, no
   WARP/service tokens, no email-OTP: the gate is the Authelia login
   itself (now `two_factor`) — the domain condition only mirrors the
   directory.
5. Zone → SSL/TLS → Edge Certificates → **Always Use HTTPS: on** —
   `http://<published>` requests otherwise reach the origin through the
   tunnel with `X-Forwarded-Proto: http` and the wall 400s them
   (Authelia rejects insecure redirect targets, fail-closed).

> **The Access application IS the gate:** deleting the app (or its policy)
> leaves the published tunnel hostname reachable by anyone — the tunnel
> route alone gates nothing; only the Authelia wall stays (observed
> 2026-11-08: app absent → unauthenticated edge requests hit the origin
> wall directly, no `cdn-cgi/access/login` challenge). Verify after any
> dashboard change: `curl -sI https://wanderer.sseifried.link` (public
> path) → 302 to `green-mouse-0fd5.cloudflareaccess.com/cdn-cgi/access/login/...`.

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

### Rollback

Dashboard: delete the public hostname(s) (DNS records) → stop the unit
(`systemctl --user disable --now podman-compose@cloudflared`). Nothing else
changes: the LAN path never depended on the tunnel.

### Federation notes

- **Federation-only**: Authelia down ⇒ remote access down (Access cannot
  authenticate). LAN, VPN, SSH, Cockpit unaffected — break-glass unchanged.
- The portal is internet-published (inherent: the wall redirects + the
  federation login live there). The login page is the public auth surface;
  Authelia `regulation` rate-limits it. Second factors are **enforced**
  (`two_factor` on every rule and OIDC client — Bitwarden passkey + TOTP
  backup, see "MFA enrollment").
- Session lifetime: Access 24h vs `authelia_session` 12h/2h inactivity → the
  wall re-prompts at the portal after Authelia expiry. Expected.
- PKCE: the `cloudflare-access` client requires `S256`; if the federation
  test shows Access sends no PKCE, drop `require_pkce`.
- Claims hydration: Access reads claims from the **ID token** and never calls
  the UserInfo endpoint (known CF bug — Authelia guide
  `integration/openid-connect/clients/cloudflare-zerotrust/`, tested
  v4.39.28). 4.39's minimal ID token carries no email, so the federation
  login fails with "User email was not returned" unless the client keeps
  `claims_policy: 'cloudflare-access'` (id_token: `email`, `email_verified`,
  `preferred_username` — the documented escape hatch, PR #61). Do not remove.
- Real client IPs: cloudflared sends `X-Forwarded-For`; Caddy trusts the
  `caddy-proxy` CIDR (`servers { trusted_proxies static 10.89.0.0/24 }` in
  the Caddyfile global block — 2.11 IP-range-source syntax;
  `trusted_proxies_static` is not a 2.11.7 option name) so Authelia
  `regulation` ip-mode bans are per client, not per shared tunnel source.
- `cert.pem` + credentials JSON are account-level secrets: Bitwarden-only,
  0600, gitignored; gitleaks guards the repo.
