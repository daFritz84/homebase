# Core Services

Each core service runs from its own `compose.yaml` via `podman-compose` and is managed as a user
systemd unit. Prerequisites (Podman, firewalld, unprivileged ports, linger) are covered in
[host-setup.md](host-setup.md).

- [Autostart: podman-compose systemd units (shared pattern)](#autostart-podman-compose-systemd-units-shared-pattern)
- [Caddy](#caddy)
- [Komodo](#komodo)
- [AdGuard Home (DNS-Server)](#adguard-home-dns-server)

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

Create the shared external network that Caddy and every proxied stack join
(`caddy-proxy` is declared `external: true` in all compose files, so a fresh
`podman-compose up` fails without it):

```bash
./caddy/ensure_proxy_network.sh
```

Then deploy with the shared pattern above (unit: `podman-compose@caddy`).

## Komodo

Deployment & orchestration platform. Compose file: `komodo/compose.yaml`. Unit: `podman-compose@komodo`.

### First run

Core and Periphery mount seven secret files from `komodo/.secrets/` (gitignored).
Provision them from Bitwarden before the first start:

```bash
bw login
export BW_SESSION="$(bw unlock --raw)"
cd komodo && ./provision-komodo-secrets.sh
```

The script fetches the `komodo-db` (username + password) and `komodo-admin`
items and generates the passkey, webhook and JWT secrets. Run it from the
`komodo/` directory — it writes to `.secrets/` relative to the current
directory, which is where the compose file expects it.

Then deploy with the shared pattern above.

Create a komodo directory in `/etc` (**unused?**)

```
mkdir -p /etc/komodo
```

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

Komodo only manages the runtime. But development can directly happen in VSCode in a local repo / branch. Using podman "compose commands".

## AdGuard Home (DNS-Server)

DNS server with blocking & filtering. Compose file: `adguard-home/compose.yaml`. Unit: `podman-compose@adguard-home`.

No longer managed by Komodo — it runs as a `podman-compose` systemd user unit like Caddy and Komodo
(shared pattern above). It uses `network_mode: host` and binds `:53` (DNS) and `:8095` (web UI),
which requires the unprivileged-port sysctl and the `dns` firewalld service from
[host-setup.md](host-setup.md).

### Forwarding `*.home.arpa` to (`homebase.fritz.box`)

`home.arpa` is the **IETF-designated special-use domain** for local, non-unique naming in residential networks. It is meant to be resolved **only by local DNS servers**, not the public DNS. `home.arpa` is defined as a special-use domain according to RFC 8375, designated for non-unique use in residential home networks.

#### DNS strategy

```
*.home.arpa → homebase.fritz.box → IP address
```

#### Configure Upstreams in AdGuard Home

Add the following upstreams under Settings → DNS → Upstream DNS servers:

```
[/fritz.box/]192.168.178.1
[/178.168.192.in-addr.arpa/]192.168.178.1
```

#### Create DNS Rewrite Rules

Add wildcard rewrite for `*.home.arpa` under Filters → DNS Rewrites.

Recommended CNAME approach:

```
Domain: *.home.arpa
Target: homebase.fritz.box
```

This should automatically resolve to a `CNAME` record.

#### Verification

Run from any LAN client:

```bash
dig test.home.arpa
dig homebase.fritz.box
dig +trace test.home.arpa
```
