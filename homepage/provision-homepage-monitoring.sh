#!/usr/bin/env bash
set -euo pipefail

## Upsert the Homepage monitoring-widget keys into homepage/.env (gitignored,
## mode 0600) from Bitwarden + args. Idempotent; preserves every other key
## (HOMEPAGE_ALLOWED_HOSTS, AdGuard, AUTH, OIDC). Mirrors the
## provision-*-secrets.sh pattern so the Beszel superuser password is never
## pasted by hand or written to a tracked file.
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
## Run from the homepage directory on the server.
##
## Inputs (env overrides):
##   KUMA_SLUG        Uptime Kuma status-page slug (default homebase)
##   BESZEL_SYSTEMID  hub system id (default krq9xw74ik726hp)
##   BESZEL_USER      hub superuser email (default s.seifried@gmx.at)
##   BESZEL_PASS      from Bitwarden beszel-superuser-password

cd "$(dirname "$(readlink -f "$0")")"

umask 077
ENV_FILE=".env"
[ -f "${ENV_FILE}" ] || { echo "[ERR] ${ENV_FILE} missing — homepage/.env must exist (OIDC keys)"; exit 1; }

KUMA_SLUG="${KUMA_SLUG:-homebase}"
BESZEL_SYSTEMID="${BESZEL_SYSTEMID:-krq9xw74ik726hp}"
BESZEL_USER="${BESZEL_USER:-s.seifried@gmx.at}"

if [ -z "${BESZEL_PASS:-}" ]; then
  command -v bw >/dev/null || { echo "[ERR] bw not found and BESZEL_PASS unset"; exit 1; }
  bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }
  BESZEL_PASS="$(bw get password beszel-superuser-password 2>/dev/null || true)"
  [ -n "${BESZEL_PASS}" ] || { echo "[ERR] Bitwarden item beszel-superuser-password empty/missing"; exit 1; }
fi

set_key() { # <key> <value> — replace in place if present, else append
  local key="$1" value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

set_key HOMEPAGE_VAR_KUMA_SLUG "${KUMA_SLUG}"
set_key HOMEPAGE_VAR_BESZEL_USER "${BESZEL_USER}"
set_key HOMEPAGE_VAR_BESZEL_PASS "${BESZEL_PASS}"
set_key HOMEPAGE_VAR_BESZEL_SYSTEMID "${BESZEL_SYSTEMID}"
chmod 0600 "${ENV_FILE}"

echo "[+] Upserted monitoring keys into ${ENV_FILE} (KUMA_SLUG=${KUMA_SLUG}, BESZEL_SYSTEMID=${BESZEL_SYSTEMID})."
echo "    Next: podman-compose up -d --force-recreate   # new .env keys need a recreate"
