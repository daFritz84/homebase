#!/usr/bin/env bash
set -euo pipefail

## Write beszel/agent.env (gitignored, mode 0600) from Bitwarden — the agent's
## KEY/TOKEN (from the hub's Add System) plus the fixed WebSocket-only + Podman
## socket settings. Consumed by systemd/user/beszel-agent.service (EnvironmentFile).
## Mirrors the provision-*-secrets.sh pattern (Bitwarden -> gitignored env, 0600).
##
## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)
#
## Run from the beszel directory on the server.
##
## Inputs (Bitwarden password fields; env overrides for testing):
##   beszel-agent-key    -> KEY   (env KEY)
##   beszel-agent-token  -> TOKEN (env TOKEN)

cd "$(dirname "$(readlink -f "$0")")"

umask 077
ENV_FILE="agent.env"

get() { # <item> <env-override>
  local item="$1" override="${2:-}" v
  if [ -n "${override}" ]; then printf '%s' "${override}"; return; fi
  command -v bw >/dev/null || { echo "[ERR] bw not found and ${item} override unset"; exit 1; }
  bw status | grep -q '"unlocked"' || { echo "[ERR] Bitwarden not unlocked — export BW_SESSION=\"\$(bw unlock --raw)\""; exit 1; }
  v="$(bw get password "${item}" 2>/dev/null || true)"
  [ -n "${v}" ] || { echo "[ERR] Bitwarden item ${item} empty/missing — add the KEY/TOKEN from the hub's Add System"; exit 1; }
  printf '%s' "${v}"
}

KEY="$(get beszel-agent-key "${KEY:-}")"
TOKEN="$(get beszel-agent-token "${TOKEN:-}")"

{
  printf 'KEY=%s\n' "${KEY}"
  printf 'TOKEN=%s\n' "${TOKEN}"
  printf 'HUB_URL=http://127.0.0.1:8090\n'
  printf 'LISTEN=45876\n'
  printf 'DISABLE_SSH=true\n'
  printf 'DOCKER_HOST=unix:///run/user/1000/podman/podman.sock\n'
  printf 'DOCKER_IMAGE_CHECK=false\n'
} > "${ENV_FILE}.tmp"
mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

echo "[+] Wrote ${ENV_FILE} (KEY/TOKEN from Bitwarden; mode 0600)."
echo "    Next: ../systemd/install-user-units.sh && systemctl --user enable --now beszel-agent"
