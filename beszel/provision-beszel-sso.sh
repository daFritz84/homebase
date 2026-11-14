#!/usr/bin/env bash
set -euo pipefail

## Configure Beszel hub's Authelia OIDC provider via the PocketBase REST API —
## idempotent, re-runnable after stack recreation (the provider lives in the
## PocketBase DB, not a file). Mirrors wanderer/provision-wanderer-sso.sh, but
## Beszel is STOCK PocketBase v0.23: the provider lives in the users collection's
## options.oauth2Providers map (the Wanderer fork uses a custom top-level
## `oauth2` field — do NOT copy that shape). The UI hides this (collection
## create/edit controls are off by default), which is why it is hard to find.
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
## Run from the beszel directory on the server. The hub publishes 127.0.0.1:8090.
##
## Inputs:
##   PB_ADMIN_EMAIL  superuser email (default admin@sseifried.link) — set to the
##                   one you created in the hub UI.
##   PB_ADMIN_PW     superuser password; default = Bitwarden beszel-superuser-password
##   PB_CLIENT_SECRET RAW OIDC client secret; default = Bitwarden
##                   authelia-oidc-beszel-secret (the argon2 digest of the same
##                   value is what authelia/config/configuration.yml expects for
##                   the `beszel` client).
##   PB_URL          default http://127.0.0.1:8090

cd "$(dirname "$(readlink -f "$0")")"

PB_URL="${PB_URL:-http://127.0.0.1:8090}"
PB_ADMIN_EMAIL="${PB_ADMIN_EMAIL:-admin@sseifried.link}"
AUTHHELIA_ISSUER="https://authelia.sseifried.link"
PROVIDER="authelia"   # oauth2Providers map key + login-page provider name
CLIENT_ID="beszel"    # must match authelia client_id in configuration.yml

command -v curl >/dev/null || { echo "[ERR] curl not found"; exit 1; }
command -v python3 >/dev/null || { echo "[ERR] python3 not found (JSON handling)"; exit 1; }

if [ -z "${PB_ADMIN_PW:-}" ]; then
  command -v bw >/dev/null || { echo "[ERR] bw not found and PB_ADMIN_PW unset"; exit 1; }
  bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }
  PB_ADMIN_PW="$(bw get password beszel-superuser-password 2>/dev/null || true)"
  [ -n "${PB_ADMIN_PW}" ] || { echo "[ERR] Bitwarden item beszel-superuser-password empty/missing"; exit 1; }
fi
if [ -z "${PB_CLIENT_SECRET:-}" ]; then
  command -v bw >/dev/null || { echo "[ERR] bw not found and PB_CLIENT_SECRET unset"; exit 1; }
  bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden not unlocked"; exit 1; }
  PB_CLIENT_SECRET="$(bw get password authelia-oidc-beszel-secret 2>/dev/null || true)"
  [ -n "${PB_CLIENT_SECRET}" ] || { echo "[ERR] Bitwarden item authelia-oidc-beszel-secret empty/missing — run authelia/provision-authelia-secrets.sh and save the generated secret"; exit 1; }
fi

echo "[*] Authenticating against ${PB_URL} as ${PB_ADMIN_EMAIL}..."
AUTH_BODY="$(python3 -c 'import json,sys; print(json.dumps({"identity": sys.argv[1], "password": sys.argv[2]}))' "${PB_ADMIN_EMAIL}" "${PB_ADMIN_PW}")"
TOKEN="$(curl -sf "${PB_URL}/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' -d "${AUTH_BODY}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d.get("data",d); print(d.get("token",""))')"
[ -n "${TOKEN}" ] || { echo "[ERR] PocketBase superuser auth failed (check PB_ADMIN_EMAIL/PB_ADMIN_PW)"; exit 1; }

echo "[*] Upserting OAuth2 provider '${PROVIDER}' on the users collection..."
python3 - "${PB_URL}" "${TOKEN}" "${PB_CLIENT_SECRET}" "${AUTHHELIA_ISSUER}" "${PROVIDER}" "${CLIENT_ID}" <<'PY'
import json, sys, urllib.request, urllib.error

pb_url, token, secret, issuer, provider_name, client_id = sys.argv[1:7]

def api(path, method="GET", body=None):
    req = urllib.request.Request(
        pb_url + path, method=method,
        headers={"Authorization": token, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req) as r:
            out = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit("[ERR] %s %s -> HTTP %d\n%s" % (method, path, e.code, e.read().decode(errors="replace")))
    if isinstance(out, dict) and "data" in out and "status" in out:
        out = out["data"]
    return out

coll = api("/api/collections/users")
options = coll.get("options") or {}
providers = options.get("oauth2Providers") or {}

provider = {
    "name": provider_name,
    "type": "oidc",
    "issuerName": "Authelia",
    "issuerURL": issuer,
    "clientId": client_id,
    "clientSecret": secret,
    "scopes": "openid profile email",
    "authURL": issuer + "/api/oidc/authorization",
    "tokenURL": issuer + "/api/oidc/token",
    "userInfoURL": issuer + "/api/oidc/userinfo",
    "pkce": True,
    "groupsAttribute": "groups",
    "usernameAttribute": "preferred_username",
    "emailTokenFile": "",
    "button": {"show": True, "icon": "", "label": "Authelia", "color": ""},
}

if provider_name in providers:
    print("[*] Provider '%s' exists — updating in place" % provider_name)
else:
    print("[*] Provider '%s' is new — adding" % provider_name)
providers[provider_name] = provider
options["oauth2Providers"] = providers
coll["options"] = options
api("/api/collections/users", "PATCH", coll)

# read back: clientSecret is write-only (GET masks it) — verify the rest.
check = (api("/api/collections/users").get("options") or {}).get("oauth2Providers") or {}
saved = check.get(provider_name)
if not saved:
    sys.exit("[ERR] provider not present after PATCH")
for key in ("clientId", "authURL", "tokenURL", "userInfoURL", "issuerURL", "usernameAttribute"):
    if saved.get(key) != provider[key]:
        sys.exit("[ERR] saved provider mismatch on %s: %s" % (key, saved))
if not saved.get("pkce"):
    sys.exit("[ERR] pkce not enabled on saved provider: %s" % saved)
print("[+] OAuth2 provider '%s' saved (client_id=%s, usernameAttribute=preferred_username)"
      % (provider_name, client_id))
PY

echo
echo "[✓] Beszel SSO provisioned. Test: https://metrics.sseifried.link ->"
echo "    login page -> 'Authelia' button -> silent Authelia login (links the"
echo "    superuser by preferred_username). Keep the password as break-glass."
