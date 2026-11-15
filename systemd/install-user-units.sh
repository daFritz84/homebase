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
ln -sfn "${src}/node-exporter.service" "${dest}/node-exporter.service"
ln -sfn "${src}/podman-stats-export.service" "${dest}/podman-stats-export.service"
ln -sfn "${src}/podman-stats-export.timer" "${dest}/podman-stats-export.timer"
ln -sfn "${src}/fritzbox-stats-export.service" "${dest}/fritzbox-stats-export.service"
ln -sfn "${src}/fritzbox-stats-export.timer" "${dest}/fritzbox-stats-export.timer"

systemctl --user daemon-reload
systemctl --user enable podman-network-online.service

# The node-exporter + podman-stats-export + fritzbox-stats-export units are
# symlinked but NOT auto-enabled: node-exporter needs the binary
# (monitoring/install-node-exporter.sh) in place first, or it crash-loops.
# Enable them after that setup:
#   systemctl --user enable --now node-exporter podman-stats-export.timer fritzbox-stats-export.timer
