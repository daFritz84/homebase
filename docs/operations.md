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
git pull
```

2. Pull new images

```bash
cd caddy
podman-compose pull

cd komodo
podman-compose pull
```

3. Restart

```bash
systemctl --user restart podman-compose@caddy
systemctl --user restart podman-compose@komodo
```

4. Verify

```bash
podman ps
podman logs --tail=50 <caddy-container>
podman logs --tail=50 <komodo-container>
podman logs --tail=50 <mongo-container>
```

5. Cleanup
   Remove all unreferenced images

```bash
podman image prune -a
```

## TODO

- FritzBox IPv6 DNS is redirecting to extern
- CA for Homelab setup
- Authentik Single Sign On
- Autostart after power outage

## Appstore as Inspiration

- [CasaOS AppStore](https://github.com/IceWhaleTech/CasaOS-AppStore/tree/main/Apps)
