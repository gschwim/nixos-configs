#!/usr/bin/env bash
# provision-user-key.sh — generate, sign, and agenix-encrypt a user keypair
# for <host>/<user>. Three artifacts land in the repo:
#
#   secrets/users/<host>_<user>_id_ed25519.age      encrypted priv (recipient
#                                                   = the host's SSH host key)
#   lib/users/<host>_<user>_id_ed25519.pub          plaintext pubkey
#   lib/users/<host>_<user>_id_ed25519-cert.pub     plaintext signed cert
#
# Nothing unencrypted persists on blushda — the keypair is generated in a
# tempdir under $TMPDIR and shredded on exit. The priv is only ever readable
# again by the target host (via agenix on first nixos-rebuild after pull).
#
# Preconditions (script enforces and bails clearly):
#   - lib/user-ca.pub exists.
#   - secrets/secrets.nix declares "users/<host>_<user>_id_ed25519.age"
#     in its publicKeys block (recipients = a <host>UserAccess list that
#     resolves to the host's SSH host key). The script doesn't auto-edit
#     secrets.nix; you set that up once per management host by hand.
#   - ~/.config/sops/age/keys.txt holds your age authoring identity.
#
# Idempotent: if all three artifacts already exist, no-op. To rotate, delete
# them and re-run.
#
# Usage:
#   scripts/provision-user-key.sh <hostname> [user] [principals]
#     defaults: user = principals = schwim
#
# After running:
#   git add -A && git commit && git push
#   on <hostname>: git pull && sudo nixos-rebuild switch --flake .#<hostname>

set -euo pipefail
[ "$#" -ge 1 ] && [ "$#" -le 3 ] \
  || { echo "usage: $0 <hostname> [user] [principals]" >&2; exit 1; }

HOSTNAME="$1"
USER_NAME="${2:-schwim}"
PRINCIPALS="${3:-$USER_NAME}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLOT="${HOSTNAME}_${USER_NAME}"
AGENIX_REL="users/${SLOT}_id_ed25519.age"      # relative to secrets/
AGENIX_ABS="$REPO_ROOT/secrets/$AGENIX_REL"
PUB_OUT="$REPO_ROOT/lib/users/${SLOT}_id_ed25519.pub"
CERT_OUT="$REPO_ROOT/lib/users/${SLOT}_id_ed25519-cert.pub"

KDBX_FILE="${KDBX_FILE:-$HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx}"
KDBX_CA_ENTRY="SSH CA/SSH User CA"
AGE_IDENTITY="$HOME/.config/sops/age/keys.txt"

die() { echo "ERROR: $*" >&2; exit 1; }
rel() { echo "${1#$REPO_ROOT/}"; }

# ----- preflight ----------------------------------------------------------

[ -f "$REPO_ROOT/lib/user-ca.pub" ] \
  || die "lib/user-ca.pub missing — extract the User CA pubkey first"
[ -f "$AGE_IDENTITY" ] \
  || die "no age authoring identity at $AGE_IDENTITY"
grep -q "\"$AGENIX_REL\"" "$REPO_ROOT/secrets/secrets.nix" \
  || die "secrets/secrets.nix doesn't declare \"$AGENIX_REL\" — add it before provisioning (see README)"
command -v keepassxc-cli >/dev/null \
  || die "keepassxc-cli not on PATH (macOS: brew install keepassxc)"
[ -r "$KDBX_FILE" ] || die "kdbx file not readable: $KDBX_FILE"

# ----- idempotent fast-path ------------------------------------------------

if [ -f "$AGENIX_ABS" ] && [ -f "$PUB_OUT" ] && [ -f "$CERT_OUT" ]; then
  echo "All artifacts already exist for $SLOT — nothing to do:"
  echo "  $(rel "$AGENIX_ABS")"
  echo "  $(rel "$PUB_OUT")"
  echo "  $(rel "$CERT_OUT")"
  echo
  echo "To rotate the keypair: rm those three files, then re-run."
  exit 0
fi

# ----- kdbx password (reuse env if already exported) ----------------------

if [ -z "${KDBX_PW:-}" ]; then
  printf 'kdbx password: '
  stty -echo
  IFS= read -r KDBX_PW
  stty echo
  echo
  export KDBX_PW
fi

mkdir -p "$REPO_ROOT/lib/users" "$REPO_ROOT/secrets/users"

# ----- generate + sign in a tempdir, never persisted ----------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "Generating ed25519 keypair for $SLOT"
ssh-keygen -t ed25519 -N "" -f "$WORK/id_ed25519" \
           -C "${USER_NAME}@${HOSTNAME}" >/dev/null

echo "Signing with User CA from '$KDBX_CA_ENTRY'"
# Pre-create the destination at mode 600 so keepassxc-cli's write inherits
# our perms (otherwise it creates a fresh 644 file and ssh-keygen refuses
# the key as "too open").
( umask 077 && : > "$WORK/user_ca" )
printf '%s\n' "$KDBX_PW" \
  | keepassxc-cli attachment-export --quiet "$KDBX_FILE" "$KDBX_CA_ENTRY" \
        user_ca "$WORK/user_ca" >/dev/null \
  || die "couldn't export 'user_ca' attachment from '$KDBX_CA_ENTRY'"
chmod 600 "$WORK/user_ca"      # belt-and-suspenders post-write
ssh-keygen -s "$WORK/user_ca" -I "${USER_NAME}@${HOSTNAME}" -n "$PRINCIPALS" \
           -V "always:forever" "$WORK/id_ed25519.pub" >/dev/null
rm -f "$WORK/user_ca"

# ----- agenix-encrypt the priv -------------------------------------------
# agenix -e opens $EDITOR <tempfile>. Setting EDITOR to "cp $WORK/id_ed25519"
# makes that "cp $WORK/id_ed25519 <tempfile>", clobbering the empty tempfile
# with our priv content. On EDITOR exit agenix re-encrypts.

echo "agenix-encrypting priv → $(rel "$AGENIX_ABS")"
cd "$REPO_ROOT/secrets"
EDITOR="cp $WORK/id_ed25519" \
  nix --extra-experimental-features 'nix-command flakes' \
      run github:ryantm/agenix -- \
        -i "$AGE_IDENTITY" \
        -e "$AGENIX_REL" >/dev/null \
  || die "agenix encrypt failed (is $AGENIX_REL declared in secrets/secrets.nix?)"
cd - >/dev/null

# ----- place pub + cert plaintext in lib/users/ ---------------------------

install -m 644 "$WORK/id_ed25519.pub"      "$PUB_OUT"
install -m 644 "$WORK/id_ed25519-cert.pub" "$CERT_OUT"

# ----- report -------------------------------------------------------------

echo
echo "Provisioned $SLOT:"
echo "  $(rel "$AGENIX_ABS")"
echo "  $(rel "$PUB_OUT")"
echo "  $(rel "$CERT_OUT")"
echo
echo "Certificate (ssh-keygen -L):"
ssh-keygen -L -f "$CERT_OUT" | sed -E 's/^/  /'
echo
echo "Next:"
echo "  git add -A && git commit -m '$HOSTNAME: provision $USER_NAME user cert' && git push"
echo "  on $HOSTNAME:  git pull && sudo nixos-rebuild switch --flake .#$HOSTNAME"
