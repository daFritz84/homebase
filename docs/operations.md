# Operations

Day-2 tasks: keeping the stack up to date, backing up irreplaceable data, and the open roadmap.

- [Stack Update Procedure](#stack-update-procedure)
- [TODO](#todo)
- [Appstore as Inspiration](#appstore-as-inspiration)

## Stack Update Procedure

### Check Health

```bash
systemctl --user status podman-compose@caddy
systemctl --user status podman-compose@adguard-home
systemctl --user status podman-compose@homepage
systemctl --user status podman-compose@wanderer
systemctl --user status podman-compose@homeassistant
podman ps
```

### Backups

Komodo (and its built-in scheduled backups) is gone — its database held only rebuildable
state (users, API keys, servers, stack definitions, variables), no irreplaceable data.
The scripts below cover everything that cannot be rebuilt.

### Wanderer data backups

Wanderer's `stacks/wanderer/data/` (PocketBase db, GPX uploads, Meili index) is
irreplaceable user data. Run from the stack checkout on the server:

```bash
cd stacks/wanderer && ./backup-wanderer-data.sh
```

The script stops the stack, archives `data/` to
`~/.local/share/wanderer/backups/wanderer-data-<date>.tar.gz`, and restarts it.
Cadence: after every significant trail import, at least monthly. Restore: stop the
stack, `rm -rf data && tar xzf <archive>`, start.

### Home Assistant config backups

Home Assistant's `stacks/homeassistant/config/` holds the irreplaceable
UI-managed state — `.storage/` (integrations, dashboards, users, long-lived
access tokens) and `secrets.yaml` are gitignored. Run from the stack checkout
on the server:

```bash
cd stacks/homeassistant && ./backup-ha-config.sh
```

The script stops the stack, archives `config/` (owner-only, mode `0600`) to
`~/.local/share/homeassistant/backups/ha-config-<date>.tar.gz`, and restarts
it. Cadence: after significant automation/integration changes, at least
monthly — take one right after onboarding. Restore: stop the stack,
`rm -rf config && tar xzf <archive>`, start.

### Update the stack

1. Update the repository

```bash
cd ~/src/homebase
git pull --rebase --autostash
```

> **Live config drift:** AdGuard Home rewrites `adguard-home/config/AdGuardHome.yaml` on every
> UI change, so the server checkout is routinely dirty. Always pull with
> `git pull --rebase --autostash` — never `git checkout -- .` on the server, that discards live
> UI changes. The server deploy key is read-only, so commit live config diffs from the
> workstation (copy the server's `AdGuardHome.yaml` over, review, commit, push).

2. Pull new images

```bash
cd caddy
podman-compose pull
podman-compose build   # Caddy is a local build (Cloudflare DNS plugin) — rebuild after image bumps
podman run --rm --env-file .env homebase-caddy:2.11.7 \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile   # must print "Valid configuration"

cd adguard-home
podman-compose pull

cd ../stacks/homepage
podman-compose pull

cd ../wanderer
podman-compose pull

cd ../homeassistant
podman-compose pull
```

> **Plugin pin not tracked by Dependabot:** the Cloudflare DNS plugin is pinned in
> `caddy/Dockerfile` (`caddy-dns/cloudflare@vX.Y.Z`). Dependabot bumps the Dockerfile base
> image and the compose image tag, but not this Go module pin — bump it manually when
> updating Caddy.

3. Restart

```bash
systemctl --user restart podman-compose@caddy
systemctl --user restart podman-compose@adguard-home
systemctl --user restart podman-compose@homepage
systemctl --user restart podman-compose@wanderer
systemctl --user restart podman-compose@homeassistant
```

4. Verify

```bash
podman ps
podman logs --tail=50 <caddy-container>
podman logs --tail=50 <adguard-home-container>
podman logs --tail=50 <homepage-container>
podman logs --tail=50 <wanderer-web-container>
podman logs --tail=50 <homeassistant-container>
```

5. Cleanup
   Remove all unreferenced images

```bash
podman image prune -a
```

## TLS Certificates

Caddy obtains and auto-renews Let's Encrypt wildcard certificates (`sseifried.link` +
`*.sseifried.link`) via the DNS-01 challenge through the Cloudflare API — no action is needed
for renewals (Caddy renews at ~1/3 of the certificate lifetime).

Check the current certificate:

```bash
openssl s_client -servername homepage.sseifried.link -connect 192.168.178.249:443 </dev/null \
  | openssl x509 -noout -issuer -dates -ext subjectAltName
```

Notes:

- Let's Encrypt allows **5 wildcard certificate issuances per week** per registered domain —
  avoid repeated forced renewals; use the staging CA (`ACME_CA` in `caddy/.env`) for testing.
- Renewals require the Cloudflare API token in `caddy/.env` (provision via
  `caddy/provision-caddy-secrets.sh`); if the token is rotated in Cloudflare, re-run the script
  and restart `podman-compose@caddy`.

## Troubleshooting

- **Caddy exits immediately after restart** — config error. Validate before deploying:
  `podman run --rm --env-file .env homebase-caddy:2.11.7 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`.
  Note: `redir` does not support negated named matchers (`@!name`/`!@name`); use an explicit
  `not` matcher.
- **502s / `connection refused` from containers to host services after network changes**
  (`podman system migrate`, network recreation) — netavark rules/subnets go stale
  (the `caddy-proxy` subnet changed from 10.88.0.0/16 to 10.89.0.0/24 once). Try
  `podman network reload --all`; a host reboot is the clean fallback.
- **All rootless containers fail with `newgidmap: write to gid_map failed`** — duplicate
  ranges in `/etc/subgid` (e.g. from appending a range that already existed). Keep exactly
  one `chef:<range>` line matching `/etc/subuid`, then `podman system migrate`.
- **HA login fails / 401 through the proxy after network recreation** — the
  `caddy-proxy` subnet drifted and `trusted_proxies` in
  `stacks/homeassistant/config/configuration.yaml` is stale. Check
  `podman network inspect caddy-proxy`, update the CIDR, redeploy (see
  [services.md](services.md), "Reverse proxy (trusted_proxies)").
- **AdGuard dashboard** — use `https://adguard.sseifried.link`; plain HTTP on :80
  redirects to the Homepage HTTPS UI by design (Caddyfile `:80` block).

## Power Outage Recovery

Recovery is automatic when Proxmox VM autostart is enabled: set `onboot: 1` on the VM
(`qm set <VMID> --onboot 1`). Once the host is back, linger (see
[host-setup.md](host-setup.md)) starts all five user units — `podman-compose@caddy`,
`podman-compose@adguard-home`, `podman-compose@homepage`, `podman-compose@wanderer` and
`podman-compose@homeassistant` — no manual action is needed.

## TODO

- Authentik Single Sign On
- Cockpit OIDC single sign-on (via Authentik, once it is deployed)

## Appstore as Inspiration

- [CasaOS AppStore](https://github.com/IceWhaleTech/CasaOS-AppStore/tree/main/Apps)
