#!/usr/bin/env bash
set -euo pipefail

## Configure Wanderer's PocketBase OIDC auth method (Authelia SSO) via the
## PocketBase REST API — idempotent, re-runnable after stack recreation
## (the provider config lives in the PocketBase DB, not in a file).
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
# Run from the wanderer directory. Requires the PocketBase admin API
# reachable at PB_URL (default http://127.0.0.1:8090). The db service has
# no host port — start the loopback socat proxy first (docs/services.md,
# "Wanderer SSO"):
#
#   podman run -d --rm --name pb-admin-proxy --network wanderer-internal \
#     -p 127.0.0.1:8090:8090 docker.io/alpine/socat \
#     TCP-LISTEN:8090,fork TCP-CONNECT:db:8090
#
# Inputs:
#   Bitwarden  authelia-oidc-wanderer-secret  -> RAW OIDC client secret
#     (the argon2 digest of the same value is what authelia/config/
#     configuration.yml expects for the `wanderer` client)
#   .env.secret POCKETBASE_ADMIN_EMAIL / POCKETBASE_ADMIN_PASSWORD
#     (superuser credentials)
#   PB_CLIENT_SECRET env var overrides the Bitwarden fetch (testing).

cd "$(dirname "$(readlink -f "$0")")"

PB_URL="${PB_URL:-http://127.0.0.1:8090}"
PB_ADMIN_EMAIL="${PB_ADMIN_EMAIL:-admin@sseifried.link}"
AUTHHELIA_ISSUER="https://authelia.sseifried.link"
SLOT="oidc" # PocketBase registry slot (oidc|oidc2|oidc3) — the Name field
# MUST be a registry key ("Invalid or missing provider with name X"), and
# this is what Wanderer's OIDC_SCOPES/OIDC_TRUST_EMAIL env slots address.

[ -f .env.secret ] || { echo "[ERR] .env.secret missing — run ./provision-wanderer-secrets.sh"; exit 1; }
PB_ADMIN_PW="$(grep '^POCKETBASE_ADMIN_PASSWORD=' .env.secret | head -n1 | cut -d= -f2- || true)"
[ -n "${PB_ADMIN_PW}" ] || { echo "[ERR] POCKETBASE_ADMIN_PASSWORD missing in .env.secret"; exit 1; }

if [ -n "${PB_CLIENT_SECRET:-}" ]; then
  echo "[*] Using PB_CLIENT_SECRET env override"
else
  command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
  bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden session not unlocked — bw login && export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }
  PB_CLIENT_SECRET="$(bw get password authelia-oidc-wanderer-secret 2>/dev/null || true)"
  [ -n "${PB_CLIENT_SECRET}" ] || { echo "[ERR] Bitwarden item authelia-oidc-wanderer-secret empty/missing — run authelia/provision-authelia-secrets.sh and save the generated secret"; exit 1; }
fi

command -v curl >/dev/null || { echo "[ERR] curl not found"; exit 1; }
command -v python3 >/dev/null || { echo "[ERR] python3 not found (JSON handling)"; exit 1; }

echo "[*] Authenticating against ${PB_URL} as ${PB_ADMIN_EMAIL}..."
TOKEN="$(curl -sf "${PB_URL}/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"identity": sys.argv[1], "password": sys.argv[2]}))' "${PB_ADMIN_EMAIL}" "${PB_ADMIN_PW}")" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
[ -n "${TOKEN}" ] || { echo "[ERR] PocketBase superuser auth failed"; exit 1; }

echo "[*] Upserting OIDC auth method '${SLOT}' on the users collection..."
python3 - "${PB_URL}" "${TOKEN}" "${PB_CLIENT_SECRET}" "${AUTHHELIA_ISSUER}" "${SLOT}" <<'PY'
import json, sys, urllib.request, urllib.error

pb_url, token, secret, issuer, slot = sys.argv[1:6]

def api(path, method="GET", body=None):
    req = urllib.request.Request(
        pb_url + path, method=method,
        headers={"Authorization": token, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req) as r:
            out = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit("[ERR] %s %s -> HTTP %d\n%s" % (
            method, path, e.code, e.read().decode(errors="replace")))
    # PocketBase >= 0.23 wraps responses in {"data": ..., "status": ...}
    if isinstance(out, dict) and "data" in out and "status" in out:
        out = out["data"]
    return out

coll = api("/api/collections/users")
# flomp/wanderer-db vendors PocketBase 0.38.0 core (auth.NewOIDCProvider,
# registry slots oidc/oidc2/oidc3) but the fork's users collection carries a
# custom top-level `oauth2` field {providers, mappedFields, enabled}. The
# provider struct is FLAT and REDUCED — unknown JSON keys are silently
# dropped; what survives (verified by read-back) is:
#   name, displayName, clientId, clientSecret, authURL, tokenURL,
#   userInfoURL, pkce, extra
# Claim attrs (email / preferred_username / email_verified), scopes
# (openid profile email, overridable via the OIDC_SCOPES env slot) and the
# S256 PKCE method are PocketBase core defaults the fork does not expose.
oauth2 = coll.get("oauth2") or {}
providers = oauth2.get("providers") or []

provider = {
    "name": slot,
    "displayName": "Authelia",
    "clientId": "wanderer",
    "clientSecret": secret,
    "authURL": issuer + "/api/oidc/authorization",
    "tokenURL": issuer + "/api/oidc/token",
    "userInfoURL": issuer + "/api/oidc/userinfo",
    "pkce": True,
    "extra": {},
}

existing = next((p for p in providers if p.get("name") == slot), None)
if existing:
    # the fork's provider JSON carries no id/collectionId — carry over any
    # bookkeeping keys it does have
    for key in ("id", "collectionId"):
        if key in existing:
            provider[key] = existing[key]
    providers = [provider if p.get("name") == slot else p for p in providers]
    print("[*] Slot '%s' exists — updating in place" % slot)
else:
    providers.append(provider)
    print("[*] Slot '%s' is new — adding" % slot)

oauth2["providers"] = providers
oauth2["enabled"] = True
# PocketBase 0.22 PATCH requires the FULL collection record (name, type,
# fields, ... all mandatory) — send the GET record back with oauth2 replaced.
coll["oauth2"] = oauth2
api("/api/collections/users", "PATCH", coll)

# read back: the fork's struct drops unknown fields — verify the ones it
# keeps stuck. clientSecret is write-only (GET masks it), so check the rest.
check = api("/api/collections/users").get("oauth2") or {}
saved = next((p for p in check.get("providers", []) if p.get("name") == slot), None)
if not saved:
    sys.exit("[ERR] provider not present after PATCH")
for key in ("clientId", "authURL", "tokenURL", "userInfoURL", "displayName"):
    if saved.get(key) != provider[key]:
        sys.exit("[ERR] saved provider mismatch on %s: %s" % (key, saved))
if not saved.get("pkce"):
    sys.exit("[ERR] pkce not enabled on saved provider: %s" % saved)
print("[+] OIDC provider '%s' saved and enabled (button label on the"
      " Wanderer login page)" % slot)
PY

echo
echo "[✓] Wanderer SSO provisioned. Test: https://wanderer.sseifried.link ->"
echo "    login page -> '${SLOT}' button -> silent Authelia login."
echo "    Account migration (link the OIDC identity to the pre-existing"
echo "    account) — see docs/services.md, 'Wanderer SSO'."
