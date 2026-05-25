#!/usr/bin/env bash
# new-host.sh — scaffold a new host directory from a template.
#
# Usage:
#   scripts/new-host.sh <hostname> <type>
#
# Where <type> is one of:
#   server   — headless, no DE/wireless, minimal toggles
#   desktop  — wireless + GNOME + xrdp, hardware module placeholder
#
# What it does:
#   1. Creates hosts/<hostname>/{default.nix, hardware-configuration.nix}
#      from the matching template, substituting hostname + a random hostId.
#   2. Prints the line to add to flake.nix (does NOT edit flake.nix itself).
#
# What it does NOT do:
#   - Generate SSH host keys (that's install-host.sh's job).
#   - Edit secrets/secrets.nix (manual).
#   - Edit flake.nix (manual — too easy to corrupt).

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

[ "$#" -eq 2 ] || usage

HOSTNAME="$1"
TYPE="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_DIR="$REPO_ROOT/hosts/$HOSTNAME"
TEMPLATE_DIR="$REPO_ROOT/hosts/_templates"

case "$TYPE" in
  server|desktop) ;;
  *) echo "ERROR: unknown type '$TYPE' (expected: server, desktop)" >&2; exit 2 ;;
esac

[ -d "$HOST_DIR" ] && { echo "ERROR: $HOST_DIR already exists" >&2; exit 2; }
[ -f "$TEMPLATE_DIR/$TYPE.nix" ] || { echo "ERROR: template $TEMPLATE_DIR/$TYPE.nix missing" >&2; exit 2; }

# Random 8-hex hostId for ZFS.
HOSTID="$(openssl rand -hex 4)"

mkdir -p "$HOST_DIR"

# Substitute placeholders into the template.
sed -e "s/@HOSTNAME@/$HOSTNAME/g" \
    -e "s/@HOSTID@/$HOSTID/g" \
    "$TEMPLATE_DIR/$TYPE.nix" > "$HOST_DIR/default.nix"

cp "$TEMPLATE_DIR/hardware-configuration.nix" "$HOST_DIR/hardware-configuration.nix"

cat <<EOF
Created hosts/$HOSTNAME/ from the '$TYPE' template.
  hostId: $HOSTID  (also written into hosts/$HOSTNAME/default.nix)

Next steps:

  1. Edit hosts/$HOSTNAME/default.nix:
       - confirm disk device, NIC name, static IP
       - flip the feature toggles you need

  2. Add this host to flake.nix nixosConfigurations:
       $HOSTNAME = mkHost { hostName = "$HOSTNAME"; system = "x86_64-linux"; };

  3. Run scripts/install-host.sh $HOSTNAME <target-ip> to actually install it.
EOF
