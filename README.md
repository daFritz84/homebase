# homebase

Homeserver setup centered around [Komodo](https://komo.do/) using rootless [Podman](https://podman.io/).

This repository contains the compose files and configuration for the services running on `homebase`.
The full setup guide lives in [`docs/`](docs/) — this README is a quick entry point.

## Services

| Service    | Compose file                       | Purpose                                    |
| ---------- | ---------------------------------- | ------------------------------------------ |
| Komodo     | `komodo/compose.yaml`              | Deployment & orchestration platform        |
| Caddy      | `caddy/compose.yaml`              | Reverse proxy + TLS (LE DNS-01/Cloudflare) |
| Adguard Home | `adguard-home/compose.yaml`        | DNS server with blocking & filtering       |
| Homepage   | `stacks/homepage/compose.yaml`      | Service dashboard                          |
| Wanderer   | `stacks/wanderer/compose.yaml`      | Self-hosted trail database (Komodo stack)  |
| Home Assistant | `stacks/homeassistant/compose.yaml` | Home automation platform (Komodo stack)  |
| Test web   | `stacks/testweb/compose.yaml`       | Example stack for testing                  |

## Quick start

```bash
# create the shared proxy network (required by caddy, komodo and all stacks)
./caddy/ensure_proxy_network.sh

# unlock Bitwarden CLI (both provisioning scripts read from it)
bw login
export BW_SESSION="$(bw unlock --raw)"

# provision secret files
cd caddy && ACME_EMAIL="you@example.com" ./provision-caddy-secrets.sh
cd ../komodo && ./provision-komodo-secrets.sh

# pull and start a stack (caddy is a local build: official builder + Cloudflare DNS plugin)
cd ../caddy && podman-compose build && podman-compose up -d
cd ../komodo && podman-compose up -d

# stop a stack
podman-compose down
```

See [`docs/host-setup.md`](docs/host-setup.md) for the full installation and configuration guide,
[`docs/services.md`](docs/services.md) for the service setup, and
[`docs/operations.md`](docs/operations.md) for the update procedure.

## Documentation

- [`docs/host-setup.md`](docs/host-setup.md) — provision the host: Proxmox VM & iGPU passthrough, Debian base, packages, firewall, static IP, Podman, Git deploy keys, Bitwarden CLI
- [`docs/services.md`](docs/services.md) — deploy the stack: shared podman-compose systemd pattern, Caddy, Komodo, Adguard Home
- [`docs/operations.md`](docs/operations.md) — operate the stack: update procedure, Komodo backups, TODO & inspiration
- [`stacks/homepage/config/README.md`](stacks/homepage/config/README.md) — Homepage dashboard configuration
- [`docs/podman.md`](docs/podman.md) — Podman cheatsheet

## License

See [LICENSE](LICENSE).