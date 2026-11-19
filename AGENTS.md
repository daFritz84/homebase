# homebase

Homeserver stack: rootless Podman + `podman-compose`, run as systemd **user** units.
Docs are the source of truth and must be updated with the stack: `docs/host-setup.md`,
`docs/services.md`, `docs/operations.md`, `docs/podman.md`.

## Deployment target: `homebase` (never re-derive this)

Debian VM on Proxmox, `192.168.178.249`, user `chef`, checkout `/home/chef/src/homebase`
(branch `main`). `ssh chef@192.168.178.249` works with key auth and has `podman`,
`podman-compose`, `git`. Its deploy key is **read-only** — never push, never commit, never
rewrite history there. Services run as `systemctl --user podman-compose@<project>` units + linger.

The **workstation** is whichever clone is editing this repo — the only place to commit and push.
One-way flow: **branch → commit → push → validate on the server (deploy skill) → merge/PR →
(server) `git pull --rebase --autostash` → `systemctl --user restart
podman-compose@<project>`**. Runbook: `deploy` skill.

## Services (dir → unit · data that cannot be rebuilt)

`caddy`→`@caddy` · `adguard-home`→`@adguard-home` · `homepage`→`@homepage` ·
`wanderer`→`@wanderer` (`wanderer/data/`) · `navidrome`→`@navidrome` (`navidrome/data/navidrome.db`) ·
`jellyfin`→`@jellyfin` (`jellyfin/data/`) · `stirling-pdf`→`@stirling-pdf`
(`stirling-pdf/data/configs/` user DB+keys, `stirling-pdf/data/storage/`) ·
`bookorbit`→`@bookorbit` (`bookorbit/data/postgres/` pgvector DB, `bookorbit/data/app/`) ·
`homeassistant`→`@homeassistant`
(`config/.storage/`, `secrets.yaml`) · `authelia`→`@authelia` (LDAP users, sqlite factors,
`config/keys/`) · `cloudflared`→`@cloudflared` (tunnel credentials JSON, gitignored) ·
`rustdesk`→`@rustdesk` (`rustdesk/data/` server keypair + ID registry + tailscale state) ·
`monitoring`→`@monitoring` (`monitoring/data/` VictoriaMetrics TSDB + grafana sqlite +
alertmanager state; the declarative config in `monitoring/` is the gitops source of truth) +
the `node-exporter` and `podman-stats-export.timer` user units.
Images, tags, ports: read each `compose.yaml`.

`caddy-proxy` (pinned `10.89.0.0/24` by `caddy/ensure_proxy_network.sh`) must exist before any
`podman-compose up`. Bridge containers reach host services via `host.containers.internal`, not the
LAN IP.

## Validation

Validate against the **server's checkout**, never by `scp`-ing local files over: push the branch,
check it out on the server (deploy skill "Validate local changes on the server"), run the probes,
return the server to `main`.

Probe before assuming: `command -v podman podman-compose docker shellcheck yamllint hadolint`.
Sandboxed editor sessions (e.g. Flatpak) usually have none of them — validate over SSH instead:

```bash
# compose file (podman-compose has no -q; run from the service dir)
ssh chef@192.168.178.249 'cd ~/src/homebase/<dir> && podman-compose -f compose.yaml config'
# Caddyfile — must print "Valid configuration"; tag from caddy/compose.yaml.
# The image ships the stock default Caddyfile (the Dockerfile never COPYs it), so the
# repo file MUST be mounted — without -v this validates the base image's boilerplate.
ssh chef@192.168.178.249 'cd ~/src/homebase/caddy && podman run --rm --env-file .env \
  -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  homebase-caddy:<tag> caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile'
```

gitleaks, compose, shellcheck, yamllint, hadolint and caddy checks run in CI
(`.github/workflows/ci.yml`) — a red CI is a stop signal.

## Hard rules

- Never commit, push, `git checkout -- .`, `git reset --hard` or `git clean` on the server:
  `adguard-home/config/AdGuardHome.yaml` is rewritten by the server UI, so its tree is routinely
  dirty. Always `git pull --rebase --autostash`.
- Config drift flows **server → workstation**: copy over, review, commit, push.
- New/changed `.env` / `.env.secret` keys need `podman-compose up -d --force-recreate` in the
  service dir, **not** a unit restart (env is baked in at container creation).
- Secrets come from Bitwarden CLI: `provision-*-secrets.sh` (caddy, wanderer, authelia,
  cloudflared, rustdesk, monitoring) generates them; `homepage/.env` is provisioned manually per
  `docs/services.md`.
  `.env*`, `authelia/config/keys/`, `cloudflared/credentials.json`,
  rendered LDIF, `homeassistant/config/secrets.yaml` are gitignored. Never write secret values to
  tracked files; never print them.
- Authelia down = walled apps (AdGuard UI, VictoriaMetrics UI, Alertmanager UI, Navidrome web UI,
  Wanderer via the tunnel `:8443` listener) 502; Navidrome Subsonic playback unaffected (bypassed
  `/rest/*`). OIDC-only login (user decision 2026-11-19): the native OIDC clients expose **no**
  local login form; Authelia-down web-login recovery = SSH (shell is the root of trust):
  Jellyfin keeps serving, only its SSO login redirect fails (break-glass: unit stopped,
  SQL `UPDATE Users SET AuthenticationProviderId='Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider',
  EnableLocalPassword=1` → local form returns with the Bitwarden password; 12.x removed
  `--reset-password` and `--mode SeedSystem` is a migration runner, not a reset — verified
  2026-11-19; the local form is dead-ended by the SSO provider switch + hidden via CSS,
  Quick Connect disabled).
  Grafana keeps serving, only its login redirect fails (break-glass: flip
  `GF_AUTH_DISABLE_LOGIN_FORM` to `"false"` + `podman-compose up -d --force-recreate grafana`,
  log in with the Bitwarden `grafana-admin-password`; last resort `grafana cli admin
  reset-admin-password`).
  HA keeps serving, only its login redirect fails (break-glass: direct
  `http://127.0.0.1:8123` from the host → passwordless `trusted_networks` user picker; the
  domain path from the host does NOT auto-login — Caddy's XFF carries the host's LAN IP).
  BookOrbit: flip `DISABLE_LOCAL_AUTH` to `"false"` + force-recreate (needs a superuser with a
  local password). Wanderer: re-enable the users-collection password method in the PocketBase
  admin UI (superuser keeps its password). Stirling PDF keeps `/login?all` (no removal flag).
  Cockpit, Homepage, VPN, SSH are break-glass.
- Update-coupling gotchas (Cloudflare plugin pin in `caddy/Dockerfile`, `caddy-proxy` CIDR ↔
  `trusted_proxies static` in `caddy/Caddyfile`; Caddy's pinned `ipv4_address` 10.89.0.200 ↔
  `ND_EXTAUTH_TRUSTEDSOURCES` in `navidrome/compose.yaml`; HA's `trusted_proxies` is UI-managed in
  `.storage/http` — must be `127.0.0.1`+`::1`, NOT the CIDR, and NOT in `configuration.yaml`;
  Jellyfin SSO-Auth plugin 4.0.0.4 provider needs "Disable Pushed Authorization" + a **hex**
  client secret (Bitwarden `authelia-oidc-jellyfin-secret`) — PAR and a `+` in the secret both
  break SSO): `docs/operations.md`.
