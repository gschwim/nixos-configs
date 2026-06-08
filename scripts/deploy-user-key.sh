#!/usr/bin/env bash
# deploy-user-key.sh — copy the cached id_ed25519 + .pub + -cert.pub into
# /home/<user>/.ssh/ on a running management host. Idempotent.
#
# Use this for hosts that are already installed and you want to give
# (or refresh) outbound-cert auth on. For fresh installs, scripts/install-host.sh
# does the same thing via nixos-anywhere --extra-files.
#
# Prerequisites:
#   - scripts/gen-user-key.sh <hostname> [user] has run successfully — cache
#     should contain the three files at
#     ~/.local/share/nixos-configs/user-keys/<hostname>_<user>_ed25519{,.pub,-cert.pub}.
#   - The host's per-host file has my.host.management.enable = true (so
#     /home/<user>/.ssh/ exists with 0700 perms from the tmpfiles rule).
#   - You can SSH to <user>@<hostname> with sudo (the install commands run
#     as the user, no sudo needed if the cache files match the target user).
#
# Usage:
#   scripts/deploy-user-key.sh <hostname> [user]
#     hostname  reachable name or IP of the running host
#     user      target user on the host. default: schwim

set -euo pipefail

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
  echo "usage: $0 <hostname> [user]" >&2
  exit 1
}

TARGET="$1"
USER_NAME="${2:-schwim}"

CACHE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/user-keys"
SLOT="${TARGET}_${USER_NAME}"
KEY="$CACHE_DIR/${SLOT}_ed25519"
PUB="${KEY}.pub"
CERT="${KEY}-cert.pub"

die() { echo "ERROR: $*" >&2; exit 1; }

for f in "$KEY" "$PUB" "$CERT"; do
  [ -f "$f" ] || die "missing cache file: $f (run scripts/gen-user-key.sh $TARGET $USER_NAME)"
done

echo "Deploying ${SLOT} → ${USER_NAME}@${TARGET}:~/.ssh/ …"

# scp the three files to a temp dir on the host first, then install(1) them
# into ~/.ssh/ with the right perms. Avoids file-mode races during scp.
ssh "${USER_NAME}@${TARGET}" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'

scp -q "$KEY" "$PUB" "$CERT" "${USER_NAME}@${TARGET}:/tmp/" \
  || die "scp failed"

ssh "${USER_NAME}@${TARGET}" "
  set -e
  install -m 600 /tmp/${SLOT}_ed25519       ~/.ssh/id_ed25519
  install -m 644 /tmp/${SLOT}_ed25519.pub   ~/.ssh/id_ed25519.pub
  install -m 644 /tmp/${SLOT}_ed25519-cert.pub ~/.ssh/id_ed25519-cert.pub
  rm -f /tmp/${SLOT}_ed25519 /tmp/${SLOT}_ed25519.pub /tmp/${SLOT}_ed25519-cert.pub
"

echo "Done. On ${TARGET}, ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub will show the cert."
