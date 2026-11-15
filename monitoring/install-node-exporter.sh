#!/usr/bin/env bash
set -euo pipefail

## Install the node_exporter AGENT binary (a plain host process, NOT a container)
## to ~/.local/bin/node_exporter, for the systemd USER unit
## systemd/user/node-exporter.service.
##
## Why a plain process and not a container: node_exporter reads the host /proc +
## /sys for CPU/RAM/disk metrics, which a rootless container cannot mount — a
## host process running as chef reads them directly (the beszel-agent model, the
## clean rootless answer; cAdvisor as a rootless container cannot).
##
## The binary is version-PINNED (the `latest/download` URL has no version, so
## pinning uses the versioned release URL). The repo does not track binaries;
## this script fetches the pinned release and verifies the sha256 against the
## release's per-asset checksum (fail closed).
##
## Run on the SERVER as the service user (chef), no sudo:
##   ./install-node-exporter.sh
## Then install the unit via ../systemd/install-user-units.sh.

cd "$(dirname "$(readlink -f "$0")")"

VERSION="1.12.1"
ASSET="node_exporter-${VERSION}.linux-amd64.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${ASSET}"
# node_exporter publishes a single sha256sums.txt per release (no per-asset
# .sha256 — that URL 404s).
CHECKSUM_URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/sha256sums.txt"
DEST="${HOME}/.local/bin/node_exporter"

command -v curl >/dev/null || { echo "[ERR] curl not found"; exit 1; }
command -v tar >/dev/null || { echo "[ERR] tar not found"; exit 1; }

if [ -x "${DEST}" ] && "${DEST}" --version 2>/dev/null | grep -q "${VERSION}"; then
  echo "[*] node_exporter ${VERSION} already installed at ${DEST}"
  exit 0
fi

echo "[*] Fetching ${URL}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# GitHub's release-asset signed-redirect intermittently returns 404 (observed
# 2026-11-15: same URL 404s from the script, 200s on manual retry) — retry.
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "${URL}" -o "${tmp}/${ASSET}"

# Verify against the release sha256sums.txt (fail closed).
expected="$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "${CHECKSUM_URL}" | grep " ${ASSET}\$" | awk '{print $1}')"
actual="$(sha256sum "${tmp}/${ASSET}" | cut -d' ' -f1)"
[ -n "${expected}" ] || { echo "[ERR] no checksum in ${CHECKSUM_URL}"; exit 1; }
[ "${expected}" = "${actual}" ] || { echo "[ERR] sha256 mismatch: expected ${expected}, got ${actual}"; exit 1; }
echo "[+] sha256 verified: ${actual}"

tar -xzf "${tmp}/${ASSET}" -C "${tmp}"
install -d "${HOME}/.local/bin"
install -m 0755 "${tmp}/node_exporter-${VERSION}.linux-amd64/node_exporter" "${DEST}"

echo "[+] Installed ${DEST}:"
"${DEST}" --version 2>&1 | head -1 || true
echo
echo "[✓] node_exporter ${VERSION} installed."
echo "    Next: ../systemd/install-user-units.sh && systemctl --user enable --now node-exporter"
