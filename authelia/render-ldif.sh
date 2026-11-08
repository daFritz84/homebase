#!/usr/bin/env bash
set -euo pipefail

## Render config/bootstrap.ldif (committed template, {REPLACE_ME} placeholders)
## into config/bootstrap.rendered.ldif (gitignored) with this deployment's
## {SSHA} hashes, computed from .env.secret with python3 hashlib (slapd
## verifies LDIF passwords; osixia 1.5.0's OpenLDAP 2.4.57 has no argon2).
##
## Do NOT hash via the openldap image's slappasswd: its output is a {SSHA}
## payload that slapd 2.4.57 rejects on simple bind (slappasswd -v accepts
## its own hashes, so the breakage is invisible offline — every user login
## 49s). The python SSHA (SHA1(pw+salt) || salt, 4-byte salt) is what slapd
## verifies; the admin entry only ever worked because osixia's startup
## rewrites the admin password with slapd's internal pw module.
##
## The committed template never carries secrets; the rendered file is the
## runtime copy — apply it with ldapadd (piped from the host: the openldap
## container has no ./config mount):
##
##   ./render-ldif.sh
##   podman exec -i authelia_openldap_1 ldapadd -x \
##     -D "cn=admin,dc=sseifried,dc=link" -W < config/bootstrap.rendered.ldif
##
## Re-runnable: hashes are regenerated from the same passwords (random salt
## per run — harmless, ldapadd -c skips existing entries; password changes
## need ldapmodify replace: userPassword with a freshly rendered hash).

cd "$(dirname "$(readlink -f "$0")")"

[ -f .env.secret ] || { echo "[ERR] .env.secret missing — run ./provision-authelia-secrets.sh"; exit 1; }
command -v python3 >/dev/null || { echo "[ERR] python3 not found (SSHA hashing)"; exit 1; }

get() { grep "^$1=" .env.secret | head -n1 | cut -d= -f2-; }
ADMIN_PW="$(get LDAP_ADMIN_PASSWORD)"
LOGIN_PW="$(get LDIF_LOGIN_PASSWORD)"
[ -n "${ADMIN_PW}" ] && [ -n "${LOGIN_PW}" ] || { echo "[ERR] LDAP_ADMIN_PASSWORD / LDIF_LOGIN_PASSWORD missing in .env.secret"; exit 1; }

hash() { python3 -c 'import base64, hashlib, os, sys
pw = sys.argv[1].encode()
salt = os.urandom(4)
print("{SSHA}" + base64.b64encode(hashlib.sha1(pw + salt).digest() + salt).decode())' "$1"; }
ADMIN_HASH="$(hash "${ADMIN_PW}")"
LOGIN_HASH="$(hash "${LOGIN_PW}")"

umask 077
python3 - "${ADMIN_HASH}" "${LOGIN_HASH}" <<'PY'
import sys
ah, lh = sys.argv[1], sys.argv[2]
t = open('config/bootstrap.ldif').read()
# positional: placeholders appear in file order — cn=admin, uid=sseifried
# (assert pins that order; adding a user = extend this split)
parts = t.split('userPassword: {REPLACE_ME}')
assert len(parts) == 3, f"expected 2 userPassword placeholders, found {len(parts) - 1}"
out = (parts[0] + 'userPassword: ' + ah + parts[1] + 'userPassword: ' + lh + parts[2])
# the template header documents {REPLACE_ME} in prose — only active LDIF
# lines (non-#) must be placeholder-free
assert all('{REPLACE_ME}' not in l for l in out.splitlines() if not l.lstrip().startswith('#')), "unfilled placeholder on an active LDIF line"
open('config/bootstrap.rendered.ldif', 'w').write(out)
PY

echo "[+] config/bootstrap.rendered.ldif rendered (gitignored, 0600)"
echo "    apply: podman exec -i authelia_openldap_1 ldapadd -x -D \"cn=admin,dc=sseifried,dc=link\" -W < config/bootstrap.rendered.ldif"
