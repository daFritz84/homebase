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
systemctl --user status podman-compose@navidrome
systemctl --user status podman-compose@jellyfin
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

### Navidrome data backups

Navidrome's `navidrome/data/navidrome.db` is the irreplaceable,
secret-bearing artifact: users, playlists, share tokens and the
auto-generated session/password secrets live in the SQLite DB. Run from the
service checkout on the server:

```bash
cd navidrome && ./backup-navidrome-data.sh
```

The script stops the service, archives `data/` (excluding the rebuildable
`data/cache`) to
`~/.local/share/navidrome/backups/navidrome-data-<date>.tar.gz`, and restarts
it. Cadence: after admin creation and every significant playlist/share change,
at least monthly — and **before every image bump** (DB migrations are
forward-only). Restore: stop the service, `rm -rf data && tar xzf <archive>`,
`podman unshare chown 1000:1000 data`, start. The script (re)starts the
containers directly, so the unit shows `inactive` afterwards —
`systemctl --user start podman-compose@navidrome` to re-adopt the pod.

### Jellyfin data backups

Jellyfin's `jellyfin/data/` is the irreplaceable, secret-bearing artifact:
`jellyfin.xml` (incl. the VAAPI/transcoding settings), users, password
hashes, API keys and the plugin DB. Run from the service checkout on the
server:

```bash
cd jellyfin && ./backup-jellyfin-data.sh
```

The script stops the service, archives `data/` (owner-only, mode `0600`;
the sibling `cache/` is rebuildable and excluded by construction) to
`~/.local/share/jellyfin/backups/jellyfin-data-<date>.tar.gz`, and restarts
it. No `podman unshare` needed — the image runs as root and rootless Podman
maps container root to the host user, so `data/` is host-user-owned
(services.md, "Jellyfin (Media Server)"). Cadence: right after admin
creation and after library/user/plugin changes, at least monthly — and
**before every image bump** (DB migrations are forward-only). Restore: stop
the service, `rm -rf data && tar xzf <archive>`, start. The script
(re)starts the containers directly, so the unit shows `inactive` afterwards
— `systemctl --user start podman-compose@jellyfin` to re-adopt the pod.

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

### Authelia MFA recovery

Second factors (Bitwarden passkey primary + TOTP backup, see
[services.md](services.md), "MFA enrollment") are enforced: `two_factor` on
every walled-app rule and all four OIDC clients. Recovery paths:

- **Passkey lost** (vault lockout, extension breakage): at the 2FA step pick
  **TOTP** — no server action needed. Re-enroll a passkey from the portal
  afterwards (the elevation OTP is written to
  `~/src/homebase/authelia/config/notifier/notification.txt` — `tail -f` it
  over SSH **before** starting the ceremony, the code TTL is ~2 minutes).
- **Both factors lost** (e.g. Bitwarden + phone gone): SSH in (always
  available; Cockpit and the HA break-glass form are unaffected), then from
  `~/src/homebase/authelia`:

```bash
systemctl --user stop podman-compose@authelia
podman run --rm --env-file .env.secret -v "$PWD/config:/config" \
  -e X_AUTHELIA_CONFIG_FILTERS=template docker.io/authelia/authelia:4.39.28 \
  authelia storage user webauthn delete sseifried --all --config /config/configuration.yml
podman run --rm --env-file .env.secret -v "$PWD/config:/config" \
  -e X_AUTHELIA_CONFIG_FILTERS=template docker.io/authelia/authelia:4.39.28 \
  authelia storage user totp delete sseifried --config /config/configuration.yml
systemctl --user start podman-compose@authelia
```

  Log in at the portal — the `two_factor` policy forces re-registration at
  login.
- **Self-service delete** (factor present, want to remove it): portal device
  management requires elevation; the OTP code is written to
  `~/src/homebase/authelia/config/notifier/notification.txt` — read it over
  SSH.
- **DB restore**: `backup-authelia.sh` archive +
  `./provision-authelia-secrets.sh` (unlocked vault) to recreate
  `.env.secret` (the storage encryption key is Bitwarden-only) — see
  "Authelia backups" above.

Factor verification (passkey): the same `podman run` pattern with
`authelia storage user webauthn list sseifried` (stop the unit first on
`SQLITE_BUSY` — the service holds the DB). 4.39 has no `totp list` — verify
TOTP in the portal UI and by completing a test login that selects TOTP.

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

cd ../navidrome
podman-compose pull

cd ../jellyfin
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
systemctl --user restart podman-compose@navidrome
systemctl --user restart podman-compose@jellyfin
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

> **Unit restarts can be a no-op (config changes ignored):** the
> `podman-compose@` unit's start path is `podman pod start pod_<project>` —
> a no-op on an already-running pod, so `systemctl --user restart` has been
> observed leaving containers running with the OLD config (diagnosed
> 2026-11-07: an authelia `configuration.yml` change stayed invisible for
> ~1h of restarts; `podman inspect <container> --format
> "{{.State.StartedAt}}"` proved the container never restarted). Reliable
> for config-only changes: `podman restart <container>` (verify
> `StartedAt` moved).

4. Verify

```bash
podman ps
podman logs --tail=50 <caddy-container>
podman logs --tail=50 <adguard-home-container>
podman logs --tail=50 <homepage-container>
podman logs --tail=50 <wanderer-web-container>
podman logs --tail=50 navidrome_navidrome_1
podman logs --tail=50 jellyfin_jellyfin_1
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
- **New `*.sseifried.link` site: cert never issues, log loops `timed out
  waiting for record to fully propagate` (last error: `<nil>`)** — with no
  `resolvers` configured, certmagic's propagation check queries the zone's
  authoritative NS directly; Cloudflare NS hostnames rotate over many
  anycast IPs and a degraded PoP (port 53 timeout/REFUSED from this
  network) makes every check time out. The fix is in the Caddyfile `(tls)`
  snippet: `resolvers 1.1.1.1` (recursive check; plugin README). Verify
  the TXT publishes fine: `dig +norecurse TXT
  _acme-challenge.<host>.sseifried.link @<zone-NS-IP>`. Secondary effect:
  each failed attempt's cleanup deletes the TXT, seeding a **1800s NXDOMAIN
  negative cache** (SOA minimum TTL) at recursive resolvers, so attempts
  keep failing after the primary cause is fixed — break the loop by
  stopping the unit until the TTL expires, or plant a short-TTL keeper TXT
  (`_acme-challenge.<host>`, any content, TTL 60) so the name never goes
  NXDOMAIN; delete the keeper once the cert issues.
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
 - **`host.containers.internal` flaky after reboots — works after `podman restart`,
   breaks after container recreates; Caddy logs `lookup host.containers.internal:
   i/o timeout`** — podman does NOT inject the name into `/etc/hosts` for containers
   on user-defined networks (aardvark answers `NXDOMAIN` for
   `host.containers.internal.dns.podman`), so the query leaks to upstream DNS where
   the Fritzbox wildcard-answers with our public IPv6 — reachable only while that
   answer is current (prefix changes at reboot). `caddy/compose.yaml` pins
   `extra_hosts: host.containers.internal:169.254.1.2` (pasta `--map-guest-addr`).
   If the relay itself is dead (every container gets `Network unreachable`/timeout
   on `169.254.1.2:<port>` while pasta runs): stop all compose stacks — pasta exits
   with the last container — then start them in dependency order (AdGuard, Authelia,
   rest, Caddy last); the rootless netns is recreated fresh. Root cause: linger
   starts the user manager before the host has an IP/default route, so pasta
   (`--config-net`) copies a route-less config. Durable fix: the
   `podman-network-online` gate unit + `podman-compose@` drop-in in `systemd/`
   (install via `./systemd/install-user-units.sh`, see
   [services.md](services.md) "Boot ordering gate") order every compose unit
   behind a usable default route. If it recurs after the gate is installed,
   check `systemctl --user status podman-network-online`.
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
- **Config change has no effect after `systemctl --user restart
  podman-compose@<project>`** — the unit's start path is `podman pod start
  pod_<project>`, a no-op on a running pod; the container keeps running
  with the old config (authelia kept rejecting a fixed OIDC client setting
  for ~1h this way, 2026-11-07). Check `podman inspect <container>
  --format "{{.State.StartedAt}}"` — if it predates your restart, the
  container never restarted. Fix: `podman restart <container>` (config
  changes) or `podman-compose up -d --force-recreate` (env changes).
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
- **Access 403 after a successful Authelia login** — check the app's policy
  (Accept + Login with the Authelia OIDC IdP + email-domain condition
  `@sseifried.link`) and that the IdP's client secret matches the RAW
  `authelia-oidc-cloudflare-secret`; the email-domain condition must cover
  the Authelia `email` claim (the LDAP `mail` attribute in
  `authelia/config/bootstrap.ldif`).
- **Access federation login "User email was not returned"** — Access reads
  claims from the ID token only (CF "Claims Hydration" bug, see
  [services.md](services.md) "Federation notes"): the `cloudflare-access`
  client must keep `claims_policy: 'cloudflare-access'` (email in the ID
  token). A mangled client secret shows as "client secret did not match" at
  the token endpoint instead — CF form-mangles `+`/`/` in base64 secrets,
  use hex (`openssl rand -hex 24`).
- **431 Request Header Fields Too Large after a successful Access login** —
  Authelia's `server.buffers.read` (default 4096) caps the header block of
  Caddy's forward-auth subrequest: browser Cookie (`CF_Authorization` ~1 KiB
  after Access login) + `Cf-Access-Jwt-Assertion` (~1 KiB) + `X-Forwarded-*`
  ≈ 4.3 KiB > 4 KiB → Authelia 431s, Caddy relays (the 35-byte text/plain
  body is Authelia's; Node's raw 431 has no body). Fix:
  `server.buffers.read: 16384` in `authelia/config/configuration.yml`
  (PR #63). Diagnose with Caddy: global `servers { log_credentials }` +
  site `log` shows the real Cookie size; `upstream roundtrip` DEBUG shows
  the subrequest headers.
- **`http://<published-hostname>` → 400 Bad Request** — the request reaches
  the origin through the tunnel with `X-Forwarded-Proto: http` and the wall
  refuses it (Authelia: "Target URL ... has an insecure scheme 'http'",
  fail-closed). Enable Cloudflare **Always Use HTTPS** (SSL/TLS → Edge
  Certificates) so http 301s at the edge.
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
[host-setup.md](host-setup.md)) starts all nine user units — `podman-compose@caddy`,
`podman-compose@adguard-home`, `podman-compose@homepage`, `podman-compose@wanderer`,
`podman-compose@navidrome`, `podman-compose@jellyfin`, `podman-compose@homeassistant`,
`podman-compose@authelia` and `podman-compose@cloudflared` — no manual action is needed.

## Appstore as Inspiration

- [CasaOS AppStore](https://github.com/IceWhaleTech/CasaOS-AppStore/tree/main/Apps)
