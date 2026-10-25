# Core Services

Each core service runs from its own `compose.yaml` via `podman-compose` and is managed as a user
systemd unit. Prerequisites (Podman, firewalld, unprivileged ports, linger) are covered in
[host-setup.md](host-setup.md).

- [Autostart: podman-compose systemd units (shared pattern)](#autostart-podman-compose-systemd-units-shared-pattern)
- [Caddy](#caddy)
- [Komodo](#komodo)
- [AdGuard Home (DNS-Server)](#adguard-home-dns-server)
- [Wanderer (Trail Database)](#wanderer-trail-database)

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

## Komodo

Deployment & orchestration platform. Compose file: `komodo/compose.yaml`. Unit: `podman-compose@komodo`.

### First run

Core, Periphery and Mongo read their secrets as plain environment variables from
`komodo/.env.secret` (gitignored, mode `0600`). Provision it from Bitwarden
before the first start:

```bash
bw login
export BW_SESSION="$(bw unlock --raw)"
cd komodo && ./provision-komodo-secrets.sh
```

The script fetches the `komodo-db` (username + password) and `komodo-admin`
items and generates the passkey, webhook and JWT secrets into `.env.secret`.
Run it from the `komodo/` directory — the compose files reference it relative
to the project directory. Re-running regenerates passkey/webhook/JWT, so
restart core **and** periphery together afterwards.

Then deploy with the shared pattern above.

### Github provider

1. Log in to your **Komodo** instance.
2. Navigate to **Settings → Providers → Git Providers**.
   *(Komodo uses git providers to clone private/public repositories via HTTPS.)*
3. Click **Add Git Provider**.
4. Set:
   - **Domain:** `github.com`  
     *(Default domain for GitHub.)*
   - **Use HTTPS:** Enabled  
     *(Komodo supports cloning only via HTTPS, not SSH.)*
   - **Username:** Your GitHub username  
   - **Token:** A GitHub Personal Access Token  
     *(Required for private repos; token must be provided either in core or periphery config.)*
5. Save the provider.

### (Optional) Enable Webhooks

If you want automatic updates on push:

1. Open the resource → **Config → Webhooks** → copy the generated URL.
2. Add it as a webhook in your GitHub repository under  
   **Settings → Webhooks → Add webhook** (Content type: `application/json`, Event: `push`).

### Development workflow

Komodo manages only the runtime (deploying stacks); development happens on the
workstation in a local clone, on a branch, tested with podman-compose directly:

1. **Branch & edit** on the workstation: `git checkout -b <topic>`.
2. **Validate before pushing** — the same checks CI runs:
   - Test a stack locally: `podman-compose up -d` / `podman-compose down` in the
     stack directory (requires the `caddy-proxy` network and the stack's `.env` files)
   - Caddyfile: `podman run --rm --env-file .env homebase-caddy:2.11.7 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`
3. **Commit & push** — the server deploy key is read-only; commits always
   originate from the workstation (see [host-setup.md](host-setup.md#git-deployment)).
4. **Deploy on the server**: `git pull --rebase --autostash`, then restart the
   systemd unit (`systemctl --user restart podman-compose@<project>`) for core
   services, or restart the stack from the Komodo UI for Komodo-managed stacks.
5. **AdGuard drift**: UI changes on the server rewrite `AdGuardHome.yaml` —
   sync the server file back to the workstation, review, commit, push
   (see [operations.md](operations.md)).

## AdGuard Home (DNS-Server)

DNS server with blocking & filtering. Compose file: `adguard-home/compose.yaml`. Unit: `podman-compose@adguard-home`.

No longer managed by Komodo — it runs as a `podman-compose` systemd user unit like Caddy and Komodo
(shared pattern above). It uses `network_mode: host` and binds `:53` (DNS) and `:8095` (web UI),
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
> (AdGuard `reverse_proxy`) and `stacks/homepage/config/services.yaml` (AdGuard widget).
> Rootless containers cannot reach host services by name, so the IP is hardcoded — if the
> static IP ever changes, update both files.
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
dig komodo.sseifried.link
dig homebase.fritz.box
dig +trace komodo.sseifried.link   # public resolution: NXDOMAIN is expected
```

## Wanderer (Trail Database)

Self-hosted trail database ([wanderer](https://github.com/open-wanderer/wanderer)).
Compose file: `stacks/wanderer/compose.yaml`. Komodo-managed stack (like Homepage) —
deployed from the Komodo UI, not a systemd unit.

Three services: `web` (SvelteKit UI — the only one on `caddy-proxy`, alias `wanderer`),
`db` (PocketBase) and `search` (Meilisearch) on the internal `wanderer-internal` network.
No host ports: the UI is served through Caddy at `https://wanderer.sseifried.link`.
The instance is private (`PUBLIC_PRIVATE_INSTANCE: "true"`) — users only see their own trails.

### First run

The steps below run in the stack checkout — on the server that is the Komodo periphery
checkout under `PERIPHERY_ROOT_DIRECTORY`, not the `~/src/homebase` clone.

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

4. Register the Komodo stack: **Stacks → Add Stack → git**, repo `homebase`,
root path `stacks/wanderer`, branch `main` (same as Homepage). Deploy.

5. Verify:

```bash
podman pod ps
curl -k https://wanderer.sseifried.link
podman logs --tail=20 wanderer-search-1   # Meilisearch must come up healthy
```

### Meilisearch upgrades

The `data.ms` format is **not forward-compatible** — a newer engine refuses to
open an older index directory and crash-loops. On a version bump: set
`MEILI_UPGRADE_DB: "true"` on the search service, deploy once (the engine
upgrades `data.ms` in place), then remove the flag and deploy again.
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
