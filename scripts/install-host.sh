#!/usr/bin/env bash
# install-host.sh — install a NixOS host end-to-end from blushda using nixos-anywhere.
#
# Usage:
#   scripts/install-host.sh <hostname> <target-ip>
#
# Assumes the target is booted into a NixOS installer (graphical or minimal)
# with sshd running and reachable as root@<target-ip>.
#
# In the installer beforehand:
#   sudo passwd root             # set a password
#   sudo systemctl start sshd    # if not already running
#   ip a                         # find the address
#
# What this script does:
#   1. Reads the host's networking.hostId from hosts/<name>/default.nix.
#   2. Ensures an ed25519 SSH host key exists for this host at
#      ~/.local/share/nixos-configs/host-keys/<hostname>_ed25519 (generates
#      it if missing).
#   3. Stages an extra-files directory placing that key at /etc/ssh/ on the
#      target before nixos-install runs.
#   4. SSHes to the installer and sets its hostid to match (works around the
#      disko + ZFS hostid first-boot mismatch).
#   5. Invokes nixos-anywhere: it runs disko, generates and pulls back a real
#      hardware-configuration.nix, copies the closure, and installs.
#   6. Reminds you to commit the generated hardware-configuration.nix.
#
# Prerequisites:
#   - You have added the host's pubkey to secrets/secrets.nix as a recipient
#     for any secrets it needs (e.g. wifi-secrets), then run `agenix -r`,
#     committed, and pushed. This script reminds you and prompts to continue.
#
# After this script: target reboots fully configured. No second rebuild needed.

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

[ "$#" -eq 2 ] || usage

HOSTNAME="$1"
TARGET="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_DIR="$REPO_ROOT/hosts/$HOSTNAME"
HOST_KEY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/host-keys"
HOST_KEY="$HOST_KEY_DIR/${HOSTNAME}_ed25519"
STAGING="${TMPDIR:-/tmp}/nixos-anywhere-staging-$HOSTNAME"

# SSH options for installer connections. Installer ISOs are ephemeral —
# every reboot regenerates the host key, so a stable known_hosts entry
# would only cause "host key changed" errors on re-installs.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# Portable lowercase->uppercase (works on bash 3.2 / macOS default).
HOSTNAME_UPPER="$(printf '%s' "$HOSTNAME" | tr '[:lower:]' '[:upper:]')"

# ----- preflight ------------------------------------------------------------

[ -d "$HOST_DIR" ] || { echo "ERROR: $HOST_DIR not found. Run scripts/new-host.sh first." >&2; exit 2; }
[ -f "$HOST_DIR/default.nix" ] || { echo "ERROR: $HOST_DIR/default.nix not found." >&2; exit 2; }

HOSTID="$(grep -E '^\s*networking\.hostId\s*=' "$HOST_DIR/default.nix" \
          | sed -E 's/.*"([^"]+)".*/\1/' | head -n1)"
case "$HOSTID" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
  *) echo "ERROR: could not parse 8-hex hostId from $HOST_DIR/default.nix (got: '$HOSTID')" >&2; exit 2 ;;
esac

# Confirm secrets.nix recipient list is set up.
if grep -q "REPLACE_WITH_${HOSTNAME_UPPER}_HOST_PUBKEY" "$REPO_ROOT/secrets/secrets.nix" 2>/dev/null; then
  echo "WARNING: $REPO_ROOT/secrets/secrets.nix still contains a placeholder for $HOSTNAME."
  echo "         If $HOSTNAME needs to decrypt any agenix secret on first boot,"
  echo "         you must (1) generate its host key here first, (2) paste the pubkey"
  echo "         into secrets/secrets.nix, (3) add it to the relevant publicKeys"
  echo "         lists, (4) run 'agenix -r' from the secrets/ directory,"
  echo "         (5) commit and push BEFORE continuing."
  echo
  read -rp "Continue anyway? (y/N) " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1
fi

# Destructive-action confirmation. nixos-anywhere will erase the target's
# disk via disko — make sure we mean it.
echo
echo "About to install NixOS host '$HOSTNAME' onto root@$TARGET."
echo "  Flake:       $REPO_ROOT#$HOSTNAME"
echo "  hostId:      $HOSTID"
echo "  Host key:    $HOST_KEY"
echo "  ⚠️  This WIPES the target disk (via disko)."
read -rp "Continue? (y/N) " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1

# ----- ensure host key exists ---------------------------------------------

mkdir -p "$HOST_KEY_DIR"
chmod 700 "$HOST_KEY_DIR"

if [ ! -f "$HOST_KEY" ]; then
  echo "Generating ed25519 host key for $HOSTNAME → $HOST_KEY"
  ssh-keygen -t ed25519 -N "" -f "$HOST_KEY" -C "root@$HOSTNAME"
else
  echo "Using existing host key at $HOST_KEY"
fi

echo
echo "Pubkey (paste into secrets/secrets.nix as '$HOSTNAME' if not already done):"
cat "${HOST_KEY}.pub"
echo

# ----- stage extra-files ---------------------------------------------------

rm -rf "$STAGING"
mkdir -p "$STAGING/etc/ssh"
install -m 600 "$HOST_KEY"      "$STAGING/etc/ssh/ssh_host_ed25519_key"
install -m 644 "${HOST_KEY}.pub" "$STAGING/etc/ssh/ssh_host_ed25519_key.pub"

# ----- prep installer's hostid ---------------------------------------------

echo "Setting installer's hostid on $TARGET to $HOSTID …"
ssh "${SSH_OPTS[@]}" "root@$TARGET" "
  set -e
  zgenhostid -fo /run/hostid $HOSTID
  mount --bind /run/hostid /etc/hostid 2>/dev/null || true
  hostid
"

# ----- run nixos-anywhere --------------------------------------------------

echo
echo "Invoking nixos-anywhere → root@$TARGET (flake .#$HOSTNAME) …"
nix --extra-experimental-features 'nix-command flakes' \
    run github:nix-community/nixos-anywhere -- \
    --flake "$REPO_ROOT#$HOSTNAME" \
    --target-host "root@$TARGET" \
    --generate-hardware-config nixos-generate-config "$HOST_DIR/hardware-configuration.nix" \
    --extra-files "$STAGING" \
    --ssh-option "StrictHostKeyChecking=no" \
    --ssh-option "UserKnownHostsFile=/dev/null"

# ----- postflight ----------------------------------------------------------

cat <<EOF

Install finished. $HOSTNAME is rebooting.

Don't forget:

  1. Commit the regenerated hardware-configuration.nix:
       cd $REPO_ROOT
       git add hosts/$HOSTNAME/hardware-configuration.nix
       git commit -m "$HOSTNAME: hardware-configuration.nix from install"
       git push

  2. The pre-staged SSH host key for $HOSTNAME lives at:
       $HOST_KEY
     Back this up — it's the agenix decryption identity for $HOSTNAME. If you
     lose it and a re-install gets a new key, you must re-key every agenix
     secret encrypted to $HOSTNAME.
EOF
