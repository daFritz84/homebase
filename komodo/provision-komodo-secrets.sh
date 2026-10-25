#!/usr/bin/env bash
set -euo pipefail

## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)

# --- CONFIG: Bitwarden item names ---
BW_ITEM_DB="komodo-db"       # has username + password
BW_ITEM_ADMIN="komodo-admin" # has password

# --- CONFIG: target env file (gitignored) ---
ENV_FILE=".env.secret"

# Secrets -> owner-only from the start (tmp file included)
umask 077

# Fetch Bitwarden credentials
echo "[*] Fetching DB username/password from Bitwarden item '${BW_ITEM_DB}'..."
DB_USER="$(bw get username "${BW_ITEM_DB}")"
DB_PASS="$(bw get password "${BW_ITEM_DB}")"

echo "[*] Fetching Komodo admin credentials from Bitwarden item '${BW_ITEM_ADMIN}'..."
ADMIN_USER="$(bw get username "${BW_ITEM_ADMIN}")"
ADMIN_PASS="$(bw get password "${BW_ITEM_ADMIN}")"

# Basic sanity checks
[ -n "${DB_USER}" ] || { echo "[ERR] Empty DB username"; exit 1; }
[ -n "${DB_PASS}" ] || { echo "[ERR] Empty DB password"; exit 1; }
[ -n "${ADMIN_USER}" ] || { echo "[ERR] Empty admin username"; exit 1; }
[ -n "${ADMIN_PASS}" ] || { echo "[ERR] Empty admin password"; exit 1; }

# Generate random secrets
gen() { openssl rand -base64 32 | tr -d '\n'; }

PASSKEY="$(gen)"
WEBHOOK="$(gen)"
JWT="$(gen)"

# Write env file atomically (secrets -> owner-only).
# NOTE: re-running regenerates passkey/webhook/JWT -> restart core AND periphery
# together afterwards so they stay in sync.
{
  printf 'MONGO_INITDB_ROOT_USERNAME=%s\n' "${DB_USER}"
  printf 'MONGO_INITDB_ROOT_PASSWORD=%s\n' "${DB_PASS}"
  printf 'KOMODO_DATABASE_USERNAME=%s\n' "${DB_USER}"
  printf 'KOMODO_DATABASE_PASSWORD=%s\n' "${DB_PASS}"
  printf 'KOMODO_INIT_ADMIN_USERNAME=%s\n' "${ADMIN_USER}"
  printf 'KOMODO_INIT_ADMIN_PASSWORD=%s\n' "${ADMIN_PASS}"
  printf 'KOMODO_PASSKEY=%s\n' "${PASSKEY}"
  printf 'PERIPHERY_PASSKEYS=%s\n' "${PASSKEY}"
  printf 'KOMODO_WEBHOOK_SECRET=%s\n' "${WEBHOOK}"
  printf 'KOMODO_JWT_SECRET=%s\n' "${JWT}"
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"
echo "[+] Wrote ${ENV_FILE}"

echo
echo "[✓] Komodo secrets provisioned."
