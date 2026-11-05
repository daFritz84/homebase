#!/usr/bin/env bash
set -euo pipefail

## Render config/bootstrap.ldif (committed template, {REPLACE_ME} placeholders)
## into config/bootstrap.rendered.ldif (gitignored) with this deployment's
## {SSHA} hashes, computed from .env.secret via slappasswd (slapd verifies
## LDIF passwords; osixia 1.5.0's OpenLDAP 2.4.57 has no argon2).
##
## The committed template never carries secrets; the rendered file is the
## runtime copy — apply it with ldapadd (piped from the host: the openldap
## container has no ./config mount):
##
##   ./render-ldif.sh
##   podman exec -i authelia_openldap_1 ldapadd -x \
##     -D "cn=admin,dc=sseifried,dc=link" -W < config/bootstrap.rendered.ldif
##
## Re-runnable: hashes are regenerated from the same passwords (slappasswd
## salts per run — harmless, ldapadd -c skips existing entries; password
## changes need ldapmodify replace: userPassword with a freshly rendered hash).

cd "$(dirname "$(readlink -f "$0")")"

[ -f .env.secret ] || { echo "[ERR] .env.secret missing — run ./provision-authelia-secrets.sh"; exit 1; }
OPENLDAP_IMAGE="$(awk '/^[[:space:]]*image:[[:space:]]*docker\.io\/osixia\/openldap/ {print $2; exit}' compose.yaml)"
[ -n "${OPENLDAP_IMAGE}" ] || { echo "[ERR] Cannot read the openldap image from compose.yaml — run from the service checkout"; exit 1; }

get() { grep "^$1=" .env.secret | head -n1 | cut -d= -f2-; }
ADMIN_PW="$(get LDAP_ADMIN_PASSWORD)"
LOGIN_PW="$(get AUTHHELIA_LOGIN_PASSWORD)"
[ -n "${ADMIN_PW}" ] && [ -n "${LOGIN_PW}" ] || { echo "[ERR] LDAP_ADMIN_PASSWORD / AUTHHELIA_LOGIN_PASSWORD missing in .env.secret"; exit 1; }

hash() { printf '%s\n' "$1" | podman run -i --rm --entrypoint /usr/sbin/slappasswd "${OPENLDAP_IMAGE}" -s -; }
ADMIN_HASH="$(hash "${ADMIN_PW}")"
LOGIN_HASH="$(hash "${LOGIN_PW}")"

umask 077
python3 - "${ADMIN_HASH}" "${LOGIN_HASH}" <<'PY'
import sys
ah, lh = sys.argv[1], sys.argv[2]
t = open('config/bootstrap.ldif').read()
parts = t.split('userPassword: {REPLACE_ME}')
assert len(parts) == 3, f"expected 2 userPassword placeholders, found {len(parts) - 1}"
out = parts[0] + 'userPassword: ' + ah + parts[1] + 'userPassword: ' + lh + parts[2]
assert '{REPLACE_ME}' not in out
open('config/bootstrap.rendered.ldif', 'w').write(out)
PY

echo "[+] config/bootstrap.rendered.ldif rendered (gitignored, 0600)"
echo "    apply: podman exec -i authelia_openldap_1 ldapadd -x -D \"cn=admin,dc=sseifried,dc=link\" -W < config/bootstrap.rendered.ldif"
