#!/usr/bin/env bash
set -euo pipefail

# Default network name
NET="${1:-caddy-proxy}"

echo "Checking if Podman network '$NET' exists..."

if podman network inspect "$NET" >/dev/null 2>&1; then
    echo "✔ Network '$NET' already exists."
else
    echo "❗ Network '$NET' does not exist. Creating..."
    podman network create "$NET"
    echo "✔ Network '$NET' created successfully."
fi