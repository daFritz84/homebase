#!/usr/bin/env bash
set -euo pipefail

## Writes /etc/samba/credentials.nas (root:root 0600) for the NAS media
## mounts (//truenas.local/share/{Filme,Serien} -> /srv/media/*) —
## see docs/host-setup.md "NAS media mounts (CIFS automount)".

## Unlock Bitwarden CLI first (example):
# bw login
# export BW_SESSION=$(bw unlock --raw)

## Uses sudo -> needs a tty: run it in an interactive session, e.g.
##   ssh -t chef@192.168.178.249
##   cd ~/src/homebase/jellyfin && ./provision-nas-credentials.sh

command -v bw >/dev/null || { echo "[ERR] bw (Bitwarden CLI) not found — see docs/host-setup.md"; exit 1; }

# --- CONFIG: Bitwarden item (Login type: login field = username, password field = password) ---
BW_ITEM_NAS="TrueNAS SMB"

# --- CONFIG: target credentials file (outside the repo, never tracked) ---
CRED_FILE="/etc/samba/credentials.nas"

# Fetch SMB credentials. NOTE: `bw get login username` is INVALID — bw has no
# `login` object; the correct forms are `bw get username <item>` / `bw get password <item>`.
echo "[*] Fetching SMB credentials from Bitwarden item '${BW_ITEM_NAS}'..."
USERNAME="$(bw get username "${BW_ITEM_NAS}")"
PASSWORD="$(bw get password "${BW_ITEM_NAS}")"

# Basic sanity checks (never echo the values)
[ -n "${USERNAME}" ] || { echo "[ERR] Empty SMB username (Bitwarden item '${BW_ITEM_NAS}' — login field?)"; exit 1; }
[ -n "${PASSWORD}" ] || { echo "[ERR] Empty SMB password (Bitwarden item '${BW_ITEM_NAS}' — password field?)"; exit 1; }

# Write root:root 0600 with no world-readable window: pre-create the file via
# install, then write through sudo tee (file stays root-owned). printf is a
# bash builtin -> the password never appears in ps argv.
sudo mkdir -p "$(dirname "${CRED_FILE}")"
sudo install -m 600 /dev/null "${CRED_FILE}"
printf 'username=%s\npassword=%s\n' "${USERNAME}" "${PASSWORD}" | sudo tee "${CRED_FILE}" >/dev/null
echo "[+] Wrote ${CRED_FILE} (root:root 0600)"

echo
echo "[✓] NAS SMB credentials provisioned."
echo "    Active mounts keep the OLD credentials until remounted:"
echo "    sudo systemctl stop srv-media-{filme,serien}.automount && sudo umount /srv/media/{filme,serien} && sudo systemctl start srv-media-{filme,serien}.automount"
