# Podman Cheatsheet

**Start a podman-compose file**

```bash
podman-compose up -d
```

**Stop a podman-compose file**

```bash
podman-compose down
```

**Cleanup podman**

WARNING! This command removes:
- all stopped containers
- all networks not used by at least one container
- all dangling images
- all dangling build cache

```bash
podman system prune -a
```

**Podman Desktop (remote connection to homebase)**

The workstation's Podman Desktop connects to the server's **rootless** engine over SSH
(`systemctl --user enable --now podman.socket` on the server, see
[host-setup.md](host-setup.md#podman)). In Podman Desktop: Resources → Podman →
Remote connections → add an SSH connection to `chef@192.168.178.249`. CLI equivalent:

```bash
podman system connection add homebase ssh://chef@192.168.178.249/run/user/1000/podman/podman.sock
podman --connection homebase ps
```

The rootful socket stays disabled — the rootless user socket is the only one in use.