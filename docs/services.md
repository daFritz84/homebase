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
   systemd unit (`systemctl --user restart podman-compose@<project>`) — for every project.
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
  Native OIDC via oauth2-proxy is a future option (see [operations.md](operations.md) TODO).

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
> `homepage/config/services.yaml` (AdGuard widget),
> `homeassistant/config/configuration.yaml` (`internal_url`) and
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
podman logs --tail=20 wanderer_search_1   # Meilisearch must come up healthy
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
Compose file: `homeassistant/compose.yaml`. Unit: `podman-compose@homeassistant`
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
`trusted_proxies: [192.168.178.249]`. HA is `network_mode: host` and Caddy
reaches it via the hardcoded host IP, so HA sees the proxy source as the host
IP — **not** the `caddy-proxy` bridge subnet (the old `10.89.0.0/24` value is
wrong here; a stale/missing entry shows up as login failures via the proxy, see
[operations.md](operations.md) troubleshooting).

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
Caddy (wildcard cert)
  ├─ homepage.sseifried.link ──► homepage:3000 (native OIDC gate → Authelia)
  ├─ adguard|homeassistant|wanderer ──► forward_auth authelia:9091 (wall) ──► upstream
  ├─ cockpit.sseifried.link ──► unchanged (PAM + TOTP, no Authelia)
  └─ authelia.sseifried.link ──► authelia:9091 (login + portal + OIDC IdP)

authelia stack: authelia (9091) ── authelia-internal ── openldap (389)
                sqlite db + openldap data in named volumes
```

Policies (`access_control` in `authelia/config/configuration.yml`):
**default deny**; `one_factor` for `group:homebase-admins` on AdGuard,
Home Assistant and Wanderer; no rules for the Authelia portal (its endpoints
are exempt from ACL) or Homepage (no forward_auth — its own OIDC gate
enforces auth: Authelia authorizes the `homepage` OIDC client, and Homepage
admits any identity Authelia authorizes). Cockpit
has **no rule and no forward_auth** — it stays outside Authelia entirely.
Session cookie domain `sseifried.link` → one login, all walled apps (true SSO).
Second factors: TOTP + WebAuthn passkeys, enrolled at
`https://authelia.sseifried.link/portal` — **optional for now**: policies run
`one_factor`; flip the two walled-app rules + the `homepage` OIDC client's
`authorization_policy` to `two_factor` after enrolling.

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
   password into `.env.secret` (gitignored, mode `0600`), plus two more
   entries: the argon2 digest of the Homepage OIDC client secret — as
   `HOMEPAGE_OIDC_CLIENT_SECRET_HASH`, injected into `configuration.yml` by
   the `template` filter (indexed `AUTHELIA_..._CLIENTS_0_...` env overrides
   are NOT supported — 4.39 rejects them), so the committed file keeps its
   placeholder — and the generated Authelia **login password**
   (`LDIF_LOGIN_PASSWORD`, printed on first generation: save it to Bitwarden
   as `authelia-login-password`). It also prints the **raw** OIDC client
   secret for `homepage/.env` as `HOMEPAGE_OIDC_CLIENT_SECRET`. Save
   generated items to Bitwarden.

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
   `.env.secret` via `slappasswd` (the openldap image; the password goes to
   stdin, `-s -`, never argv) into the gitignored
   `config/bootstrap.rendered.ldif`:

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
   Home Assistant → **no second login** (SSO cookie).

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
`uid=partner` (homebase-users) is Phase 2.

### HA wall bypasses (Companion app + Bearer tokens)

The HA Companion app sends no browser cookies, so it cannot pass the wall.
Authelia 4.38+ **removed** the legacy `bypass_credentials`/user-agent ACL
criteria, so the bypass lives in the Caddyfile: a `User-Agent` matcher
(`^(HomeAssistant/|com\.homeassistant\.companion\.android)`) skips
`forward_auth` and proxies straight to HA, which authenticates the app with
its own long-lived access token. Caddy >=2.8 **removed regex from the `header`
matcher** (exact + `*` wildcards only) — the matcher must be `header_regexp`:
a regex in `header` is compared literally, never matches, and the app silently
gets walled. If the app's user-agent string changes, the pattern must follow.

The same reasoning covers Bearer-token API clients (automations, custom cards,
external tools): they send `Authorization: Bearer <long-lived token>` and no
Authelia cookie, so the `@bearer` handle proxies them straight to HA, which
validates its own tokens. HA **webhooks** (`/api/webhook/<id>`, no
`Authorization` header) are not covered by either bypass — call them on the
LAN address (`192.168.178.249:8123`) directly.

**Residual risk (accepted):** `User-Agent` is fully client-controlled, so any
client that can reach `homeassistant.sseifried.link` can spoof the Companion
UA and reach HA's own single-factor login, evading Authelia's `one_factor`
policy and its regulation bans. The wall is an SSO/anti-phishing layer for
browsers, not a hard boundary against a client that deliberately evades it —
on the bypassed paths the HA long-lived tokens are the only credential, so
keep them scoped and revocable.

### Break-glass

Authelia down = walled apps (AdGuard UI, HA, Wanderer) unreachable (502).
Cockpit, Homepage, VPN and SSH are unaffected. Recovery: SSH in →
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
- ACL rules have no `bypass_credentials`/user-agent criteria → HA Companion
  bypass in the Caddyfile (above).
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
  support — so LDIF passwords use `{SSHA}` via `slappasswd` (the openldap
  image, `-s -` on stdin) — `./render-ldif.sh` does this from `.env.secret`
  into the gitignored rendered LDIF. Argon2 digests are only for the OIDC
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
