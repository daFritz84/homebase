---
name: deploy
description: Deploy, restart, verify, back up, restore, and roll back the homebase stack on the homebase server over SSH.
---

# Deploying homebase

Topology, units, hard rules: `AGENTS.md`. Background: `docs/services.md`, `docs/operations.md`.
Runtime commands run over SSH: probe `command -v podman podman-compose` — sandboxed editor
sessions have no container tooling.

## 0. Preflight

```bash
git status -sb && git log --oneline origin/main..HEAD
ssh chef@192.168.178.249 'cd ~/src/homebase && git status -sb && git log --oneline -1 && systemctl --user is-system-running'
```

A dirty server tree is normal (AdGuard drift) — never clean it. Ask the user before touching
`authelia/`, `homeassistant/config/`, `wanderer/data/`, `caddy/Caddyfile`, `caddy-proxy`
networking, or `.env*` keys (irreplaceable state / lockout risk).

## 1. Workstation: commit, push

```bash
git add <paths> && git diff --staged && git commit && git push
```

Caddyfile validation runs over SSH (AGENTS.md); CI (`.github/workflows/ci.yml`) gates the rest —
red CI = stop.

## 2. Server: pull

```bash
ssh chef@192.168.178.249 'cd ~/src/homebase && git pull --rebase --autostash'
```

Conflicts → stop and report; never resolve on the server.

## 3. Server: apply (narrowest action that matches the change)

| Change | Command, in the service dir on the server |
| --- | --- |
| config/code only | `systemctl --user restart podman-compose@<project>` |
| image tag bump | `podman-compose pull`, then unit restart |
| Caddy image rebuild | `podman-compose build` (bump `CB_VERSION` and the plugin pin in `caddy/Dockerfile` together) |
| new/changed `.env` / `.env.secret` key | `podman-compose up -d --force-recreate` (unit restart does **not** re-read env) |
| first deploy of a service | `./caddy/ensure_proxy_network.sh`, provision secrets, `podman-compose up -d`, `podman-compose systemd`, `systemctl --user enable --now podman-compose@<project>` |

`ssh chef@192.168.178.249 'cd ~/src/homebase/<dir> && <cmd>'`

`caddy` last for proxy changes; `authelia` before anything behind the wall. `podman-compose`
ignores `depends_on: condition: service_healthy` — authelia may crash-loop ~30s while slapd
bootstraps; that self-heals, do not panic-restart.

## 4. Verify (never skip)

```bash
ssh chef@192.168.178.249 'systemctl --user is-active podman-compose@{caddy,adguard-home,homepage,wanderer,homeassistant,authelia}; podman ps'
ssh chef@192.168.178.249 'podman logs --tail=50 <container>'   # names from `podman ps`
ssh chef@192.168.178.249 'podman exec caddy curl -s -o /dev/null -w "%{http_code}\n" http://host.containers.internal:8095'
```

Units `active`, no `Restarting`/`Exited`, walled apps `200`/`302` to the Authelia portal (not
`502`). Env recreation proof: `podman inspect <container> --format "{{json .Config.Env}}"`.
Public curls (`https://homepage.sseifried.link`) are best-effort and need LAN/VPN reachability —
a curl failure there is not a failed deploy. `podman image prune -a` is opt-in, only after
verification passes.

## 5. Config drift: server → workstation

From the repo root on the workstation:

```bash
scp chef@192.168.178.249:~/src/homebase/adguard-home/config/AdGuardHome.yaml \
    ./adguard-home/config/AdGuardHome.yaml
git diff && git add adguard-home/config/AdGuardHome.yaml && git commit && git push
```

Review the diff; never blind-copy, never commit on the server.

## 6. Backups

`authelia/backup-authelia.sh`, `homeassistant/backup-ha-config.sh`,
`wanderer/backup-wanderer-data.sh` (run from the service dir on the server) — stops the service,
archives, restarts; confirm the unit is `active` afterwards.
Cadence + restore order (Authelia: LDIF, sqlite and `config/keys/` in place **before** start,
after `provision-authelia-secrets.sh`) in `docs/operations.md`.

## 7. Rollback

Fix forward: `git revert <sha>` on the workstation, push, redeploy. Images: re-pull the previous
tag, `podman-compose up -d --force-recreate`. Never rewrite server history (`git checkout <sha>`,
`git reset --hard`, `git clean`) — the server tree is dirty by design.

## Stop-and-report

`git pull` conflicts · red CI · Caddyfile validation failure · unit not `active` after restart ·
walled apps `502` while authelia is `active` · anything destructive against `wanderer/data/`,
`homeassistant/config/.storage/`, `authelia/config/keys/`, `caddy-proxy`.
Never `git clean`, `git reset --hard`, `git checkout -- .`, `rm -rf`, `podman volume rm` on the
server.
