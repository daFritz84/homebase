# Operations

Day-2 tasks: keeping the stack up to date, backing up irreplaceable data, and the open roadmap.

- [Stack Update Procedure](#stack-update-procedure)
- [Appstore as Inspiration](#appstore-as-inspiration)

## Stack Update Procedure

### Check Health

```bash
systemctl --user status podman-compose@caddy
systemctl --user status podman-compose@adguard-home
systemctl --user status podman-compose@homepage
systemctl --user status podman-compose@wanderer
systemctl --user status podman-compose@homeassistant
systemctl --user status podman-compose@authelia
systemctl --user status podman-compose@cloudflared
podman ps
```

### Backups

Komodo (and its built-in scheduled backups) is gone — its database held only rebuildable
state (users, API keys, servers, stack definitions, variables), no irreplaceable data.
The scripts below cover everything that cannot be rebuilt.

### Wanderer data backups

Wanderer's `wanderer/data/` (PocketBase db, GPX uploads, Meili index) is
irreplaceable user data. Run from the service checkout on the server:

```bash
cd wanderer && ./backup-wanderer-data.sh
```

The script stops the service, archives `data/` to
`~/.local/share/wanderer/backups/wanderer-data-<date>.tar.gz`, and restarts it.
Cadence: after every significant trail import, at least monthly. Restore: stop the
service, `rm -rf data && tar xzf <archive>`, start.

### Home Assistant config backups

Home Assistant's `homeassistant/config/` holds the irreplaceable
UI-managed state — `.storage/` (integrations, dashboards, users, long-lived
access tokens) and `secrets.yaml` are gitignored. Run from the service checkout
on the server:

```bash
cd homeassistant && ./backup-ha-config.sh
```

The script stops the service, archives `config/` (owner-only, mode `0600`) to
`~/.local/share/homeassistant/backups/ha-config-<date>.tar.gz`, and restarts
it. Cadence: after significant automation/integration changes, at least
monthly — take one right after onboarding. Restore: stop the service,
`rm -rf config && tar xzf <archive>`, start.

### Authelia backups

The authelia stack holds the irreplaceable identity data: the OpenLDAP
directory (users) and the sqlite DB (TOTP/WebAuthn factors), plus the
gitignored OIDC signing keys in `authelia/config/keys/`. Run from the service
checkout on the server:

```bash
cd authelia && ./backup-authelia.sh
```

The script stops the service, dumps the directory with offline `slapcat`,
copies the sqlite volume and `config/keys/`, and archives everything
(owner-only, mode `0600`) to `~/.local/share/authelia/backups/authelia-<date>.tar.gz`,
then restarts. Cadence: monthly + after every user/group change. Restore
(order matters — authelia opens the sqlite DB and reads the keys at startup,
so they must be in place BEFORE it starts, not under a running process):
stop the service, recreate `.env.secret` from Bitwarden
(`./provision-authelia-secrets.sh` — the storage encryption key that
decrypts the factors DB is NOT in the archive), `podman-compose up -d
openldap` (creates fresh volumes), load the archived LDIF with `ldapadd`,
copy the sqlite file into the `authelia_authelia-db` volume and
`config/keys/` while authelia is still stopped, then `podman-compose up -d`
the rest.

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

cd ../homepage
podman-compose pull

cd ../wanderer
podman-compose pull

cd ../homeassistant
podman-compose pull

cd ../authelia
podman-compose pull

cd ../cloudflared
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
systemctl --user restart podman-compose@authelia
systemctl --user restart podman-compose@cloudflared
```

> **env_file changes need a recreation, not a restart:** the unit only
> `pod start`s the existing pod, and container env is baked in at creation —
> new/changed `.env.secret` / `.env` entries are invisible to a plain
> `systemctl restart`. Recreate from the service directory instead:
> `podman-compose up -d --force-recreate` (named volumes keep all data).
> Prove it with `podman inspect <container> --format "{{json .Config.Env}}"`.

4. Verify

```bash
podman ps
podman logs --tail=50 <caddy-container>
podman logs --tail=50 <adguard-home-container>
podman logs --tail=50 <homepage-container>
podman logs --tail=50 <wanderer-web-container>
podman logs --tail=50 <homeassistant-container>
podman logs --tail=50 authelia_authelia_1
podman logs --tail=50 authelia_openldap_1
podman logs --tail=50 cloudflared_cloudflared_1
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
  `caddy/ensure_proxy_network.sh` now creates the network with a pinned
  `--subnet 10.89.0.0/24`, so a recreated network keeps the CIDR that
  `trusted_proxies` expects (an existing network is left untouched — check it
  with `podman network inspect caddy-proxy`).
- **After a host reboot: walled apps (AdGuard UI) 502, HA 502 (Caddy→HA
  reachability, not the wall — HA is a native OIDC client, not walled),
  AdGuard widget down, containers get `connection refused` to host ports
  `:8095/:8123/:9090`** —
  firewalld reloads its permanent config at boot and loses the runtime trust
  netavark had registered for the `caddy-proxy` bridge; existing networks are
  not re-registered. The durable fix is architectural: bridge containers reach
  host services via `host.containers.internal` (pasta `--map-guest-addr` →
  host loopback, firewalld-trusted), not the LAN IP — see
  [services.md](services.md) "Split DNS" note. Verify from a bridge container:
  `podman exec caddy curl -s -o /dev/null -w '%{http_code}' http://host.containers.internal:8095`.
- **All rootless containers fail with `newgidmap: write to gid_map failed`** — duplicate
  ranges in `/etc/subgid` (e.g. from appending a range that already existed). Keep exactly
  one `chef:<range>` line matching `/etc/subuid`, then `podman system migrate`.
- **HA login fails / 401 through the proxy after network recreation** —
  `trusted_proxies` (UI-managed in `.storage/http`, NOT in
  `configuration.yaml`) is stale. HA is host-networked and Caddy reaches it
  via `host.containers.internal` (pasta relay), so the value must be
  `127.0.0.1` + `::1` — a `caddy-proxy` CIDR or LAN-IP entry is the bug.
  Fix under Settings → System → Network (see [services.md](services.md),
  "Reverse proxy (trusted_proxies)").
- **AdGuard dashboard** — use `https://adguard.sseifried.link`; plain HTTP on :80
  redirects to the Homepage HTTPS UI by design (Caddyfile `:80` block).
- **Walled apps (AdGuard UI, Wanderer) return 502** — the authelia stack is
  down. Check `systemctl --user status podman-compose@authelia` and
  `podman logs --tail=50 authelia_authelia_1`; restart the unit. Cockpit,
  Homepage, VPN and SSH are unaffected (not walled). Home Assistant keeps
  serving (native OIDC client, not walled) — only its login redirect to
  Authelia fails; existing HA sessions keep working, break-glass form:
  `http://127.0.0.1:8123/?skip_oidc_redirect=true` from the host.
  Break-glass is SSH (see [services.md](services.md), "Authelia (SSO) →
  Break-glass").
- **New `.env.secret` entries have no effect after a unit restart** — the
  `podman-compose@` unit only `pod start`s the existing pod; env is baked in
  at container creation. `podman inspect <container> --format
  "{{json .Config.Env}}"` shows the stale set; fix with
  `podman-compose up -d --force-recreate` (see "Update the stack" note).
- **forward_auth wall loops / auth requests rejected after network recreation**
  — the `caddy-proxy` subnet drifted and `trusted_proxies 10.89.0.0/24` in the
  Caddyfile `(authelia-fa)` snippet is stale. Check `podman network inspect
  caddy-proxy`, update the CIDR in the snippet, validate, restart
  `podman-compose@caddy`. (Authelia 4.38+ has no `server.trusted_proxies` —
  proxy trust lives only in Caddy.) `ensure_proxy_network.sh` pins the subnet
  at creation, so a recreated network should not drift.
- **HA login loops between `homeassistant.sseifried.link` and
  `authelia.sseifried.link`** — the OIDC round trip fails: the component
  cannot reach its `discovery_url`
  (`https://authelia.sseifried.link/.well-known/openid-configuration`) from
  HA. HA is host-networked: AdGuard split DNS must resolve the domain and
  Caddy must be up (TLS via Caddy, no private CA). Probe from the host:
  `curl -s https://authelia.sseifried.link/.well-known/openid-configuration`.
  Also check the `homeassistant` OIDC client's `redirect_uris` in
  `authelia/config/configuration.yml` matches
  `https://homeassistant.sseifried.link/auth/oidc/callback` exactly
  (see [services.md](services.md), "HA SSO (hass-oidc-auth)").
- **HA login page stops offering the Authelia button / breaks after an HA
  core update** — the vendored `hass-oidc-auth` pin (v1.2.1,
  `homeassistant/config/custom_components/auth_oidc/`) is incompatible with
  the new core (it injects frontend assets). Check upstream releases/issues,
  bump the vendored zip per the upgrade procedure in
  [services.md](services.md), "HA SSO (hass-oidc-auth)". Fallback meanwhile:
  HA's own login form — `http://127.0.0.1:8123/?skip_oidc_redirect=true`
  from the host, or `https://homeassistant.sseifried.link/?skip_oidc_redirect=true`.
- **Portal login: 49 Invalid Credentials for every user** — the directory's
  `userPassword` hashes were rendered with the openldap image's
  `slappasswd`, whose `{SSHA}` payload slapd 2.4.57 rejects on simple bind
  (`slappasswd -v` accepts its own hashes, so offline verification passes —
  the trap). `render-ldif.sh` hashes with `python3` hashlib SSHA; fix a live
  directory with `ldapmodify replace: userPassword` (via `-Y EXTERNAL
  -H ldapi:///`) using a freshly rendered hash. The `cn=admin` entry is
  unaffected (osixia rewrites it with slapd's internal pw module at
  startup). See [services.md](services.md), "4.39 schema notes".
- **authelia crash-loops at first start** — podman-compose **ignores**
  `depends_on: condition: service_healthy` (start ordering only), so authelia
  starts while slapd is still bootstrapping, fails its LDAP connection and
  exits; `restart: unless-stopped` self-heals it within ~30s. If it keeps
  looping, check slapd: the openldap healthcheck must not pass `-b` to
  `ldapwhoami` (it accepts no base DN — such a check fails forever and marks
  slapd unhealthy). Check `podman inspect authelia_openldap_1 --format
  '{{json .State.Health}}'` and `podman logs authelia_openldap_1`.
- **Tunnel down / dashboard shows `connector has never connected`** —
  `podman logs --tail=50 cloudflared_cloudflared_1`: `credentials.json`
  missing/unreadable (re-run `cloudflared/provision-cloudflared-secrets.sh`
  — the file must be 0600 **and** chowned to container uid 65532 via
  `podman unshare chown`, see [services.md](services.md) "Cloudflare
  Tunnel"); cert.pem is NOT needed on the server. Also check the unit is
  active and the dashboard connector status.
- **Redirect loop at the Cloudflare edge** (too many redirects on a
  published hostname) — the tunnel ingress must target `https://caddy:443`
  with a per-host `originServerName` (`cloudflared/config.yml`); an
  `http://` ingress hits Caddy's `:80` redirect block and loops.
- **Access 403 after a successful Authelia login** — the Access policy
  include email must equal the Authelia `email` claim exactly (the LDAP
  `mail` attribute in `authelia/config/bootstrap.ldif`); check the user's
  `mail` and the policy, and that the app's IdP is the Authelia OIDC IdP.
- **Authelia ip-mode ban hits all remote users at once** (one failed login
  bans everyone through the tunnel) — Caddy's global
  `servers { trusted_proxies static 10.89.0.0/24 }` is missing/stale, so
  `forward_auth` passes the shared tunnel source IP and every remote client
  shares one `remote_ip`. Check the Caddyfile global block and the
  `caddy-proxy` subnet (`podman network inspect caddy-proxy`), validate,
  restart `podman-compose@caddy`.

## Power Outage Recovery

Recovery is automatic when Proxmox VM autostart is enabled: set `onboot: 1` on the VM
(`qm set <VMID> --onboot 1`). Once the host is back, linger (see
[host-setup.md](host-setup.md)) starts all seven user units — `podman-compose@caddy`,
`podman-compose@adguard-home`, `podman-compose@homepage`, `podman-compose@wanderer`,
`podman-compose@homeassistant`, `podman-compose@authelia` and
`podman-compose@cloudflared` — no manual action is needed.

## Appstore as Inspiration

- [CasaOS AppStore](https://github.com/IceWhaleTech/CasaOS-AppStore/tree/main/Apps)
