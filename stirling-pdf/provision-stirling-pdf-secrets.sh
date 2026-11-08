#!/usr/bin/env bash
set -euo pipefail

## Provision stirling-pdf secrets into .env.secret from Bitwarden.
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
# Run from the stirling-pdf directory — compose.yaml references .env.secret
# relative to the project directory.
#
# Each key is read from the password field of a Bitwarden item:
#   stirling-pdf-admin-password        -> SECURITY_INITIALLOGIN_PASSWORD
#   authelia-oidc-stirling-pdf-secret  -> SECURITY_OAUTH2_CLIENTSECRET
#
# SECURITY_INITIALLOGIN_USERNAME/PASSWORD preset the first admin account —
# the upstream default admin/stirling must never survive. They are IGNORED
# once users exist, so provision BEFORE the first start.
#
# SECURITY_OAUTH2_CLIENTSECRET is the RAW OIDC client secret of the
# `stirling-pdf` Authelia client. The matching argon2 digest
# (STIRLING_OIDC_CLIENT_SECRET_HASH) lives in authelia/.env.secret, and the
# Bitwarden item is provisioned by ../authelia/provision-authelia-secrets.sh:
# run that script first, or save a value generated here to Bitwarden and
# re-run the authelia script afterwards (then podman-compose up -d
# --force-recreate in authelia/ — new env key) so digest and raw value stay
# in sync.
#
# Missing items are generated and printed on stderr — save them to Bitwarden
# under the same names before the next run.

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden session not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }

# --- CONFIG: target env file (gitignored) ---
ENV_FILE=".env.secret"

# Secrets -> owner-only from the start (tmp file included)
umask 077

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

echo "[*] Provisioning stirling-pdf secrets -> ${ENV_FILE}"
SECURITY_INITIALLOGIN_USERNAME="admin"
SECURITY_INITIALLOGIN_PASSWORD="$(resolve stirling-pdf-admin-password)"
SECURITY_OAUTH2_CLIENTSECRET="$(resolve authelia-oidc-stirling-pdf-secret)"

# Basic sanity checks
[ -n "${SECURITY_INITIALLOGIN_PASSWORD}" ] || { echo "[ERR] Empty SECURITY_INITIALLOGIN_PASSWORD"; exit 1; }
[ -n "${SECURITY_OAUTH2_CLIENTSECRET}" ] || { echo "[ERR] Empty SECURITY_OAUTH2_CLIENTSECRET"; exit 1; }

# Write env file atomically (secrets -> owner-only). Re-running is idempotent
# as long as the keys live in Bitwarden; new/changed keys need
# `podman-compose up -d --force-recreate` (env is baked in at container
# creation, a unit restart does NOT re-read it).
{
  printf 'SECURITY_INITIALLOGIN_USERNAME=%s\n' "${SECURITY_INITIALLOGIN_USERNAME}"
  printf 'SECURITY_INITIALLOGIN_PASSWORD=%s\n' "${SECURITY_INITIALLOGIN_PASSWORD}"
  printf 'SECURITY_OAUTH2_CLIENTSECRET=%s\n' "${SECURITY_OAUTH2_CLIENTSECRET}"
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"
echo "[+] Wrote ${ENV_FILE}"

echo
echo "[✓] stirling-pdf secrets provisioned."
echo "    If keys were generated above, save them to Bitwarden now —"
echo "    authelia-oidc-stirling-pdf-secret must match the argon2 digest in"
echo "    authelia/.env.secret: re-run ../authelia/provision-authelia-secrets.sh"
echo "    afterwards, then podman-compose up -d --force-recreate in authelia/."
echo "    SECURITY_INITIALLOGIN_* are ignored once users exist — set them"
echo "    before the first start."
