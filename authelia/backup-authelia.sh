#!/usr/bin/env bash
set -euo pipefail

## Back up the authelia stack (OpenLDAP LDIF dump + sqlite DB + OIDC signing
## keys) to a timestamped tar.gz. The sqlite DB holds the TOTP/WebAuthn
## factors and the LDAP directory holds the users — both are irreplaceable
## (see docs/operations.md, "Authelia backups").
##
## The service is stopped while archiving for a consistent snapshot and is
## restarted afterwards, even if the archive fails.
##
## Run from the service checkout (the directory containing compose.yaml and
## config/) — on the server that is the ~/src/homebase checkout of this repo.

cd "$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="${HOME}/.local/share/authelia/backups"
ARCHIVE="${BACKUP_DIR}/authelia-$(date +%F-%H%M).tar.gz"
LDAP_BASE_DN="dc=sseifried,dc=link"
# Single source of truth for the image pin: compose.yaml (Dependabot bumps
# compose only — a hardcoded pin here would dump newer volumes with stale
# slapd tooling; same pattern as provision-authelia-secrets.sh).
OPENLDAP_IMAGE="$(awk '/^[[:space:]]*image:[[:space:]]*docker\.io\/osixia\/openldap/ {print $2; exit}' compose.yaml)"
[ -n "${OPENLDAP_IMAGE}" ] || { echo "[ERR] Cannot read the openldap image from compose.yaml — run from the service checkout"; exit 1; }
# podman-compose prefixes the project name
DB_VOLUME="authelia_authelia-db"
OPENLDAP_DATA_VOLUME="authelia_openldap-data"
OPENLDAP_CONFIG_VOLUME="authelia_openldap-config"

[ -d config ] || { echo "[ERR] No config/ directory next to compose.yaml — run from the service checkout"; exit 1; }

# Archive contains secrets (signing keys, 2FA factors) — owner-only.
umask 077
mkdir -p "${BACKUP_DIR}"
STAGE="$(mktemp -d)"

restore_service() {
  echo "[*] Starting the service"
  podman-compose up -d
}
cleanup() { rm -rf "${STAGE}"; }
trap 'restore_service; cleanup' EXIT

echo "[*] Stopping the service"
podman-compose down

echo "[*] LDIF dump (offline slapcat from the openldap volumes)"
# The named volumes survive `podman-compose down`; the container does not, so
# --volumes-from authelia_openldap_1 would fail here ("no such container").
# Guard: a missing volume would make podman create an empty one and slapcat
# would silently emit an empty LDIF.
for volume in "${OPENLDAP_DATA_VOLUME}" "${OPENLDAP_CONFIG_VOLUME}"; do
  podman volume inspect "${volume}" >/dev/null 2>&1 || { echo "[ERR] Volume ${volume} missing — nothing to dump"; exit 1; }
done
# --entrypoint is REQUIRED: the osixia image's ENTRYPOINT is its light-
# baseimage startup tool, which runs the bootstrap scripts on EVERY start —
# with no env they would rewrite the live volumes (random admin password,
# default dc=example,dc=com base) before exec'ing the command. Bypassing the
# entrypoint runs slapcat truly offline against the mounted volumes.
podman run --rm --entrypoint /usr/sbin/slapcat \
  -v "${OPENLDAP_DATA_VOLUME}:/var/lib/ldap" \
  -v "${OPENLDAP_CONFIG_VOLUME}:/etc/ldap/slapd.d" \
  "${OPENLDAP_IMAGE}" \
  -F /etc/ldap/slapd.d -b "${LDAP_BASE_DN}" > "${STAGE}/ldap.ldif"

echo "[*] Copying sqlite DB volume"
mkdir -p "${STAGE}/db"
MOUNTPOINT="$(podman volume inspect "${DB_VOLUME}" --format '{{.Mountpoint}}')"
cp -a "${MOUNTPOINT}/." "${STAGE}/db/"

if [ -d config/keys ]; then
  echo "[*] Copying config/keys (OIDC signing key pair)"
  cp -a config/keys "${STAGE}/keys"
fi

echo "[*] Archiving -> ${ARCHIVE}"
tar czf "${ARCHIVE}" -C "${STAGE}" .

trap - EXIT
restore_service
cleanup

echo
echo "[✓] Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
