#!/usr/bin/env bash
set -euo pipefail

## Install the Beszel AGENT binary (a plain host process, NOT a container) to
## ~/.local/bin/beszel-agent, for the systemd USER unit
## systemd/user/beszel-agent.service.
##
## Why a plain process and not a container: the agent reads the host /proc for
## CPU/RAM/disk metrics, which a rootless container cannot mount — a host
## process running as chef reads /proc directly (the clean rootless answer). It
## reads container stats via the Podman API socket (chef's own socket, no proxy).
##
## The binary is version-PINNED (the `latest/download` asset URL has no version,
## so pinning uses the versioned release URL). The repo does not track binaries;
## this script fetches the pinned release. Verify the printed sha256 against the
## GitHub release's checksums before trusting it.
##
## Pin the agent version to the hub image tag in beszel/compose.yaml (0.21.2) —
## bump both together.
##
## Run on the SERVER as the service user (chef), no sudo:
##   ./install-agent.sh
## Then write beszel/agent.env (KEY/TOKEN from the hub's "Add System") and
## install the unit via ../systemd/install-user-units.sh.

cd "$(dirname "$(readlink -f "$0")")"

VERSION="0.21.2"
ARCH="Linux_x86_64"
URL="https://github.com/henrygd/beszel/releases/download/v${VERSION}/beszel-agent_${ARCH}.tar.gz"
DEST="${HOME}/.local/bin/beszel-agent"

command -v curl >/dev/null || { echo "[ERR] curl not found"; exit 1; }
command -v tar >/dev/null || { echo "[ERR] tar not found"; exit 1; }

if [ -x "${DEST}" ] && "${DEST}" --version 2>/dev/null | grep -q "${VERSION}"; then
  echo "[*] beszel-agent ${VERSION} already installed at ${DEST}"
  exit 0
fi

echo "[*] Fetching ${URL}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL "${URL}" -o "${tmp}/agent.tar.gz"

echo "[*] sha256 (verify against the GitHub release checksums):"
sha256sum "${tmp}/agent.tar.gz"

tar -xzf "${tmp}/agent.tar.gz" -C "${tmp}" beszel-agent
install -d "${HOME}/.local/bin"
install -m 0755 "${tmp}/beszel-agent" "${DEST}"

echo "[+] Installed ${DEST}:"
"${DEST}" --version 2>/dev/null || true
echo
echo "[✓] beszel-agent ${VERSION} installed."
echo "    Next: write beszel/agent.env (KEY/TOKEN from the hub's Add System),"
echo "    then ../systemd/install-user-units.sh && systemctl --user enable --now beszel-agent"
