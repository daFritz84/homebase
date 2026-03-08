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
FILE_PASSKEY="$SECRETS_DIR/komodo_passkey"
FILE_WEBHOOK="$SECRETS_DIR/komodo_webhook_secret"
FILE_JWT="$SECRETS_DIR/komodo_jwt_secret"

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

# Fetch Bitwarden credentials
echo "[*] Fetching DB username/password from Bitwarden item '${BW_ITEM_DB}'..."
DB_USER="$(bw get username "${BW_ITEM_DB}")"
DB_PASS="$(bw get password "${BW_ITEM_DB}")"

echo "[*] Fetching Komodo admin username from Bitwarden item '${BW_ITEM_ADMIN}'..."
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

# Write all secrets atomically
write_secret() {
    local file="$1" val="$2"
    printf %s "$val" > "${file}.tmp"
    mv -f "${file}.tmp" "$file"
    chmod 0444 "$file"
    echo "[+] Wrote $file"
}

write_secret "$FILE_DB_USER"     "$DB_USER"
write_secret "$FILE_DB_PASS"     "$DB_PASS"
write_secret "$FILE_ADMIN_USER"  "$ADMIN_USER"
write_secret "$FILE_ADMIN_PASS"  "$ADMIN_PASS"
write_secret "$FILE_PASSKEY"     "$PASSKEY"
write_secret "$FILE_WEBHOOK"     "$WEBHOOK"
write_secret "$FILE_JWT"         "$JWT"

echo
echo "[✓] All secrets generated."
