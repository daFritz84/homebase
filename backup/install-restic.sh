#!/usr/bin/env bash
set -euo pipefail

## Install the restic BINARY (a plain host process, NOT a container) to
## ~/.local/bin/restic, for the offsite backup pipeline
## (systemd/user/backup-all.{service,timer} + backup-verify.{service,timer}).
##
## Why a plain process and not a container: restic reads the service data dirs
## under ~/.local/share (rootless-podman uid-mapped files) and writes the
## repo-size/state cache; a host process as chef reads them directly (the
## node_exporter model).
##
## The binary is version-PINNED. The repo does not track binaries; this script
## fetches the pinned release and verifies the sha256 against the release's
## SHA256SUMS (fail closed) — the install-node-exporter.sh pattern.
##
## Run on the SERVER as the service user (chef), no sudo:
##   ./install-restic.sh
## Then: ./provision-backup-secrets.sh + restic init (docs/operations.md,
## "Backups").

cd "$(dirname "$(readlink -f "$0")")"

VERSION="0.20.0"
ASSET="restic_${VERSION}_linux_amd64.bz2"
URL="https://github.com/restic/restic/releases/download/v${VERSION}/${ASSET}"
# restic publishes a single SHA256SUMS per release covering all assets.
CHECKSUM_URL="https://github.com/restic/restic/releases/download/v${VERSION}/SHA256SUMS"
DEST="${HOME}/.local/bin/restic"

command -v curl >/dev/null || { echo "[ERR] curl not found"; exit 1; }
command -v bunzip2 >/dev/null || { echo "[ERR] bunzip2 not found (p7zip/bzip2 package)"; exit 1; }

if [ -x "${DEST}" ] && "${DEST}" version 2>/dev/null | grep -q "${VERSION}"; then
  echo "[*] restic ${VERSION} already installed at ${DEST}"
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

bunzip2 -c "${tmp}/${ASSET}" > "${tmp}/restic"
install -d "${HOME}/.local/bin"
install -m 0755 "${tmp}/restic" "${DEST}"

echo "[+] Installed ${DEST}:"
"${DEST}" version 2>&1 | head -1 || true
echo
echo "[✓] restic ${VERSION} installed."
echo "    Next: ./provision-backup-secrets.sh, restic init, then"
echo "    ../systemd/install-user-units.sh && systemctl --user enable --now"
echo "    backup-all.timer backup-verify.timer (docs/operations.md, \"Backups\")"
