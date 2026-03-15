# homebase
homeserver setup centered around komodo using rootless podman

# Podman Cheatsheet

**Start a podman compose file**

```bash
podman compose up -d
```

---

**Stop a podman compose file**

```bash
podman compose down
```

---
**Cleanup podman**

WARNING! This command removes:
        - all stopped containers
        - all networks not used by at least one container
        - all dangling images
        - all dangling build cache

```bash
podman system prune
```