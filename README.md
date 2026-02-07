# homebase
homeserver setup centered around komodo

# TODO

- [ ] firewall ufw keeps intefering with forwarding ~maybe a symptom of still having to expose komodo core ports
- [ ] cleanup and refactor komodo/compose.env. And why isn't it used automatically when the `env-file` is set to `compose.env` in the compose file.

# Podman Cheatsheet

Currently komodo is only supported (by me) as a rootful container

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