#!/usr/bin/env bash
set -euo pipefail

## Provision monitoring/.env.secret (gitignored, 0600) from Bitwarden — the
## Grafana admin password + the Grafana Authelia OIDC client secret (RAW) + the
## Alertmanager Telegram bot token. Mirrors the provision-*-secrets.sh pattern
## (Bitwarden -> gitignored env, 0600). Consumed by grafana + alertmanager
## (env_file in compose.yaml). The Telegram CHAT ID is not a secret and amtool
## cannot validate an env-expanded int64, so it is a literal in
## alertmanager/alertmanager.yml — this script prints it for you to set there.
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
## Run from the monitoring directory on the server.
##
## Also renders the file-based secrets consumed by the network-device scrape
## (gitignored, 0600; template + docs in docs/services.md):
##   ipmi/ipmi.yml               <- Bitwarden `bmc-ipmi` (username + password
##                                  fields) — the Supermicro BMC auth for
##                                  ipmi-exporter (no env expansion there, so
##                                  the auth lives in the rendered file)
##   vm/secrets/truenas-api-key  <- Bitwarden `truenas-api-key` (password
##                                  field) — READONLY key read by
##                                  export-truenas-stats.sh (pool state + disk
##                                  temps via the REST v2.0 compat API; the
##                                  25.x graphite stream carries neither)
##
## The same Bitwarden key also feeds the homepage widget
## (HOMEPAGE_VAR_TRUENAS_KEY in homepage/.env, provisioned manually per
## docs/services.md).
##
## Inputs (Bitwarden password fields; env overrides for testing):
##   grafana-admin-password        -> GF_SECURITY_ADMIN_PASSWORD (env override GF_SECURITY_ADMIN_PASSWORD)
##   authelia-oidc-grafana-secret  -> GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET (env override GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET)
##                                    (the argon2 digest of the SAME value is
##                                    provisioned into authelia/.env.secret by
##                                    provision-authelia-secrets.sh — same
##                                    Bitwarden item, stirling-pdf precedent)
##   telegram-bot-token            -> TELEGRAM_BOT_TOKEN (env override TELEGRAM_BOT_TOKEN)
##                                    AND alertmanager/bot_token (the file
##                                    Alertmanager's bot_token_file reads —
##                                    Alertmanager does not expand $(VAR) in
##                                    config, so the token must be a file)
##   telegram-chat-id              -> printed only (set it as the literal chat_id
##                                    in alertmanager/alertmanager.yml; env
##                                    override TELEGRAM_CHAT_ID)
##   bmc-ipmi                      -> ipmi/ipmi.yml (env overrides BMC_USER, BMC_PASS)
##   truenas-api-key               -> vm/secrets/truenas-api-key (env override TRUENAS_API_KEY)
##
## Missing items are generated and printed on stderr — save them to Bitwarden
## under the same names before the next run. The Grafana OIDC secret is generated
## hex (openssl rand -hex 32) to match the authelia-oidc-grafana-secret the
## provision-authelia-secrets.sh expects (hex avoids the +/ form-encoding class
## of bug documented for the Jellyfin SSO-Auth plugin).

cd "$(dirname "$(readlink -f "$0")")"

umask 077
ENV_FILE=".env.secret"

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden not unlocked — export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }

# resolve <item> <env-override> <gen-cmd> — fetch the Bitwarden password field;
# generate + print a save hint if missing. Progress on stderr, value on stdout.
resolve() {
  local item="$1" override="${2:-}" gentype="${3:-base64}" value
  if [ -n "${override}" ]; then printf '%s' "${override}"; return; fi
  value="$(bw get password "${item}" 2>/dev/null || true)"
  if [ -n "${value}" ]; then
    echo "[*] ${item}: fetched from Bitwarden" >&2
  else
    if [ "${gentype}" = "hex" ]; then value="$(openssl rand -hex 32)"; else value="$(openssl rand -base64 32 | tr -d '\n')"; fi
    echo "[!] ${item}: not in Bitwarden — generated. Save it as a Bitwarden" >&2
    echo "    item named '${item}' (password field) before the next run:" >&2
    echo "    ${value}" >&2
  fi
  printf '%s' "${value}"
}

# resolve_required <item> <field> <env-override> — fetch a Bitwarden field
# (password|username) that CANNOT be generated (it is created in a device UI:
# TrueNAS API key, BMC user). Fail closed with the creation hint.
resolve_required() {
  local item="$1" field="$2" override="${3:-}" value
  if [ -n "${override}" ]; then printf '%s' "${override}"; return; fi
  value="$(bw get "${field}" "${item}" 2>/dev/null || true)"
  [ -n "${value}" ] || { echo "[ERR] Bitwarden item '${item}' (${field} field) not found —" >&2; echo "      create the credential on the device first (see docs/services.md)." >&2; exit 1; }
  echo "[*] ${item} (${field}): fetched from Bitwarden" >&2
  printf '%s' "${value}"
}

echo "[*] Provisioning monitoring secrets -> ${ENV_FILE}"
GF_SECURITY_ADMIN_PASSWORD="$(resolve grafana-admin-password "${GF_SECURITY_ADMIN_PASSWORD:-}")"
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="$(resolve authelia-oidc-grafana-secret "${GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:-}" hex)"
TELEGRAM_BOT_TOKEN="$(resolve telegram-bot-token "${TELEGRAM_BOT_TOKEN:-}")"
TELEGRAM_CHAT_ID="$(resolve telegram-chat-id "${TELEGRAM_CHAT_ID:-}")"

[ -n "${GF_SECURITY_ADMIN_PASSWORD}" ] || { echo "[ERR] Empty GF_SECURITY_ADMIN_PASSWORD"; exit 1; }
[ -n "${GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}" ] || { echo "[ERR] Empty GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"; exit 1; }
[ -n "${TELEGRAM_BOT_TOKEN}" ] || { echo "[ERR] Empty TELEGRAM_BOT_TOKEN"; exit 1; }
[ -n "${TELEGRAM_CHAT_ID}" ] || { echo "[ERR] Empty TELEGRAM_CHAT_ID"; exit 1; }

{
  printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "${GF_SECURITY_ADMIN_PASSWORD}"
  printf 'GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=%s\n' "${GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "${TELEGRAM_BOT_TOKEN}"
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

# Telegram bot token as a FILE for Alertmanager's bot_token_file (gitignored,
# 0600). Alertmanager does NOT expand $(VAR) in config string/secret fields
# (probed v0.35.0 2026-11-18), so the token cannot live in the config as
# $(TELEGRAM_BOT_TOKEN) — it must be a file the receiver reads (getBotToken()
# TrimSpaces it). See alertmanager/alertmanager.yml.
printf '%s' "${TELEGRAM_BOT_TOKEN}" > alertmanager/bot_token.tmp
mv -f alertmanager/bot_token.tmp alertmanager/bot_token
chmod 0600 alertmanager/bot_token

# --- network-device scrape secrets (file-based, gitignored, 0600) ---
BMC_USER="$(resolve_required bmc-ipmi username "${BMC_USER:-}")"
BMC_PASS="$(resolve_required bmc-ipmi password "${BMC_PASS:-}")"
TRUENAS_API_KEY="$(resolve_required truenas-api-key password "${TRUENAS_API_KEY:-}")"

umask 077
mkdir -p ipmi vm/secrets
{
  echo "---"
  echo "# Rendered by provision-monitoring-secrets.sh from Bitwarden \`bmc-ipmi\`"
  echo "# (gitignored, 0600). Template: ipmi.yml.example. Docs: docs/services.md."
  echo "# v1.10.1 schema: per-module user/pass/driver/privilege/timeout (the"
  echo "# master-branch top-level \`auth:\` list and \`collector_timeout\` are"
  echo "# unknown fields there — probed at first deploy 2026-11-15). session"
  echo "# timeout 10s; a scrape can take up to timeout x #-of-collectors, the"
  echo "# VM scrape_timeout 30s is the outer bound."
  echo "modules:"
  echo "  autoconf:"
  printf '    user: "%s"\n' "${BMC_USER}"
  printf '    pass: "%s"\n' "${BMC_PASS}"
  echo '    driver: "LAN_2_0"'
  echo '    privilege: "admin"'
  echo "    timeout: 10000"
  echo "    collectors:"
  echo "    - bmc"
  echo "    - ipmi"
  echo "    - chassis"
  echo "    - sel"
  echo "    # NO dcmi: the freeipmi 1.6.15 bundled in the v1.10.1 image has no"
  echo "    # --get-power-reading option (probed 2026-11-19: \"unrecognized"
  echo "    # option\"), so the collector can never succeed — it timed out on"
  echo "    # every scrape since first deploy. The BMC itself answers fine."
} > ipmi/ipmi.yml.tmp
mv -f ipmi/ipmi.yml.tmp ipmi/ipmi.yml
chmod 0600 ipmi/ipmi.yml
printf '%s' "${TRUENAS_API_KEY}" > vm/secrets/truenas-api-key.tmp
mv -f vm/secrets/truenas-api-key.tmp vm/secrets/truenas-api-key
chmod 0600 vm/secrets/truenas-api-key

echo "[+] Wrote ${ENV_FILE} (Grafana admin pw + OIDC client secret + Telegram bot token)."
echo "[+] Wrote alertmanager/bot_token (Telegram bot token file for bot_token_file)."
echo "[+] Wrote ipmi/ipmi.yml (BMC auth) + vm/secrets/truenas-api-key (TrueNAS REST key for export-truenas-stats.sh)."
echo "    Telegram chat id (not a secret): ${TELEGRAM_CHAT_ID}"
echo "    Set it as the literal chat_id in alertmanager/alertmanager.yml (git)."
echo "    The Grafana OIDC RAW secret must match the argon2 digest in"
echo "    authelia/.env.secret (provision-authelia-secrets.sh, same Bitwarden"
echo "    item authelia-oidc-grafana-secret). Re-run that script after saving"
echo "    a generated secret, then force-recreate authelia."
