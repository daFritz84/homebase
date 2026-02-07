# homebase
homeserver setup centered around komodo

# TODO

- [ ] rootful vs. rootless komodo. Does it even make sense to have this rootless
- [ ] forward to external interface
- [ ] cleanup and refactor komodo/compose.env. And why isn't it used automatically when the `env-file` is set to `compose.env` in the compose file.

# Podman Cheatsheet

**Start a podman compose file**

```bash
podman compose --env-file ./compose.env up -d
```

---

**Stop a podman compose file**

```bash
podman compose --env-file ./compose.env down
```

---