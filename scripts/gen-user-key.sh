#!/usr/bin/env bash
# gen-user-key.sh — generate (if missing) and CA-sign (if missing) an
# ed25519 user keypair for <hostname>_<user>. Stored only in the local
# blushda cache; the cert is not committed to the repo (the receiving
# host trusts the User CA via my.services.openssh.trustUserCA).
#
# Pipeline:
#   1. Ensure keypair exists in cache; ssh-keygen if not.
#   2. Ensure cert exists in cache; sign with User CA from keepassxc if not.
#   3. Print ssh-keygen -L of the cert.
#
# Deploy the resulting cache entries via:
#   - scripts/install-host.sh   (fresh install)
#   - scripts/deploy-user-key.sh (already-installed host)
#
# Re-runs are idempotent: existing keypair + existing cert → no-op.
# Force re-sign: rm the cert file from the cache and re-run.
# Force rotation: rm all three cache files and re-run.
#
# Usage:
#   scripts/gen-user-key.sh <hostname> [user] [principals]
#     hostname    target host (must match hosts/<hostname>/ in the repo)
#     user        username on the target host. default: schwim
#     principals  comma-separated principals on the cert. default: <user>
#
# Env (defaults usually fine):
#   KDBX_FILE  path to the .kdbx
#              default: $HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx
#   KDBX_PW    kdbx unlock password. If unset, prompts once and exports for
#              reuse by other scripts in the same shell.

set -euo pipefail

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || {
  echo "usage: $0 <hostname> [user] [principals]" >&2
  exit 1
}

HOSTNAME="$1"
USER_NAME="${2:-schwim}"
PRINCIPALS="${3:-$USER_NAME}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/user-keys"
SLOT="${HOSTNAME}_${USER_NAME}"
KEY="$CACHE_DIR/${SLOT}_ed25519"
CERT="${KEY}-cert.pub"

KDBX_FILE="${KDBX_FILE:-$HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx}"
KDBX_CA_ENTRY="SSH CA/SSH User CA"

die() { echo "ERROR: $*" >&2; exit 1; }

# We only need keepassxc when we have to sign. Defer the password prompt
# until we know it's needed.
need_kdbx() {
  command -v keepassxc-cli >/dev/null \
    || die "keepassxc-cli not on PATH (macOS: brew install keepassxc)"
  [ -r "$KDBX_FILE" ] || die "kdbx file not readable: $KDBX_FILE"
  if [ -z "${KDBX_PW:-}" ]; then
    read -rsp "kdbx password: " KDBX_PW
    echo
    export KDBX_PW
  fi
  printf '%s\n' "$KDBX_PW" \
    | keepassxc-cli ls --quiet "$KDBX_FILE" / >/dev/null 2>&1 \
    || die "kdbx unlock failed (wrong password? bad file?)"
}

kpx() { printf '%s\n' "$KDBX_PW" | keepassxc-cli "$@"; }

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

# 1) Ensure keypair exists.
if [ -f "$KEY" ] && [ -f "${KEY}.pub" ]; then
  echo "Reusing existing keypair at $KEY"
else
  # If only one half exists, refuse — that's an inconsistent state.
  [ -f "$KEY" ] || [ -f "${KEY}.pub" ] \
    && die "inconsistent cache: one of $KEY / ${KEY}.pub exists without the other"
  echo "Generating fresh ed25519 keypair → $KEY"
  ssh-keygen -t ed25519 -N "" -f "$KEY" \
    -C "${USER_NAME}@${HOSTNAME}" >/dev/null
fi

# 2) Ensure cert exists.
if [ -f "$CERT" ]; then
  echo "Reusing existing cert at $CERT"
else
  need_kdbx

  tmp_ca="$(mktemp)"
  chmod 600 "$tmp_ca"
  trap 'rm -f "$tmp_ca"' EXIT INT TERM

  echo "Pulling User CA from '$KDBX_CA_ENTRY' to sign"
  kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_CA_ENTRY" \
      user_ca "$tmp_ca" >/dev/null \
    || die "couldn't export 'user_ca' attachment from '$KDBX_CA_ENTRY'"

  # User cert (no -h flag). Identity is "${user}@${host}", principals as passed.
  ssh-keygen -s "$tmp_ca" -I "${USER_NAME}@${HOSTNAME}" -n "$PRINCIPALS" \
             -V "always:forever" "${KEY}.pub" >/dev/null \
    || die "ssh-keygen user-cert signing failed"

  rm -f "$tmp_ca"
  trap - EXIT INT TERM

  echo "Signed cert → $CERT"
fi

echo
echo "Certificate (ssh-keygen -L):"
ssh-keygen -L -f "$CERT" | sed -E 's/^/  /'
echo
echo "Deploy with:"
echo "  scripts/install-host.sh $HOSTNAME <ip>          # for a fresh install"
echo "  scripts/deploy-user-key.sh $HOSTNAME $USER_NAME # for a running host"
