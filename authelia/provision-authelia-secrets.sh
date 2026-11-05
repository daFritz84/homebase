#!/usr/bin/env bash
set -euo pipefail

## Provision authelia secrets into .env.secret from Bitwarden.
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
# Run from the authelia directory — compose.yaml references .env.secret
# relative to the project directory.
#
# Each key is read from the password field of a Bitwarden item:
#   authelia-session-secret         -> AUTHELIA_SESSION_SECRET
#   authelia-storage-secret         -> AUTHELIA_STORAGE_ENCRYPTION_KEY
#   authelia-oidc-hmac-secret       -> AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET
#   authelia-ldap-admin-password    -> AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD
#                                    + LDAP_ADMIN_PASSWORD (same value)
#
# (No JWT secret: Authelia 4.38+ removed the top-level jwt_secret; the only
# remaining JWT secret is for password reset, which is disabled here.)
#
# Missing items are generated and printed on stderr — save them to Bitwarden
# under the same names before the next run.
#
# The OIDC client secret for Homepage (item: authelia-oidc-homepage-secret)
# is fetched/generated and argon2-hashed via the authelia image: the digest
# goes into .env.secret as HOMEPAGE_OIDC_CLIENT_SECRET_HASH (injected into
# configuration.yml by the template filter — the committed file keeps its
# placeholder), the RAW value is printed for homepage/.env as
# HOMEPAGE_OIDC_CLIENT_SECRET.
#
# The Authelia login password (LDIF_LOGIN_PASSWORD, for the LDIF
# userPassword) is generated once, kept in .env.secret across re-runs, and
# printed on first generation — save it to Bitwarden (authelia-login-password).
# render-ldif.sh hashes it (with LDAP_ADMIN_PASSWORD) into the rendered LDIF.
# Both names avoid the AUTHELIA_ prefix on purpose: Authelia validates every
# AUTHELIA_* env var as a config key and warns "not expected" on these.
#
# WARNING: AUTHELIA_STORAGE_ENCRYPTION_KEY encrypts 2FA secrets in the sqlite
# DB at rest. Rotating it after factors exist forces every user to re-enroll.
# Existing Bitwarden values are fetched, never regenerated.

cd "$(dirname "$(readlink -f "$0")")"

# Single source of truth for the image pin: compose.yaml. Dependabot's
# /authelia scope bumps only compose.yaml, so a pin hardcoded here (and in
# docs/services.md + config/bootstrap.ldif) would silently desync.
AUTHHELIA_IMAGE="$(awk '/^[[:space:]]*image:[[:space:]]*docker\.io\/authelia\// {print $2; exit}' compose.yaml)"
[ -n "${AUTHHELIA_IMAGE}" ] || { echo "[ERR] Cannot read the authelia image from compose.yaml — run from the authelia directory"; exit 1; }

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden session not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }

# --- CONFIG: target env file (gitignored) ---
ENV_FILE=".env.secret"

# Secrets -> owner-only from the start (tmp file included)
umask 077

gen() { openssl rand -base64 32 | tr -d '\n'; }

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

# hash_argon2 <value> — argon2id digest via the authelia image (stdout,
# "Digest: " prefix stripped). The CLI reads the password from an interactive
# tty ONLY (stdin is not supported), so the only non-interactive path is
# --password: the secret sits in the container's argv for the run's duration,
# readable via /proc/<pid>/cmdline by the owning user — acceptable on this
# single-admin host. Empty output when podman/the image is unavailable — the
# caller prints manual instructions then.
hash_argon2() {
  local value="$1" out
  out="$(podman run --rm "${AUTHHELIA_IMAGE}" authelia crypto hash generate argon2 --no-confirm --password "${value}" 2>/dev/null | tail -n 1)" || out=""
  printf '%s' "${out#Digest: }"
}

echo "[*] Provisioning authelia secrets -> ${ENV_FILE}"
AUTHELIA_SESSION_SECRET="$(resolve authelia-session-secret)"
AUTHELIA_STORAGE_ENCRYPTION_KEY="$(resolve authelia-storage-secret)"
AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET="$(resolve authelia-oidc-hmac-secret)"
LDAP_ADMIN_PASSWORD="$(resolve authelia-ldap-admin-password)"
AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD="${LDAP_ADMIN_PASSWORD}"

# --- OIDC client secret for Homepage: raw value -> homepage/.env, argon2
# digest -> .env.secret (template-filter injection into configuration.yml;
# the committed file keeps its placeholder) ---
echo "[*] OIDC client secret (Homepage):"
OIDC_HOMEPAGE_SECRET="$(resolve authelia-oidc-homepage-secret)"
[ -n "${OIDC_HOMEPAGE_SECRET}" ] || { echo "[ERR] Empty authelia-oidc-homepage-secret"; exit 1; }
OIDC_HOMEPAGE_HASH="$(hash_argon2 "${OIDC_HOMEPAGE_SECRET}")"
if [ -z "${OIDC_HOMEPAGE_HASH}" ]; then
  echo "[!] podman/image unavailable — hash it manually, then re-run:"
  echo "    podman run --rm ${AUTHHELIA_IMAGE} authelia crypto hash generate argon2 --no-confirm --password '<secret>'"
  exit 1
fi

# --- Authelia login password (LDIF userPassword): generated once, preserved
# across re-runs from the existing env file; render-ldif.sh hashes it ---
LDIF_LOGIN_PASSWORD=""
[ -f "${ENV_FILE}" ] && LDIF_LOGIN_PASSWORD="$(grep '^LDIF_LOGIN_PASSWORD=' "${ENV_FILE}" | head -n1 | cut -d= -f2- || true)"
LOGIN_PW_GENERATED=0
if [ -z "${LDIF_LOGIN_PASSWORD}" ]; then
  LDIF_LOGIN_PASSWORD="$(openssl rand -base64 18 | tr -d '\n')"
  LOGIN_PW_GENERATED=1
fi

# Basic sanity checks
[ -n "${AUTHELIA_SESSION_SECRET}" ] || { echo "[ERR] Empty AUTHELIA_SESSION_SECRET"; exit 1; }
[ -n "${AUTHELIA_STORAGE_ENCRYPTION_KEY}" ] || { echo "[ERR] Empty AUTHELIA_STORAGE_ENCRYPTION_KEY"; exit 1; }
[ -n "${AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET}" ] || { echo "[ERR] Empty AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET"; exit 1; }
[ -n "${LDAP_ADMIN_PASSWORD}" ] || { echo "[ERR] Empty LDAP_ADMIN_PASSWORD"; exit 1; }
[ -n "${LDIF_LOGIN_PASSWORD}" ] || { echo "[ERR] Empty LDIF_LOGIN_PASSWORD"; exit 1; }

# Write env file atomically (secrets -> owner-only). Re-running is idempotent
# as long as the keys live in Bitwarden; restart the stack after any change.
{
  printf 'AUTHELIA_SESSION_SECRET=%s\n' "${AUTHELIA_SESSION_SECRET}"
  printf 'AUTHELIA_STORAGE_ENCRYPTION_KEY=%s\n' "${AUTHELIA_STORAGE_ENCRYPTION_KEY}"
  printf 'AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET=%s\n' "${AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET}"
  printf 'AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD=%s\n' "${AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD}"
  printf 'LDAP_ADMIN_PASSWORD=%s\n' "${LDAP_ADMIN_PASSWORD}"
  printf 'HOMEPAGE_OIDC_CLIENT_SECRET_HASH=%s\n' "${OIDC_HOMEPAGE_HASH}"
  printf 'LDIF_LOGIN_PASSWORD=%s\n' "${LDIF_LOGIN_PASSWORD}"
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"
echo "[+] Wrote ${ENV_FILE} (incl. OIDC client_secret digest + login password)"

echo
echo "    -> paste the RAW OIDC value as HOMEPAGE_OIDC_CLIENT_SECRET in homepage/.env:"
echo "       ${OIDC_HOMEPAGE_SECRET}"
if [ "${LOGIN_PW_GENERATED}" = 1 ]; then
  echo "    -> NEW Authelia login password — save to Bitwarden (authelia-login-password):"
  echo "       ${LDIF_LOGIN_PASSWORD}"
fi

echo
echo "[✓] authelia secrets provisioned."
echo "    If keys were generated above, save them to Bitwarden now —"
echo "    AUTHELIA_STORAGE_ENCRYPTION_KEY rotation forces 2FA re-enrollment."
echo
echo "Next steps (see docs/services.md, 'Authelia (SSO)'):"
echo "  1. Generate the OIDC signing key pair (gitignored):"
echo "     mkdir -p config/keys"
echo "     podman run --rm -v \"\$(pwd)/config/keys:/keys\" ${AUTHHELIA_IMAGE} \\"
echo "       authelia crypto pair rsa generate --bits 2048 --directory /keys \\"
echo "       --file.private-key oidc.key --file.public-key oidc.pub"
echo "  2. Render the LDIF (fills the {REPLACE_ME} hashes from .env.secret, gitignored):"
echo "     ./render-ldif.sh"
echo "  3. Validate the config offline, then podman-compose up -d and ldapadd the"
echo "     RENDERED LDIF piped from the host (docs/services.md, 'First run')."
