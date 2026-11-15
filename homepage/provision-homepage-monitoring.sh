#!/usr/bin/env bash
set -euo pipefail

## Upsert the Homepage monitoring-widget keys into homepage/.env (gitignored,
## mode 0600) from Bitwarden + args. Idempotent; preserves every other key
## (HOMEPAGE_ALLOWED_HOSTS, AdGuard, AUTH, OIDC). Mirrors the
## provision-*-secrets.sh pattern so the Grafana service-account key is never
## pasted by hand or written to a tracked file.
##
## The grafana widget (which replaced the uptimekuma + beszel widgets) reads
## committed dashboard panels via a Grafana SERVICE-ACCOUNT API key (viewer role,
## scoped to the homebase-overview dashboard). Create the key in Grafana
## (Administration -> Service accounts -> add a Viewer, generate a token), save
## it to Bitwarden `homepage-grafana-api-key`, then run this.
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
## Run from the homepage directory on the server.
##
## Inputs (env overrides):
##   GRAFANA_APIKEY  Grafana service-account key; default = Bitwarden
##                   homepage-grafana-api-key

cd "$(dirname "$(readlink -f "$0")")"

umask 077
ENV_FILE=".env"
[ -f "${ENV_FILE}" ] || { echo "[ERR] ${ENV_FILE} missing — homepage/.env must exist (OIDC keys)"; exit 1; }

if [ -z "${GRAFANA_APIKEY:-}" ]; then
  command -v bw >/dev/null || { echo "[ERR] bw not found and GRAFANA_APIKEY unset"; exit 1; }
  bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden not unlocked — export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }
  GRAFANA_APIKEY="$(bw get password homepage-grafana-api-key 2>/dev/null || true)"
  [ -n "${GRAFANA_APIKEY}" ] || { echo "[ERR] Bitwarden item homepage-grafana-api-key empty/missing — create a Grafana service-account key (Viewer) and save it there"; exit 1; }
fi

set_key() { # <key> <value> — replace in place if present, else append
  local key="$1" value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

# Drop the retired Uptime Kuma / Beszel widget keys (the grafana widget replaces
# them); upsert the Grafana key.
for k in HOMEPAGE_VAR_KUMA_SLUG HOMEPAGE_VAR_BESZEL_USER HOMEPAGE_VAR_BESZEL_PASS HOMEPAGE_VAR_BESZEL_SYSTEMID; do
  sed -i "/^${k}=/d" "${ENV_FILE}"
done
set_key HOMEPAGE_VAR_GRAFANA_APIKEY "${GRAFANA_APIKEY}"
chmod 0600 "${ENV_FILE}"

echo "[+] Upserted HOMEPAGE_VAR_GRAFANA_APIKEY into ${ENV_FILE} (dropped KUMA_SLUG/BESZEL_*)."
echo "    Next: podman-compose up -d --force-recreate   # new .env keys need a recreate"
