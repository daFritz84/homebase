# Operations

Day-2 tasks: keeping the stack up to date, backing up Komodo data, and the open roadmap.

- [Stack Update Procedure](#stack-update-procedure)
- [TODO](#todo)
- [Appstore as Inspiration](#appstore-as-inspiration)

## Stack Update Procedure

### Check Health

```bash
systemctl --user status podman-compose@caddy
systemctl --user status podman-compose@komodo
systemctl --user status podman-compose@adguard-home
podman ps
```

### Mongodb backups

Komodo stores the Backups according to the `COMPOSE_KOMODO_BACKUPS_PATH=/home/chef/.local/share/komodo/backups` variable in the `.env` file

```
<BACKUP_PATH>
```
Replace `<BACKUP_PATH>` with the value of `COMPOSE_KOMODO_BACKUPS_PATH` from your `.env` file (e.g. `~/.local/share/komodo/backups`).

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

cd komodo
podman-compose pull

cd adguard-home
podman-compose pull
```

3. Restart

```bash
systemctl --user restart podman-compose@caddy
systemctl --user restart podman-compose@komodo
systemctl --user restart podman-compose@adguard-home
```

4. Verify

```bash
podman ps
podman logs --tail=50 <caddy-container>
podman logs --tail=50 <komodo-container>
podman logs --tail=50 <mongo-container>
podman logs --tail=50 <adguard-home-container>
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
- **Homepage is stopped after a Komodo restart** — by design: Homepage is a Komodo-managed
  stack, and Komodo's StopAllContainers stops it (Caddy, Komodo, Mongo and AdGuard carry the
  `komodo.skip` label to survive exactly that). Start Homepage from the Komodo UI.
- **AdGuard dashboard** — use `https://adguard.sseifried.link`; plain HTTP on :80
  redirects to the Komodo HTTPS UI by design (Caddyfile `:80` block).

## Power Outage Recovery

Recovery is automatic when Proxmox VM autostart is enabled: set `onboot: 1` on the VM
(`qm set <VMID> --onboot 1`). Once the host is back, linger (see
[host-setup.md](host-setup.md)) starts the user units `podman-compose@caddy`,
`podman-compose@komodo` and `podman-compose@adguard-home`; Homepage is a Komodo-managed
stack and is started from the Komodo UI (see [Troubleshooting](#troubleshooting)).

## TODO

- Authentik Single Sign On

## Appstore as Inspiration

- [CasaOS AppStore](https://github.com/IceWhaleTech/CasaOS-AppStore/tree/main/Apps)
