#!/usr/bin/env bash
set -euo pipefail

## Quarterly restore drill — "a backup you never restored is a hope, not a
## plan" (docs/operations.md, "Backups"). Manual by design: the drill needs
## judgement (which service, how deep), so it is NOT on a timer.
##
## What it proves, end to end, against the LIVE offsite repo:
##   1. the app token + repo key decrypt the repo (restic restore latest);
##   2. every archive in the snapshot is a readable tar.gz (tar -tzf);
##   3. the navidrome SQLite DB passes PRAGMA integrity_check;
##   4. the authelia LDIF dump parses (non-empty, has dn: entries).
##
## Read-only against the repo; restores into a temp dir under /tmp and removes
## it. Run from the backup directory on the server:
##   ./restore-drill.sh

cd "$(dirname "$(readlink -f "$0")")"

[ -f .env.secret ] || { echo "[ERR] .env.secret missing — run ./provision-backup-secrets.sh"; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env.secret
set +a

command -v restic >/dev/null || { echo "[ERR] restic not found — run ./install-restic.sh"; exit 1; }
command -v python3 >/dev/null || { echo "[ERR] python3 not found"; exit 1; }

target="$(mktemp -d /tmp/restic-drill.XXXXXX)"
trap 'rm -rf "${target}"' EXIT

echo "[*] restic restore latest -> ${target}"
restic restore latest --target "${target}"

fails=0

echo "[*] tar integrity of every archive in the snapshot"
while IFS= read -r -d '' archive; do
  if tar -tzf "${archive}" >/dev/null 2>&1; then
    echo "    [ok] $(basename "${archive}")"
  else
    echo "    [FAIL] $(basename "${archive}")" >&2
    fails=$((fails + 1))
  fi
done < <(find "${target}" -name '*.tar.gz' -print0)

echo "[*] navidrome SQLite integrity_check"
navidrome_archive="$(find "${target}" -name 'navidrome-data-*.tar.gz' -print -quit)"
if [ -n "${navidrome_archive}" ]; then
  stage="$(mktemp -d "${target}/nd.XXXXXX")"
  if tar -xzf "${navidrome_archive}" -C "${stage}" 2>/dev/null; then
    db="$(find "${stage}" -name 'navidrome.db' -print -quit)"
    if [ -n "${db}" ]; then
      result="$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"PRAGMA integrity_check\").fetchone()[0])' "${db}" 2>/dev/null || echo error)"
      if [ "${result}" = "ok" ]; then
        echo "    [ok] navidrome.db integrity_check: ok"
      else
        echo "    [FAIL] navidrome.db integrity_check: ${result}" >&2
        fails=$((fails + 1))
      fi
    else
      echo "    [FAIL] navidrome.db not found in the archive" >&2
      fails=$((fails + 1))
    fi
  else
    echo "    [FAIL] navidrome archive did not extract" >&2
    fails=$((fails + 1))
  fi
else
  echo "    [FAIL] no navidrome archive in the snapshot" >&2
  fails=$((fails + 1))
fi

echo "[*] authelia LDIF dump parses"
authelia_archive="$(find "${target}" -name 'authelia-*.tar.gz' -print -quit)"
if [ -n "${authelia_archive}" ]; then
  stage="$(mktemp -d "${target}/au.XXXXXX")"
  if tar -xzf "${authelia_archive}" -C "${stage}" 2>/dev/null; then
    ldif="$(find "${stage}" -name 'ldap.ldif' -print -quit)"
    if [ -n "${ldif}" ] && [ -s "${ldif}" ] && grep -q '^dn: ' "${ldif}"; then
      echo "    [ok] ldap.ldif: $(grep -c '^dn: ' "${ldif}") entries"
    else
      echo "    [FAIL] ldap.ldif missing/empty/no dn: entries" >&2
      fails=$((fails + 1))
    fi
  else
    echo "    [FAIL] authelia archive did not extract" >&2
    fails=$((fails + 1))
  fi
else
  echo "    [FAIL] no authelia archive in the snapshot" >&2
  fails=$((fails + 1))
fi

echo
if [ "${fails}" = 0 ]; then
  echo "[✓] Restore drill PASS $(date -Is)"
else
  echo "[ERR] Restore drill FAIL: ${fails} check(s) failed" >&2
  exit 1
fi
