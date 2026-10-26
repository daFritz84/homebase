# Retire Komodo → Cockpit + cockpit-podman + Podman Desktop

## Goal

Remove Komodo from the homebase stack entirely. Homepage, Wanderer and Home Assistant move onto the
existing `podman-compose@<project>` systemd-user-unit pattern (like Caddy/AdGuard). Cockpit +
cockpit-podman becomes the web management UI on the server; Podman Desktop connects remotely from
the workstation. Homepage's Komodo widget is replaced by container stats via the Podman socket and
a Cockpit bookmark tile.

## Decisions (fixed for implementation)

- **Cockpit exposure**: proxied by Caddy at `cockpit.sseifried.link` → `reverse_proxy 192.168.178.249:9090`
  (same hardcoded-host-IP pattern as AdGuard `:8095` and HA `:8123` — rootless containers cannot reach
  host services by name; pasta gateway refuses forwarded connections). `/etc/cockpit/cockpit.conf`
  needs `AllowOrigin = https://cockpit.sseifried.link`. Cockpit also validates the `Host` header,
  so the site needs `header_up Host cockpit.sseifried.link` (Caddy's default Host is the upstream
  IP, which Cockpit rejects — bare `curl` to the host IP returns empty). **No firewalld rule for
  9090** — LAN stays closed, Caddy reaches it from the podman-managed (firewalld-trusted) bridge,
  proven by AdGuard/HA.
- **`:80` block**: redirect target becomes `https://homepage.sseifried.link` (Komodo is gone; Homepage is
  the landing page). `/health` stays plaintext-proxied for LAN monitoring, repointed to
  `homepage:3000` with `rewrite → /api/health`.
- **Homepage container stats**: Homepage has **no dedicated podman widget** — its Docker integration
  speaks the Docker-compatible Podman API. A `tecnativa/docker-socket-proxy` sidecar fronts the
  rootless socket (`POST=0`, `CONTAINERS=1`) on an internal network; `docker.yaml` points at
  `dockerproxy:2375`. The socket is mounted only into the proxy — a direct `:ro` socket mount is
  **not** a read-only boundary (the full API stays connectable), and Homepage is web-exposed.
  Tiles get `server: homebase-podman` + `container:` + `showStats: true`.
- **Single checkout**: stacks run from `~/src/homebase/stacks/<name>` (the git clone), not the Komodo
  periphery checkout under `/home/chef/.local/share/komodo` (`PERIPHERY_ROOT_DIRECTORY`). Wanderer's
  `data/` is **moved** with `mv` (same filesystem → preserves rootless uid mappings); Home Assistant
  was never deployed — fresh onboarding in Phase 2. Container names under podman-compose use
  underscores (`<project>_<service>_<n>`), not docker-compose dashes.
- **Unit names**: `podman-compose@homepage`, `podman-compose@wanderer`, `podman-compose@homeassistant`
  (podman-compose derives the project from the directory basename).
- **Teardown order**: Cockpit up → Komodo control plane torn down **before the server's first
  `git pull`** (pre-migration backups, UI stack definitions removed, `podman-compose down` while
  `komodo/` still exists in the server checkout) → stacks migrated & verified → Caddy/homepage
  updated → leftover volumes/networks/periphery checkout removed. The pushed commit deletes
  `komodo/`, so teardown must precede the pull; this also closes the window in which the
  `komodo.skip` label removal would expose caddy/adguard to Komodo's StopAllContainers.
  Komodo state (users, API keys, stack defs) is rebuildable-only per operations.md — no new
  backup script; the section is deleted.
- **testweb** stays as-is (no unit, no restart policy — not part of the boot path).

## A. Repository changes (workstation, this repo)

1. **Delete `komodo/`** — `compose.yaml`, `provision-komodo-secrets.sh`, committed `.env` template.
2. **`caddy/Caddyfile`**
   - Remove the `komodo.sseifried.link` site.
   - `:80` block: `redir @nothealth https://homepage.sseifried.link{uri}`; health:
     `@health path /health /health/*` + `rewrite @health /api/health` + `reverse_proxy @health homepage:3000`.
   - Add site:
     ```
     cockpit.sseifried.link {
         import tls
         header Strict-Transport-Security "max-age=31536000; includeSubDomains"
         reverse_proxy 192.168.178.249:9090
     }
     ```
     (Caddy 2 proxies WebSockets transparently — Cockpit needs them.)
3. **`caddy/compose.yaml`, `adguard-home/compose.yaml`** — remove the `komodo.skip` label blocks.
4. **`stacks/homeassistant/compose.yaml`** — update the header comment: drop the "Komodo-managed
   stack / komodo.skip / start from the Komodo UI" lines; note it runs as a `podman-compose@homeassistant`
   unit.
5. **`stacks/homepage/compose.yaml`** — add a `dockerproxy` sidecar
   (`ghcr.io/tecnativa/docker-socket-proxy`, `POST=0`, `CONTAINERS=1`, socket mounted `:ro` into
   the proxy only) on a new `homepage-internal` network; Homepage joins that network and
   `depends_on` the proxy; update the `env_file` comment (KOMODO/ADGUARD → ADGUARD keys).
6. **`stacks/homepage/config/docker.yaml`** — replace the commented example with:
   ```yaml
   homebase-podman:
     host: dockerproxy
     port: 2375
   ```
7. **`stacks/homepage/config/services.yaml`** — replace the Komodo tile (widget block included) with:
   ```yaml
   - Cockpit:
       icon: cockpit
       href: https://cockpit.sseifried.link
       description: Web management — systemd units, logs, containers
   ```
   Add to the existing tiles: `server: homebase-podman`, `container:`
   (`homepage-homepage-1`, `adguard-home-adguard-home-1`, `wanderer-web-1`,
   `homeassistant-homeassistant-1`) and `showStats: true`. Keep yamllint-clean
   (`---` header, 2-space indent, existing style).
8. **`stacks/homepage/.env.example`** — remove `HOMEPAGE_VAR_KOMODO_KEY/SECRET` block; keep
   `HOMEPAGE_ALLOWED_HOSTS` + AdGuard vars.
9. **`stacks/homepage/config/README.md`** — drop the two KOMODO vars from the list.
10. **`.github/dependabot.yml`** — remove `"/komodo"` from the docker-compose directories.
11. **`.github/workflows/ci.yml`** — compose job: drop `komodo` from the validation loop and the
    `touch` list; remove `COMPOSE_PROJECT_DIR`, `PERIPHERY_ROOT_DIRECTORY`,
    `COMPOSE_KOMODO_BACKUPS_PATH` env; **keep `XDG_RUNTIME_DIR: /tmp`** (homepage socket
    interpolation now needs it).
12. **`.gitignore`** — update the env-file comment (drop komodo examples).
13. **`README.md`** — services table: remove Komodo row, add Cockpit row (host package, not a
    compose stack); quick start: remove komodo provisioning/up steps; docs links: services.md
    description mentions Cockpit instead of Komodo.
14. **`docs/services.md`**
    - TOC + body: remove the Komodo section; add a **Cockpit** section: `sudo apt install cockpit
      cockpit-podman`, `systemctl enable --now cockpit.socket`, `cockpit.conf` AllowOrigin, Caddy
      site, firewall note (9090 stays closed to LAN), Services page **user-instances toggle** for
      `podman-compose@*` units, cockpit-podman container page (logs/terminal), web terminal,
      future Authentik OIDC note.
    - Move the "Development workflow" (currently inside the Komodo section) under the shared-pattern
      section; step 4 becomes: `git pull --rebase --autostash` + `systemctl --user restart
      podman-compose@<project>` for **all** projects (no Komodo UI).
    - Wanderer + Home Assistant sections: replace "Komodo-managed stack — deployed from the Komodo
      UI" with unit names; replace the "Register the Komodo stack" first-run step with
      `podman-compose systemd` + `systemctl --user enable --now podman-compose@<name>`; change the
      "run in the Komodo periphery checkout" notes to `~/src/homebase`.
    - AdGuard intro: "runs as a podman-compose unit like Caddy" (drop Komodo); dig examples:
      `komodo.sseifried.link` → `cockpit.sseifried.link`; hardcoded-IP note: add the Cockpit
      `reverse_proxy` to the list of Caddyfile references.
15. **`docs/host-setup.md`** — Podman socket note: replace "Komodo's Periphery mounts the rootless
    socket" with "Homepage's container-stats integration and Podman Desktop remote connections use
    the rootless socket"; keep the "do not enable the rootful socket" warning.
16. **`docs/operations.md`**
    - Health check: replace the komodo unit status line with `@homepage`, `@wanderer`,
      `@homeassistant`; drop mongo from the log-verify list, add the new containers.
    - Delete the "Database backups" (Komodo built-in) section; add one line: Komodo held only
      rebuildable state; irreplaceable data is covered by the Wanderer/HA scripts.
    - Update procedure: drop komodo pull/restart; add the three stack units to the restart list;
      note stacks now update via `git pull` in `~/src/homebase` (no periphery checkout).
    - Troubleshooting: delete the three "stopped after a Komodo restart" entries and the
      `komodo.skip` convention; AdGuard-dashboard entry: ":80 redirects to the Homepage HTTPS UI
      by design"; keep the HA trusted_proxies entry.
    - Power Outage Recovery: all services are linger + user units; drop the Komodo UI sentence.
    - TODO: add "Cockpit OIDC SSO via Authentik" next to the Authentik entry.
17. **`docs/podman.md`** — add a short "Podman Desktop (remote)" section:
    `podman system connection add homebase ssh://chef@192.168.178.249/run/user/1000/podman/podman.sock`
    (Podman Desktop: Resources → Remote connections → SSH, same target); note it uses the rootless
    socket and the rootful socket stays disabled.
18. **Backup script comments** (`stacks/wanderer/backup-wanderer-data.sh`,
    `stacks/homeassistant/backup-ha-config.sh`) — "on the server that is the Komodo periphery
    checkout" → "the `~/src/homebase` checkout".

## B. Server runbook (manual, `ssh chef@192.168.178.249`)

Execute in order; each phase ends with its verification before proceeding.

**Phase 0 — Cockpit**
```bash
sudo apt install -y cockpit cockpit-podman
sudo systemctl enable --now cockpit.socket
printf '[WebService]\nAllowOrigin = https://cockpit.sseifried.link\n' | sudo tee /etc/cockpit/cockpit.conf
```
Verify: `systemctl is-active cockpit.socket`; `curl -s -H 'Host: homebase' 127.0.0.1:9090 | head -3`
returns the login HTML. A bare `curl 192.168.178.249:9090` returning empty is **expected** — Cockpit
rejects the IP as `Host` header (not a firewall issue); direct LAN access to `:9090` stays closed by
design (no firewalld rule). Browser login + Services/Podman/Terminal checks happen in Phase 3 via
`https://cockpit.sseifried.link` (Caddy forwards `Host: cockpit.sseifried.link`, allowed by
`AllowOrigin`).

**Phase 1 — pre-migration backups + Komodo control-plane teardown** (before any `git pull` —
the pushed commit deletes `komodo/`, and `podman-compose down` needs it)

```bash
# 0. Back up irreplaceable data FIRST (from the periphery checkout, where the data lives now).
#    Home Assistant was never deployed — nothing to back up; it gets a fresh onboarding in Phase 2.
cd /home/chef/.local/share/komodo/stacks/wanderer && ./backup-wanderer-data.sh
ls -lh ~/.local/share/wanderer/backups   # verify fresh archive

# 1. Remove the Homepage/Wanderer/Home Assistant/testweb stack definitions in the Komodo UI
#    (a UI deploy after the mv below would boot the stacks from empty dirs — split-brain)

# 2. Tear down the Komodo control plane while komodo/ still exists in the checkout
systemctl --user disable --now podman-compose@komodo
cd ~/src/homebase/komodo && podman-compose down && cd ../..

# 3. Stop the stack containers Komodo had started (podman-compose names use underscores;
#    names per podman ps; testweb has no restart policy and is usually already down)
podman stop wanderer_web_1 wanderer_search_1 wanderer_db_1 homepage_homepage_1 testweb_testweb_1
```
Verify: `podman ps` shows only caddy + adguard-home; `podman ps -a` shows no komodo/mongo/periphery
containers. From here on, the `komodo.skip` labels are moot — Komodo can no longer stop anything.

**Phase 2 — migrate the stacks** (move data, start the unit). The changes live on
`feat/retire-komodo-cockpit` — **merge the PR to `main` first** (the server is on `main` and its
deploy key is read-only). Before starting, sync live config drift (AdGuard ritual) from server →
workstation → commit → push, then `git pull --rebase --autostash` on the server (safe now: the
komodo teardown above is done).

- **Home Assistant** (not deployed yet — fresh start, no data to migrate):
  ```bash
  cd ~/src/homebase/stacks/homeassistant
  podman-compose systemd && systemctl --user enable --now podman-compose@homeassistant
  ```
  Then open `https://homeassistant.sseifried.link` and complete the onboarding wizard (owner
  account, location Vienna — see docs/services.md). `config/` is created in the checkout; the
  committed-YAML drift ritual and `backup-ha-config.sh` apply from the first UI edit onward.
- **Wanderer**:
  ```bash
  cd ~/src/homebase/stacks/wanderer
  mv /home/chef/.local/share/komodo/stacks/wanderer/data ./data
  ./provision-wanderer-secrets.sh          # bw unlocked; writes .env.secret
  podman-compose systemd && systemctl --user enable --now podman-compose@wanderer
  ```
- **Homepage** (no data dir; config is git-managed):
  ```bash
  cd ~/src/homebase/stacks/homepage
  # create .env from .env.example: HOMEPAGE_ALLOWED_HOSTS + AdGuard vars (Bitwarden), no KOMODO vars
  podman-compose systemd && systemctl --user enable --now podman-compose@homepage
  ```
Verify per stack: `systemctl --user status podman-compose@<name>`, `curl -k
https://<name>.sseifried.link`, HA onboarding **through Caddy** (proves trusted_proxies matches
the unchanged caddy-proxy subnet), Wanderer trails visible (data moved intact).

**Phase 3 — Caddy + Homepage** (after repo changes are pushed)
```bash
cd ~/src/homebase && git pull --rebase --autostash
podman run --rm --env-file caddy/.env homebase-caddy:2.11.7 \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile   # must print "Valid configuration"
systemctl --user restart podman-compose@caddy
systemctl --user restart podman-compose@homepage
```
Verify: `https://cockpit.sseifried.link` loads through the proxy (login, podman page);
`http://homebase.fritz.box/` redirects to Homepage; Homepage tiles show container stats and the
Cockpit tile; no Komodo tile.

**Phase 4 — remove leftovers** (only after Phases 0–3 verify)
```bash
rm -rf /home/chef/.local/share/komodo          # periphery checkouts + backups — data moved & verified
podman volume rm komodo_mongo-data komodo_mongo-config komodo_komodo-keys   # names per podman volume ls
podman network rm komodo-internal-network
podman image prune -a
```
(The `komodo/` directory deletion ships in the workstation commit the server pulled in Phase 2 —
no server-side git operations; the deploy key is read-only.)
Verify: `podman ps -a` shows no komodo/mongo/periphery containers;
`systemctl --user list-units 'podman-compose@*'` lists exactly caddy, adguard-home, homepage,
wanderer, homeassistant.

**Phase 5 — cleanup outside git** (manual)
- The Homepage Komodo API key is dead with the core teardown in Phase 1 — ensure
  `stacks/homepage/.env` (created in Phase 2) carries no KOMODO vars.
- Bitwarden: delete/archive items `komodo-db`, `komodo-admin`.
- GitHub: remove any Komodo webhooks.

## C. Validation

1. **CI green**: compose `config -q` for all remaining projects, yamllint on
   `stacks/homepage/config/`, shellcheck, hadolint, Caddyfile validate.
2. **Units**: `systemctl --user list-units 'podman-compose@*'` → 5 active, enabled.
3. **Endpoints** (LAN client): `curl -k` cockpit, homepage, adguard, wanderer,
   homeassistant `.sseifried.link` → all 200/expected; `dig cockpit.sseifried.link` resolves via
   AdGuard rewrite.
4. **Cockpit**: proxy login, user-services start/stop of `podman-compose@homepage`, cockpit-podman
   container terminal, Logs page shows unit journal.
5. **Homepage**: stats on tiles (podman socket), Cockpit tile, AdGuard widget, no 403 host errors.
6. **Reboot test**: `sudo reboot` → linger brings up all 5 units; HA reachable through Caddy;
   Wanderer healthy (`podman logs --tail=20 wanderer-search-1`).
7. **Podman Desktop** (workstation): remote connection lists the server containers; terminal works.

## Risks / notes

- **HA not deployed**: fresh onboarding in Phase 2 — no server-side state to migrate. The
  committed-YAML drift ritual and `backup-ha-config.sh` apply from the first UI edit onward.
- **`mv` not `cp`** for `data/` and `config/` — same filesystem, preserves the rootless uid
  mappings (Wanderer's uid-1000 dirs); `cp` would break permissions.
- **Homepage socket mount** requires the image's root user (default) — do not add a `user:` key.
- **CI** keeps `XDG_RUNTIME_DIR=/tmp` so `compose config -q` interpolates the homepage socket path.
- **Cockpit auth is PAM** (host accounts): add TOTP for the chef account; OIDC via Authentik is a
  follow-up TODO, not in this plan.
- Meilisearch upgrade procedure in services.md: "deploy" now means `systemctl --user restart
  podman-compose@wanderer` — wording update only, mechanics unchanged.
