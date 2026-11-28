# Wallpaper images

Served by Homepage at `/images/...` via the `./config/images:/app/public/images`
mount (compose.yaml). Referenced from `settings.yaml` `background.image`.

- `wallpaper.jpg` — ACTIVE background. **Gitignored runtime asset**: the
  server's copy is the source of truth (like AdGuard config drift); offsite
  backup via `homepage/backup-homepage.sh` (backup-all SERVICES list). The
  workstation keeps an untracked copy here for swaps.
  Current: "winter Austria" 4K wallpaper (wp15923325, wallpaper-site
  collection), user-provided local file (`~/Bilder/`). Wallpaper-site license:
  personal use only, not redistributable — the reason the file lives outside
  git (server-resident + backed up, never committed). Re-encoded from
  5120x2880 to 3840x2160 baseline JPEG, ~1.4 MB.
  (Previous: Grossglockner by Pavel Špindler, Wikimedia Commons, CC BY 3.0.)
- `wallpaper.svg` — generated dark-slate fallback, committed: keeps the
  directory tracked and a fresh checkout rendering without the jpg.
- Swap: drop a 16:9, >=3840px, <=2 MB jpg here (any license — the file is not
  committed), point `background.image` at it, restart `podman-compose@homepage`
  (Homepage discovers local images only at container start), run
  `backup-homepage.sh`, and record source + license here.
