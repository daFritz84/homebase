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
## Inputs (Bitwarden password fields; env overrides for testing):
##   grafana-admin-password        -> GF_SECURITY_ADMIN_PASSWORD (env override GF_SECURITY_ADMIN_PASSWORD)
##   authelia-oidc-grafana-secret  -> GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET (env override GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET)
##                                    (the argon2 digest of the SAME value is
##                                    provisioned into authelia/.env.secret by
##                                    provision-authelia-secrets.sh — same
##                                    Bitwarden item, stirling-pdf precedent)
##   telegram-bot-token            -> TELEGRAM_BOT_TOKEN (env override TELEGRAM_BOT_TOKEN)
##   telegram-chat-id              -> printed only (set it as the literal chat_id
##                                    in alertmanager/alertmanager.yml; env
##                                    override TELEGRAM_CHAT_ID)
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

echo "[+] Wrote ${ENV_FILE} (Grafana admin pw + OIDC client secret + Telegram bot token)."
echo "    Telegram chat id (not a secret): ${TELEGRAM_CHAT_ID}"
echo "    Set it as the literal chat_id in alertmanager/alertmanager.yml (git)."
echo "    The Grafana OIDC RAW secret must match the argon2 digest in"
echo "    authelia/.env.secret (provision-authelia-secrets.sh, same Bitwarden"
echo "    item authelia-oidc-grafana-secret). Re-run that script after saving"
echo "    a generated secret, then force-recreate authelia."
