#!/usr/bin/env bash
set -euo pipefail

## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)

# --- CONFIG: Bitwarden item names ---
BW_ITEM_DB="komodo-db"       # has username + password
BW_ITEM_ADMIN="komodo-admin" # has password

# --- CONFIG: target files mounted into containers ---
SECRETS_DIR=".secrets"
FILE_DB_USER="${SECRETS_DIR}/komodo_db_user"
FILE_DB_PASS="${SECRETS_DIR}/komodo_db_pass"
FILE_ADMIN_USER="${SECRETS_DIR}/komodo_admin_user"
FILE_ADMIN_PASS="${SECRETS_DIR}/komodo_admin_pass"

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

echo "[*] Fetching DB username from Bitwarden item '${BW_ITEM_DB}'..."
DB_USER="$(bw get username "${BW_ITEM_DB}")"

echo "[*] Fetching DB password from Bitwarden item '${BW_ITEM_DB}'..."
DB_PASS="$(bw get password "${BW_ITEM_DB}")"

echo "[*] Fetching Komodo admin username from Bitwarden item '${BW_ITEM_ADMIN}'..."
ADMIN_USER="$(bw get username "${BW_ITEM_ADMIN}")"

echo "[*] Fetching Komodo admin password from Bitwarden item '${BW_ITEM_ADMIN}'..."
ADMIN_PASS="$(bw get password "${BW_ITEM_ADMIN}")"

# Basic sanity checks
[ -n "${DB_USER}" ] || { echo "[ERR] Empty DB username"; exit 1; }
[ -n "${DB_PASS}" ] || { echo "[ERR] Empty DB password"; exit 1; }
[ -n "${ADMIN_USER}" ] || { echo "[ERR] Empty admin username"; exit 1; }
[ -n "${ADMIN_PASS}" ] || { echo "[ERR] Empty admin password"; exit 1; }

# Write files atomically (avoid partial writes)
printf %s "${DB_USER}"    > "${FILE_DB_USER}.tmp"    && mv -f "${FILE_DB_USER}.tmp"    "${FILE_DB_USER}"
printf %s "${DB_PASS}"    > "${FILE_DB_PASS}.tmp"    && mv -f "${FILE_DB_PASS}.tmp"    "${FILE_DB_PASS}"
printf %s "${ADMIN_USER}" > "${FILE_ADMIN_USER}.tmp" && mv -f "${FILE_ADMIN_USER}.tmp" "${FILE_ADMIN_USER}"
printf %s "${ADMIN_PASS}" > "${FILE_ADMIN_PASS}.tmp" && mv -f "${FILE_ADMIN_PASS}.tmp" "${FILE_ADMIN_PASS}"

chmod 0444 "${FILE_DB_USER}" "${FILE_DB_PASS}" "${FILE_ADMIN_USER}" "${FILE_ADMIN_PASS}"

echo "[+] Wrote secrets:"
echo "    ${FILE_DB_USER}"
echo "    ${FILE_DB_PASS}"
echo "    ${FILE_ADMIN_USER}"
echo "    ${FILE_ADMIN_PASS}"
