# Wallpaper images

Served by Homepage at `/images/...` via the `./config/images:/app/public/images`
mount (compose.yaml). Referenced from `settings.yaml` `background.image`.

- `wallpaper.jpg` — active background: "Qwantani night – Panorama", a dark
  night-mountain panorama (Kangchenjunga massif under the Milky Way) by Greg
  Zaal and Jarod Guest via Poly Haven, CC0, hosted on Wikimedia Commons
  (File:Qwantani night – Panorama (Greg Zaal and Jarod Guest via Poly Haven).jpg).
  Re-encoded from the Commons 3840px render to 3840x1920 baseline JPEG, ~1.7 MB.
  CC0 — no attribution required; source recorded here for provenance.
- `wallpaper.svg` — generated dark-slate fallback (muted gradients, no
  photography; resolution-independent).
- To swap the photo: drop a 16:9, >=3840px, <=2 MB jpg here (license-clean:
  Unsplash/Pexels/Pixabay, Wallhaven CC0, Wikimedia Commons PD/CC0), point
  `background.image` at it, and restart `podman-compose@homepage` — Homepage
  discovers local images only at container start.
- Replace files, never accumulate variants (binaries in git history).
