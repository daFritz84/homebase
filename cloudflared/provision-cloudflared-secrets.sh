#!/usr/bin/env bash
set -euo pipefail

## Provision the cloudflared tunnel credentials from Bitwarden.
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
# Run from the cloudflared directory — compose.yaml bind-mounts
# ./credentials.json relative to the project directory.
#
# Bitwarden item (password field, single-line JSON):
#   cloudflared-tunnel-credentials  -> credentials.json
#
# The JSON is the tunnel credentials file created on the WORKSTATION by
# `cloudflared tunnel create homebase` (~/.cloudflared/<uuid>.json). The
# account cert (~/.cloudflared/cert.pem) is needed for tunnel management
# only, never on the server — keep it in Bitwarden (cloudflared-account-cert).
# Missing item -> hard fail (nothing to generate: the credentials are minted
# by Cloudflare at tunnel creation).

cd "$(dirname "$(readlink -f "$0")")"

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden session not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }

# --- CONFIG: Bitwarden item name + target file (gitignored) ---
BW_ITEM_CREDENTIALS="cloudflared-tunnel-credentials"
CRED_FILE="credentials.json"

echo "[*] Fetching tunnel credentials from Bitwarden item '${BW_ITEM_CREDENTIALS}'..."
CREDENTIALS="$(bw get password "${BW_ITEM_CREDENTIALS}" 2>/dev/null || true)"
[ -n "${CREDENTIALS}" ] || { echo "[ERR] Empty/missing ${BW_ITEM_CREDENTIALS} — create the tunnel on the workstation (cloudflared tunnel create homebase) and save ~/.cloudflared/<uuid>.json as this item's password field"; exit 1; }

# Write atomically (secret -> owner-only)
umask 077
printf '%s\n' "${CREDENTIALS}" > "${CRED_FILE}.tmp"
mv -f "${CRED_FILE}.tmp" "${CRED_FILE}"
chmod 0600 "${CRED_FILE}"

# The image runs as nonroot uid 65532 (the -nonroot variant was merged into
# the main tag); rootless Podman maps it to a subuid, which cannot read a
# 0600 file owned by the host user. Hand the file to that uid (same pattern
# as wanderer's `podman unshare chown 1000:1000`). The file stays gitignored
# and secret; re-running this script replaces it (the directory is owned by
# the host user, so mv works).
if command -v podman >/dev/null; then
  podman unshare chown 65532:65532 "${CRED_FILE}"
  echo "[+] Wrote ${CRED_FILE} (0600, chowned to container uid 65532 for the nonroot image)"
else
  echo "[!] podman not found — run manually before the first start:"
  echo "    podman unshare chown 65532:65532 ${CRED_FILE}"
  echo "[+] Wrote ${CRED_FILE} (0600)"
fi

echo
echo "[✓] cloudflared secrets provisioned."
echo "    Next: podman-compose up -d, then podman-compose systemd +"
echo "    systemctl --user enable --now podman-compose@cloudflared"
echo "    (see docs/services.md, 'Cloudflare Tunnel (cloudflared)')."
