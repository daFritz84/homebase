#!/usr/bin/env bash
set -euo pipefail

## Provision backup/.env.secret (gitignored, 0600) from Bitwarden — the restic
## repo encryption key + the Hetzner Storage Share app token. Mirrors the
## provision-*-secrets.sh pattern (Bitwarden -> gitignored env, 0600).
## Consumed by run-weekly-backups.sh, run-verify.sh, restore-drill.sh and
## export-backup-stats.sh (sourced with `set -a`).
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
## Run from the backup directory on the server.
##
## Inputs:
##   restic-backup-password       -> RESTIC_PASSWORD (env override
##                                   RESTIC_PASSWORD). Generated hex (openssl
##                                   rand -hex 32) when missing — hex avoids
##                                   the +/ form-encoding class of bug
##                                   documented for the Jellyfin SSO-Auth
##                                   plugin (docs/operations.md). Save a
##                                   generated value to Bitwarden under the
##                                   same name before the next run: losing it
##                                   makes the offsite repo UNREADABLE.
##   nextcloud-backup-app-token   -> NEXTCLOUD_APP_TOKEN (env override
##                                   NEXTCLOUD_APP_TOKEN). CANNOT be generated
##                                   — create it in the Storage Share web UI
##                                   (Settings -> Security -> Devices &
##                                   sessions / tokens) for the DAV user.
##
## Non-secret literals (env overrides for testing; placeholders fail closed):
##   NEXTCLOUD_HOST  the Storage Share host, e.g. cloud-XXXXXXXX.hbts.net
##   NEXTCLOUD_USER  the DAV user of the backup share
##
## Rendered keys:
##   RESTIC_REPOSITORY   rclone:homebase:homebase   (restic REMOVED its native
##                       webdav backend in 0.18.0 — 0.19/0.20 have none — so
##                       the target is reached via restic's supported rclone
##                       backend; remote `homebase`, repo path `homebase` in
##                       the DAV home)
##   RCLONE_CONFIG_HOMEBASE_TYPE / _VENDOR / _URL / _USER / _PASS
##                       the webdav remote configured ENTIRELY via env vars
##                       (rclone's env-var remote config — no rclone.conf
##                       file; restic spawns rclone with this environment,
##                       so the app token never lands in process cmdline
##                       args/logs and never lives outside this 0600 file).
##                       _PASS is the rclone-OBSCURED form of the token:
##                       rclone decrypts the pass parameter (plaintext fails
##                       "couldn't decrypt password: base64 decode failed",
##                       observed 2026-11-22) — rclone obscure is reversible
##                       obfuscation (fixed key), NOT encryption; the
##                       plaintext token stays in NEXTCLOUD_APP_TOKEN below
##   RESTIC_PASSWORD     repo encryption key (client-side encryption)
##   NEXTCLOUD_WEBDAV_URL / NEXTCLOUD_USER / NEXTCLOUD_APP_TOKEN
##                       quota PROPFIND for export-backup-stats.sh

cd "$(dirname "$(readlink -f "$0")")"

umask 077
ENV_FILE=".env.secret"

NEXTCLOUD_HOST="${NEXTCLOUD_HOST:-}"
NEXTCLOUD_USER="${NEXTCLOUD_USER:-}"

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }
bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden not unlocked — export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }
# rclone renders the webdav remote's pass from the OBSCURED token form —
# install-rclone.sh must have run first.
command -v rclone >/dev/null || { echo "[ERR] rclone not found — run ./install-rclone.sh first (the RCLONE_CONFIG_HOMEBASE_PASS value must be rclone-obscured)"; exit 1; }

[ -n "${NEXTCLOUD_HOST}" ] || { echo "[ERR] NEXTCLOUD_HOST not set (e.g. NEXTCLOUD_HOST=cloud-XXXXXXXX.hbts.net" >&2; echo "      ./provision-backup-secrets.sh) — the Storage Share host from the web UI." >&2; exit 1; }
[ -n "${NEXTCLOUD_USER}" ] || { echo "[ERR] NEXTCLOUD_USER not set (the DAV user of the backup share)" >&2; exit 1; }

# resolve <item> <env-override> — fetch the Bitwarden password field; generate
# a hex value + print a save hint if missing. Progress on stderr, value on stdout.
resolve() {
  local item="$1" override="${2:-}" value
  if [ -n "${override}" ]; then printf '%s' "${override}"; return; fi
  value="$(bw get password "${item}" 2>/dev/null || true)"
  if [ -n "${value}" ]; then
    echo "[*] ${item}: fetched from Bitwarden" >&2
  else
    value="$(openssl rand -hex 32)"
    echo "[!] ${item}: not in Bitwarden — generated. Save it as a Bitwarden" >&2
    echo "    item named '${item}' (password field) before the next run —" >&2
    echo "    without it the offsite repo can NEVER be decrypted:" >&2
    echo "    ${value}" >&2
  fi
  printf '%s' "${value}"
}

# resolve_required <item> <field> <env-override> — a field that CANNOT be
# generated (created in the Storage Share web UI). Fail closed with the hint.
resolve_required() {
  local item="$1" field="$2" override="${3:-}" value
  if [ -n "${override}" ]; then printf '%s' "${override}"; return; fi
  value="$(bw get "${field}" "${item}" 2>/dev/null || true)"
  [ -n "${value}" ] || { echo "[ERR] Bitwarden item '${item}' (${field} field) not found —" >&2; echo "      create the app token in the Storage Share web UI first (docs/operations.md)." >&2; exit 1; }
  echo "[*] ${item} (${field}): fetched from Bitwarden" >&2
  printf '%s' "${value}"
}

echo "[*] Provisioning backup secrets -> ${ENV_FILE}"
RESTIC_PASSWORD_VALUE="$(resolve restic-backup-password "${RESTIC_PASSWORD:-}" )"
NEXTCLOUD_APP_TOKEN_VALUE="$(resolve_required nextcloud-backup-app-token password "${NEXTCLOUD_APP_TOKEN:-}")"

[ -n "${RESTIC_PASSWORD_VALUE}" ] || { echo "[ERR] Empty restic-backup-password"; exit 1; }
[ -n "${NEXTCLOUD_APP_TOKEN_VALUE}" ] || { echo "[ERR] Empty nextcloud-backup-app-token"; exit 1; }

# rclone's env-var config decrypts the pass parameter — render the obscured
# form (reversible obfuscation, fixed key; plaintext fails the decrypt).
RCLONE_PASS_OBSCURED="$(rclone obscure "${NEXTCLOUD_APP_TOKEN_VALUE}")"

{
  printf 'RESTIC_REPOSITORY=rclone:homebase:homebase\n'
  printf 'RCLONE_CONFIG_HOMEBASE_TYPE=webdav\n'
  printf 'RCLONE_CONFIG_HOMEBASE_VENDOR=nextcloud\n'
  printf 'RCLONE_CONFIG_HOMEBASE_URL=https://%s/remote.php/dav/files/%s\n' "${NEXTCLOUD_HOST}" "${NEXTCLOUD_USER}"
  printf 'RCLONE_CONFIG_HOMEBASE_USER=%s\n' "${NEXTCLOUD_USER}"
  printf 'RCLONE_CONFIG_HOMEBASE_PASS=%s\n' "${RCLONE_PASS_OBSCURED}"
  printf 'RESTIC_PASSWORD=%s\n' "${RESTIC_PASSWORD_VALUE}"
  printf 'NEXTCLOUD_WEBDAV_URL=https://%s/remote.php/dav/files/%s/homebase\n' "${NEXTCLOUD_HOST}" "${NEXTCLOUD_USER}"
  printf 'NEXTCLOUD_USER=%s\n' "${NEXTCLOUD_USER}"
  printf 'NEXTCLOUD_APP_TOKEN=%s\n' "${NEXTCLOUD_APP_TOKEN_VALUE}"
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

echo "[+] Wrote ${ENV_FILE} (restic repo key + Storage Share app token)."
echo "    Next: ./install-restic.sh, then restic init (docs/operations.md, \"Backups\")."
