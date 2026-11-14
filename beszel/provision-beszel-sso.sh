#!/usr/bin/env bash
set -euo pipefail

## Configure Beszel hub's Authelia OIDC provider via the PocketBase REST API —
## idempotent, re-runnable after stack recreation (the provider lives in the
## PocketBase DB, not a file). Mirrors wanderer/provision-wanderer-sso.sh:
## Beszel 0.21.2's users collection carries a TOP-LEVEL `oauth2` field
## {providers:[...], mappedFields, enabled} (verified by GET — users.options is
## null, so stock v0.23's options.oauth2Providers map is NOT used here). The
## admin UI hides this (collection create/edit controls off by default), which
## is why it is hard to find. The provider struct is FLAT/REDUCED — only
## name, displayName, clientId, clientSecret, authURL, tokenURL, userInfoURL,
## pkce, extra survive.
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
## Run from the beszel directory on the server. The hub publishes 127.0.0.1:8090.
##
## Inputs:
##   PB_ADMIN_EMAIL  superuser email (default s.seifried@gmx.at) — set to the
##                   one you created in the hub UI.
##   PB_ADMIN_PW     superuser password; default = Bitwarden beszel-superuser-password
##   PB_CLIENT_SECRET RAW OIDC client secret; default = Bitwarden
##                   authelia-oidc-beszel-secret (the argon2 digest of the same
##                   value is what authelia/config/configuration.yml expects for
##                   the `beszel` client).
##   PB_URL          default http://127.0.0.1:8090

cd "$(dirname "$(readlink -f "$0")")"

PB_URL="${PB_URL:-http://127.0.0.1:8090}"
PB_ADMIN_EMAIL="${PB_ADMIN_EMAIL:-s.seifried@gmx.at}"
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
# Beszel 0.21.2 bundles a PocketBase whose users collection carries a TOP-LEVEL
# `oauth2` field {providers:[...], mappedFields:{...}, enabled:bool} — the same
# shape as the Wanderer fork, NOT stock v0.23's options.oauth2Providers map
# (users.options is null here; a PATCH to it is silently dropped). The provider
# struct is FLAT/REDUCED — unknown keys are dropped; verified surviving keys:
# name, displayName, clientId, clientSecret, authURL, tokenURL, userInfoURL,
# pkce, extra.
oauth2 = coll.get("oauth2") or {}
providers = oauth2.get("providers") or []

provider = {
    "name": provider_name,
    "displayName": "Authelia",
    "clientId": client_id,
    "clientSecret": secret,
    "authURL": issuer + "/api/oidc/authorization",
    "tokenURL": issuer + "/api/oidc/token",
    "userInfoURL": issuer + "/api/oidc/userinfo",
    "pkce": True,
    "extra": {},
}

existing = next((p for p in providers if p.get("name") == provider_name), None)
if existing:
    for key in ("id", "collectionId"):
        if key in existing:
            provider[key] = existing[key]
    providers = [provider if p.get("name") == provider_name else p for p in providers]
    print("[*] Provider '%s' exists — updating in place" % provider_name)
else:
    providers.append(provider)
    print("[*] Provider '%s' is new — adding" % provider_name)

oauth2["providers"] = providers
oauth2["enabled"] = True
coll["oauth2"] = oauth2
api("/api/collections/users", "PATCH", coll)

# read back: clientSecret is write-only (GET masks it) — verify the rest.
check = api("/api/collections/users").get("oauth2") or {}
saved = next((p for p in check.get("providers", []) if p.get("name") == provider_name), None)
if not saved:
    sys.exit("[ERR] provider not present after PATCH")
for key in ("clientId", "authURL", "tokenURL", "userInfoURL", "displayName"):
    if saved.get(key) != provider[key]:
        sys.exit("[ERR] saved provider mismatch on %s: %s" % (key, saved))
if not saved.get("pkce"):
    sys.exit("[ERR] pkce not enabled on saved provider: %s" % saved)
if not check.get("enabled"):
    sys.exit("[ERR] oauth2.enabled not true after PATCH")
print("[+] OAuth2 provider '%s' saved and enabled (client_id=%s)" % (provider_name, client_id))
PY

echo
echo "[✓] Beszel SSO provisioned. Test: https://metrics.sseifried.link ->"
echo "    login page -> 'Authelia' button -> silent Authelia login (links the"
echo "    superuser by preferred_username). Keep the password as break-glass."
