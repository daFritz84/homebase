#!/usr/bin/env bash
set -euo pipefail

## Provision bookorbit secrets into .env.secret from Bitwarden.
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
# Run from the bookorbit directory — compose.yaml references .env.secret
# relative to the project directory.
#
# Each key is read from the password field of a Bitwarden item:
#   bookorbit-postgres-password   -> POSTGRES_PASSWORD
#   bookorbit-jwt-secret          -> JWT_SECRET
#   bookorbit-setup-token         -> SETUP_BOOTSTRAP_TOKEN
#
# Missing items are generated and printed on stderr — save them to Bitwarden
# under the same names before the next run. Generated values are hex
# (openssl rand -hex 32, upstream recommendation).
#
# SETUP_BOOTSTRAP_TOKEN gates the one-time setup wizard (first browser visit
# to https://bookorbit.sseifried.link) — keep it in Bitwarden afterwards.
# JWT_SECRET rotation invalidates all sessions (every user logged out).
# POSTGRES_PASSWORD changes need `podman-compose up -d --force-recreate`
# AND an ALTER USER in the running DB (the postgres image only applies the
# password on first init of an empty data dir).
#
# The OIDC provider is configured IN-APP (Settings > OIDC/SSO): paste the RAW
# value of the Bitwarden item authelia-oidc-bookorbit-secret (provisioned by
# ../authelia/provision-authelia-secrets.sh, client_id `bookorbit`) into the
# provider form there — it never lives in this file.

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden session not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }

# --- CONFIG: target env file (gitignored) ---
ENV_FILE=".env.secret"

# Secrets -> owner-only from the start (tmp file included)
umask 077

gen() { openssl rand -hex 32; }

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

echo "[*] Provisioning bookorbit secrets -> ${ENV_FILE}"
POSTGRES_PASSWORD="$(resolve bookorbit-postgres-password)"
JWT_SECRET="$(resolve bookorbit-jwt-secret)"
SETUP_BOOTSTRAP_TOKEN="$(resolve bookorbit-setup-token)"

# Basic sanity checks
[ -n "${POSTGRES_PASSWORD}" ] || { echo "[ERR] Empty POSTGRES_PASSWORD"; exit 1; }
[ -n "${JWT_SECRET}" ] || { echo "[ERR] Empty JWT_SECRET"; exit 1; }
[ -n "${SETUP_BOOTSTRAP_TOKEN}" ] || { echo "[ERR] Empty SETUP_BOOTSTRAP_TOKEN"; exit 1; }

# Write env file atomically (secrets -> owner-only). Re-running is idempotent
# as long as the keys live in Bitwarden; new/changed keys need
# `podman-compose up -d --force-recreate` (env is baked in at container
# creation, a unit restart does NOT re-read it).
{
  printf 'POSTGRES_PASSWORD=%s\n' "${POSTGRES_PASSWORD}"
  printf 'JWT_SECRET=%s\n' "${JWT_SECRET}"
  printf 'SETUP_BOOTSTRAP_TOKEN=%s\n' "${SETUP_BOOTSTRAP_TOKEN}"
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"
echo "[+] Wrote ${ENV_FILE}"

echo
echo "[✓] bookorbit secrets provisioned."
echo "    If keys were generated above, save them to Bitwarden now —"
echo "    SETUP_BOOTSTRAP_TOKEN gates the one-time setup wizard (keep it in"
echo "    the vault), JWT_SECRET rotation invalidates all sessions."
echo "    The OIDC client secret is NOT here: paste the RAW value of the"
echo "    Bitwarden item authelia-oidc-bookorbit-secret into BookOrbit's"
echo "    Settings > OIDC/SSO provider form (client_id bookorbit)."
