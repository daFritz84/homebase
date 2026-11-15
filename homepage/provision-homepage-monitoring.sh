#!/usr/bin/env bash
set -euo pipefail

## Clean the Homepage .env (gitignored, mode 0600) of the monitoring-widget keys
## that no longer exist. Idempotent; preserves every other key
## (HOMEPAGE_ALLOWED_HOSTS, AdGuard, AUTH, OIDC).
##
## The Monitoring card's widget is Homepage v2.8's `prometheusmetric` widget
## reading VictoriaMetrics directly (Prometheus-compatible API on the internal
## caddy-proxy alias, no auth) — it needs NO key, so this script only prunes:
##   - the retired Uptime Kuma / Beszel widget keys,
##   - HOMEPAGE_VAR_GRAFANA_APIKEY (the v1 grafana panel-stats widget that used
##     it was removed in Homepage v2 — v2's grafana widget is a status widget
##     needing Admin creds; do not reintroduce a key).
##
## Run from the homepage directory on the server.

cd "$(dirname "$(readlink -f "$0")")"

umask 077
ENV_FILE=".env"
[ -f "${ENV_FILE}" ] || { echo "[ERR] ${ENV_FILE} missing — homepage/.env must exist (OIDC keys)"; exit 1; }

for k in HOMEPAGE_VAR_KUMA_SLUG HOMEPAGE_VAR_BESZEL_USER HOMEPAGE_VAR_BESZEL_PASS \
         HOMEPAGE_VAR_BESZEL_SYSTEMID HOMEPAGE_VAR_GRAFANA_APIKEY; do
  sed -i "/^${k}=/d" "${ENV_FILE}"
done
chmod 0600 "${ENV_FILE}"

echo "[+] Pruned retired widget keys from ${ENV_FILE} (KUMA/BESZEL/GRAFANA_APIKEY)."
echo "    The prometheusmetric widget needs no key — next: podman-compose up -d --force-recreate"
