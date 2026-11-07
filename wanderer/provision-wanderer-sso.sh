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
SLOT="authelia" # authMethods slot name -> login button label + OIDC_* env slots

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
import json, sys, urllib.request

pb_url, token, secret, issuer, slot = sys.argv[1:6]

def api(path, method="GET", body=None):
    req = urllib.request.Request(
        pb_url + path, method=method,
        headers={"Authorization": token, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req) as r:
        out = json.load(r)
    # PocketBase >= 0.23 wraps responses in {"data": ..., "status": ...}
    if isinstance(out, dict) and "data" in out and "status" in out:
        out = out["data"]
    return out

coll = api("/api/collections/users")
# PocketBase 0.22 (wanderer-db fork): the collection record carries a
# top-level `oauth2` field {providers: [...], mappedFields, enabled} —
# NOT `options.authMethods` (0.23+). Unknown PATCH fields are silently
# ignored, so the shape must match the server.
oauth2 = coll.get("oauth2") or {}
providers = oauth2.get("providers") or []

provider = {
    "name": slot,
    "providerId": "oidc",
    "identity": slot,
    "params": {
        "clientId": "wanderer",
        "clientSecret": secret,
        "scopes": ["openid", "profile", "email"],
        "pkce": True,
        "pkceChallengeMethod": "S256",
        "authUrl": issuer + "/api/oidc/authorization",
        "tokenUrl": issuer + "/api/oidc/token",
        "userInfoUrl": issuer + "/api/oidc/userinfo",
        "emailAttr": "email",
        "usernameAttr": "preferred_username",
        "verifiedAttr": "email_verified",
    },
    "state": {},
}

existing = next((p for p in providers if p.get("name") == slot), None)
if existing:
    provider["id"] = existing["id"]
    provider["collectionId"] = existing.get("collectionId", coll["id"])
    providers = [provider if p.get("name") == slot else p for p in providers]
    print("[*] Slot '%s' exists — updating in place" % slot)
else:
    providers.append(provider)
    print("[*] Slot '%s' is new — adding" % slot)

oauth2["providers"] = providers
oauth2["enabled"] = True
api("/api/collections/users", "PATCH", {"oauth2": oauth2})

# read back: PocketBase strips unknown params fields — verify they stuck
check = api("/api/collections/users").get("oauth2") or {}
saved = next((p for p in check.get("providers", []) if p.get("name") == slot), None)
if not saved:
    sys.exit("[ERR] provider not present after PATCH")
missing = [k for k in provider["params"] if k not in saved.get("params", {})]
if missing:
    sys.exit("[ERR] params dropped by server (shape mismatch): %s" % missing)
print("[+] OIDC provider '%s' saved and enabled (button label on the"
      " Wanderer login page)" % slot)
PY

echo
echo "[✓] Wanderer SSO provisioned. Test: https://wanderer.sseifried.link ->"
echo "    login page -> '${SLOT}' button -> silent Authelia login."
echo "    Account migration (link the OIDC identity to the pre-existing"
echo "    account) — see docs/services.md, 'Wanderer SSO'."
