#!/usr/bin/env bash
set -euo pipefail

## Provision the rustdesk secrets from Bitwarden: TS_AUTHKEY -> .env.secret.
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
# Run from the rustdesk directory — compose.yaml references .env.secret relative
# to the project directory (tailscale service env_file).
#
# Bitwarden item (password field):
#   tailscale-authkey  -> TS_AUTHKEY in .env.secret
#
# The auth key is minted in the Tailscale admin console (Settings -> Keys):
# REUSABLE, NON-EPHEMERAL, pre-pinned tag `tag:homebase`. Non-ephemeral is
# required: ephemeral nodes are removed from the tailnet shortly after
# disconnecting (tailscale.com Docker-params doc) — a persistent subnet router
# needs a stable node identity. Tagged nodes have key expiry disabled by
# default. Missing item -> hard fail (nothing to generate: the key is minted
# by Tailscale).
#
# .env.secret is read by podman-compose at container creation (env_file), not
# by the container process — no `podman unshare chown` needed (the tailscale
# image runs as root, container root maps to the host user).

cd "$(dirname "$(readlink -f "$0")")"

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden session not unlocked — export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }

# --- CONFIG: Bitwarden item name + target file (gitignored) ---
BW_ITEM_AUTHKEY="tailscale-authkey"
ENV_FILE=".env.secret"

echo "[*] Fetching auth key from Bitwarden item '${BW_ITEM_AUTHKEY}'..."
AUTHKEY="$(bw get password "${BW_ITEM_AUTHKEY}" 2>/dev/null || true)"
[ -n "${AUTHKEY}" ] || { echo "[ERR] Empty/missing ${BW_ITEM_AUTHKEY} — create a REUSABLE NON-EPHEMERAL auth key tagged tag:homebase in the Tailscale admin console (Settings -> Keys) and save it as this item's password field"; exit 1; }

# Write atomically (secret -> owner-only). Never print the key.
umask 077
printf 'TS_AUTHKEY=%s\n' "${AUTHKEY}" > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

echo
echo "[✓] rustdesk secrets provisioned (${ENV_FILE}, 0600)."
echo "    New/changed .env.secret key -> podman-compose up -d --force-recreate"
echo "    (env is baked at container creation, a unit restart does NOT re-read it)."
