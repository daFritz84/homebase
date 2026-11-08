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

systemctl --user daemon-reload
systemctl --user enable podman-network-online.service
