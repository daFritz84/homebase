#!/usr/bin/env bash
set -euo pipefail

## Provision wanderer secrets into .env.secret from Bitwarden.
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
# Run from the wanderer directory — compose.yaml references .env.secret
# relative to the project directory.
#
# Each key is read from the password field of a Bitwarden item:
#   wanderer-meili-key          -> MEILI_MASTER_KEY
#   wanderer-pb-encryption-key  -> POCKETBASE_ENCRYPTION_KEY
#   wanderer-pb-proxy-secret    -> POCKETBASE_PROXY_SECRET
#
# Missing items are generated and printed on stderr — save them to Bitwarden
# under the same names before the next run.
#
# WARNING: POCKETBASE_ENCRYPTION_KEY encrypts trail data at rest. Existing
# Bitwarden values are fetched, never regenerated — rotating the key after
# data exists makes the database unreadable.

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden session not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }

# --- CONFIG: target env file (gitignored) ---
ENV_FILE=".env.secret"

# Secrets -> owner-only from the start (tmp file included)
umask 077

# 24 random bytes -> exactly 32 base64 chars (no padding): wanderer requires
# POCKETBASE_ENCRYPTION_KEY to be exactly 32 bytes long.
gen() { openssl rand -base64 24 | tr -d '\n'; }

# resolve <item> — fetch the Bitwarden password field; generate + print a save
# hint if the item does not exist. Progress on stderr, value on stdout.
resolve() {
  local item="$1" value
  value="$(bw get password "${item}" 2>/dev/null || true)"
  if [ -n "${value}" ]; then
    echo "[*] ${item}: fetched from Bitwarden" >&2
  else
    value="$(gen)"
    echo "[!] ${item}: not in Bitwarden — generated. Save it as a Bitwarden" >&2
    echo "    item named '${item}' (password field) before the next run:" >&2
    echo "    ${value}" >&2
  fi
  printf '%s' "${value}"
}

echo "[*] Provisioning wanderer secrets -> ${ENV_FILE}"
MEILI_MASTER_KEY="$(resolve wanderer-meili-key)"
POCKETBASE_ENCRYPTION_KEY="$(resolve wanderer-pb-encryption-key)"
POCKETBASE_PROXY_SECRET="$(resolve wanderer-pb-proxy-secret)"

# Basic sanity checks
[ -n "${MEILI_MASTER_KEY}" ] || { echo "[ERR] Empty MEILI_MASTER_KEY"; exit 1; }
[ -n "${POCKETBASE_ENCRYPTION_KEY}" ] || { echo "[ERR] Empty POCKETBASE_ENCRYPTION_KEY"; exit 1; }
[ -n "${POCKETBASE_PROXY_SECRET}" ] || { echo "[ERR] Empty POCKETBASE_PROXY_SECRET"; exit 1; }

# Write env file atomically (secrets -> owner-only). Re-running is idempotent
# as long as the keys live in Bitwarden; restart all three services after any
# key change so db and web stay in sync.
{
  printf 'MEILI_MASTER_KEY=%s\n' "${MEILI_MASTER_KEY}"
  printf 'POCKETBASE_ENCRYPTION_KEY=%s\n' "${POCKETBASE_ENCRYPTION_KEY}"
  printf 'POCKETBASE_PROXY_SECRET=%s\n' "${POCKETBASE_PROXY_SECRET}"
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"
echo "[+] Wrote ${ENV_FILE}"

echo
echo "[✓] wanderer secrets provisioned."
echo "    If keys were generated above, save them to Bitwarden now —"
echo "    POCKETBASE_ENCRYPTION_KEY cannot be rotated without losing trail data."
