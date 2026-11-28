# Wallpaper images

Served by Homepage at `/images/...` via the `./config/images:/app/public/images`
mount (compose.yaml). Referenced from `settings.yaml` `background.image`.

- `wallpaper.svg` — generated dark-slate fallback (muted gradients, no
  photography; resolution-independent).
- To use a photo: drop a 16:9, >=3840px, <=2 MB jpg here (license-clean:
  Unsplash/Pexels/Pixabay, Wallhaven CC0, Wikimedia Commons PD), point
  `background.image` at it, and restart `podman-compose@homepage` — Homepage
  discovers local images only at container start.
- Replace files, never accumulate variants (binaries in git history).
