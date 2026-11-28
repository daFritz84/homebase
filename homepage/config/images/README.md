# Wallpaper images

Served by Homepage at `/images/...` via the `./config/images:/app/public/images`
mount (compose.yaml). Referenced from `settings.yaml` `background.image`.

- `wallpaper.jpg` — ACTIVE background. **Gitignored runtime asset**: the
  server's copy is the source of truth (like AdGuard config drift); offsite
  backup via `homepage/backup-homepage.sh` (backup-all SERVICES list). The
  workstation keeps an untracked copy here for swaps.
  Current: **Grossglockner** (Austria's highest peak, Pasterze glacier side),
  photo by Pavel Špindler — Wikimedia Commons
  `File:Grossglockner - Rakousko - panoramio.jpg`, **CC BY 3.0**
  (attribution recorded here; not required in the UI). Re-encoded from the
  Commons 3840px render to 3840x2543 baseline JPEG, ~1.6 MB.
- `wallpaper.svg` — generated dark-slate fallback, committed: keeps the
  directory tracked and a fresh checkout rendering without the jpg.
- Swap: drop a 16:9, >=3840px, <=2 MB jpg here (any license — the file is not
  committed), point `background.image` at it, restart `podman-compose@homepage`
  (Homepage discovers local images only at container start), run
  `backup-homepage.sh`, and record source + license here.
