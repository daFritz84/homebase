#!/usr/bin/env bash
set -euo pipefail

## Install the rclone BINARY (a plain host process, NOT a container) to
## ~/.local/bin/rclone, for the offsite backup pipeline.
##
## Why rclone exists in this pipeline: restic REMOVED its native webdav
## backend in 0.18.0 (confirmed absent from the 0.18.1 source tree and the
## 0.20.0 backend registry), so the Storage Share target is reached through
## restic's supported `rclone:` backend: restic spawns
## `rclone serve restic --stdio homebase:homebase` and rclone's mature
## webdav provider (vendor=nextcloud) speaks to the DAV endpoint.
##
## The remote is configured ENTIRELY via RCLONE_CONFIG_HOMEBASE_* environment
## variables rendered by provision-backup-secrets.sh into .env.secret (0600)
## — there is NO ~/.config/rclone/rclone.conf and the app token never lives
## outside .env.secret.
##
## The binary is version-PINNED; the sha256 is verified against the release's
## SHA256SUMS (fail closed) — the install-restic.sh / install-node-exporter.sh
## pattern.
##
## Run on the SERVER as the service user (chef), no sudo:
##   ./install-rclone.sh

cd "$(dirname "$(readlink -f "$0")")"

VERSION="1.76.0"
ASSET="rclone-v${VERSION}-linux-amd64.zip"
URL="https://github.com/rclone/rclone/releases/download/v${VERSION}/${ASSET}"
CHECKSUM_URL="https://github.com/rclone/rclone/releases/download/v${VERSION}/SHA256SUMS"
DEST="${HOME}/.local/bin/rclone"

command -v curl >/dev/null || { echo "[ERR] curl not found"; exit 1; }
command -v unzip >/dev/null || { echo "[ERR] unzip not found"; exit 1; }

if [ -x "${DEST}" ] && "${DEST}" version 2>/dev/null | grep -q "rclone v${VERSION}"; then
  echo "[*] rclone ${VERSION} already installed at ${DEST}"
  exit 0
fi

echo "[*] Fetching ${URL}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# GitHub's release-asset signed-redirect intermittently returns 404 (observed
# 2026-11-15 for node_exporter: same URL 404s from the script, 200s on manual
# retry) — retry.
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "${URL}" -o "${tmp}/${ASSET}"

# Verify against the release SHA256SUMS (fail closed).
expected="$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "${CHECKSUM_URL}" | grep " ${ASSET}\$" | awk '{print $1}')"
actual="$(sha256sum "${tmp}/${ASSET}" | cut -d' ' -f1)"
[ -n "${expected}" ] || { echo "[ERR] no checksum for ${ASSET} in ${CHECKSUM_URL}"; exit 1; }
[ "${expected}" = "${actual}" ] || { echo "[ERR] sha256 mismatch: expected ${expected}, got ${actual}"; exit 1; }
echo "[+] sha256 verified: ${actual}"

unzip -j -q -o "${tmp}/${ASSET}" "rclone-v${VERSION}-linux-amd64/rclone" -d "${tmp}"
install -d "${HOME}/.local/bin"
install -m 0755 "${tmp}/rclone" "${DEST}"

echo "[+] Installed ${DEST}:"
"${DEST}" version 2>&1 | head -1 || true
echo
echo "[✓] rclone ${VERSION} installed."
echo "    The restic repo spec is rclone:homebase:homebase; the remote comes"
echo "    from RCLONE_CONFIG_HOMEBASE_* in backup/.env.secret"
echo "    (provision-backup-secrets.sh)."
