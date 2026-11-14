#!/usr/bin/env bash
# Install the user-scope systemd units tracked in this repo:
# the podman-network-online gate and the podman-compose@ drop-in that
# orders every compose unit behind it. Idempotent; run as the service
# user (chef), no sudo.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/user" && pwd)"
dest="${HOME}/.config/systemd/user"

install -d "${dest}/podman-compose@.service.d"
ln -sfn "${src}/podman-network-online.service" "${dest}/podman-network-online.service"
ln -sfn "${src}/podman-compose@.service.d/network-online.conf" \
  "${dest}/podman-compose@.service.d/network-online.conf"
ln -sfn "${src}/beszel-agent.service" "${dest}/beszel-agent.service"

systemctl --user daemon-reload
systemctl --user enable podman-network-online.service

# The beszel-agent unit is symlinked but NOT auto-enabled: it needs the binary
# (beszel/install-agent.sh) and beszel/agent.env (KEY/TOKEN from the hub's Add
# System) in place first, or it crash-loops. Enable it after that setup:
#   systemctl --user enable --now beszel-agent
