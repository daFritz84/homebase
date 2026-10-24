#!/usr/bin/env bash
set -euo pipefail

## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)

# --- CONFIG: Bitwarden item names ---
BW_ITEM_TOKEN="caddy-cloudflare-token" # password field holds the Cloudflare API token

# --- CONFIG: target env file (gitignored) ---
ENV_FILE=".env"

# ACME registration email (not a secret) — pass via environment:
#   ACME_EMAIL="you@example.com" ./provision-caddy-secrets.sh
ACME_EMAIL="${ACME_EMAIL:-}"

# ACME CA directory — production by default; set to the staging CA for bring-up testing:
#   ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory" ./provision-caddy-secrets.sh
ACME_CA="${ACME_CA:-https://acme-v02.api.letsencrypt.org/directory}"

# Fetch Cloudflare API token
echo "[*] Fetching Cloudflare API token from Bitwarden item '${BW_ITEM_TOKEN}'..."
TOKEN="$(bw get password "${BW_ITEM_TOKEN}")"

# Basic sanity checks
[ -n "${TOKEN}" ] || { echo "[ERR] Empty Cloudflare API token"; exit 1; }
[ -n "${ACME_EMAIL}" ] || { echo "[ERR] Set ACME_EMAIL env var before running (ACME registration email)"; exit 1; }

# Write env file atomically (token is a secret -> owner-only)
umask 077
printf 'CF_API_TOKEN=%s\nACME_EMAIL=%s\nACME_CA=%s\n' "${TOKEN}" "${ACME_EMAIL}" "${ACME_CA}" > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"
echo "[+] Wrote ${ENV_FILE}"

echo
echo "[✓] Caddy secrets provisioned."
