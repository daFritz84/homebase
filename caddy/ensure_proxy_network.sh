#!/usr/bin/env bash
set -euo pipefail

# Default network name
NET="${1:-caddy-proxy}"

# Pinned subnet: must match the Caddyfile (authelia-fa) "trusted_proxies"
# CIDR — the single source of truth, read from the Caddyfile next to this
# script so the two copies cannot drift (the drift-recovery procedure in
# docs/operations.md updates the Caddyfile; the script follows it). An
# auto-assigned subnet drifts when the network is recreated (it has drifted
# before: 10.88.0.0/16 -> 10.89.0.0/24), which silently breaks the
# forward-auth wall. HA's trusted proxy is NOT this subnet: HA is
# host-networked and trusts the host IP 192.168.178.249 (see
# homeassistant/config/configuration.yaml).
CADDYFILE="$(dirname "$(readlink -f "$0")")/Caddyfile"
DEFAULT_SUBNET="$(grep -oE 'trusted_proxies [0-9./]+' "$CADDYFILE" | head -n1 | awk '{print $2}' || true)"
[ -n "${DEFAULT_SUBNET}" ] || { echo "[ERR] Cannot read trusted_proxies from ${CADDYFILE}"; exit 1; }
SUBNET="${2:-${DEFAULT_SUBNET}}"

echo "Checking if Podman network '$NET' exists..."

if podman network inspect "$NET" >/dev/null 2>&1; then
    echo "✔ Network '$NET' already exists."
    echo "  Verify the subnet matches trusted_proxies in the Caddyfile:"
    podman network inspect "$NET" | grep -i subnet || true
else
    echo "❗ Network '$NET' does not exist. Creating on $SUBNET..."
    podman network create --subnet "$SUBNET" "$NET"
    echo "✔ Network '$NET' created successfully."
fi
