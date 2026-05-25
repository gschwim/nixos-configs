#!/usr/bin/env bash
# gen-host-key.sh — generate (or print, if it exists) an ed25519 SSH host
# key for a NixOS host. The key lives outside the repo at
# ~/.local/share/nixos-configs/host-keys/<hostname>_ed25519.
#
# Use this BEFORE install-host.sh when the host needs to decrypt any
# agenix secret on first boot. The printed pubkey goes into
# secrets/secrets.nix as the host's recipient; then re-key any affected
# secrets with `agenix -r` and commit/push before running install-host.sh.
#
# Usage:
#   scripts/gen-host-key.sh <hostname>

set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <hostname>" >&2; exit 1; }

HOSTNAME="$1"
KEY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/host-keys"
KEY="$KEY_DIR/${HOSTNAME}_ed25519"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "root@$HOSTNAME" >/dev/null
  echo "Generated: $KEY"
else
  echo "Existing:  $KEY  (reusing)"
fi

echo
echo "Public key (paste into secrets/secrets.nix as '$HOSTNAME'):"
cat "${KEY}.pub"
