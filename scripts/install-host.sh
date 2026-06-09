#!/usr/bin/env bash
# install-host.sh — install a NixOS host end-to-end from blushda using nixos-anywhere.
#
# Usage:
#   scripts/install-host.sh <hostname> <target-ip>
#
# Assumes the target is booted into a NixOS installer (graphical or minimal)
# with sshd running, your SSH key authorized for $INSTALL_USER (defaults to
# $USER on this machine), and that user granted passwordless sudo. The
# custom installer ISO built from this repo satisfies all three by default
# for the `schwim` user.
#
# In the installer beforehand:
#   sudo systemctl start sshd    # if not already running
#   ip a                         # find the address
#
# Override the SSH user via env if needed: INSTALL_USER=nixos ./install-host.sh ...
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
INSTALL_USER="${INSTALL_USER:-$USER}"

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

# Read management flag + users list from the flake config. Empty MGMT_USERS
# means "not a management host" (regardless of whether the flag literally
# evaluates false or this host doesn't set it).
MGMT_ENABLE="$(nix --extra-experimental-features 'nix-command flakes' \
  eval --raw "$REPO_ROOT#nixosConfigurations.$HOSTNAME.config.my.host.management.enable" \
  --apply 'b: if b then "1" else "0"' 2>/dev/null || echo 0)"

MGMT_USERS=""
if [ "$MGMT_ENABLE" = "1" ]; then
  MGMT_USERS="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --raw "$REPO_ROOT#nixosConfigurations.$HOSTNAME.config.my.host.management.users" \
    --apply 'l: builtins.concatStringsSep " " l')"
fi

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
echo "About to install NixOS host '$HOSTNAME' onto $INSTALL_USER@$TARGET."
echo "  Flake:       $REPO_ROOT#$HOSTNAME"
echo "  hostId:      $HOSTID"
echo "  Host key:    $HOST_KEY"
echo "  SSH as:      $INSTALL_USER (needs passwordless sudo on target)"
echo "  ⚠️  This WIPES the target disk (via disko)."
read -rp "Continue? (y/N) " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1

# ----- ensure host key exists ---------------------------------------------
# gen-host-key.sh is the single source of truth: it pulls from keepassxc
# when an entry exists, generates + pushes when not, and hard-fails on
# any mismatch with secrets/secrets.nix. It also prompts for KDBX_PW
# (once per shell) and exports it for any future invocations in the
# same session.

"$REPO_ROOT/scripts/gen-host-key.sh" "$HOSTNAME"

# ----- stage extra-files ---------------------------------------------------

rm -rf "$STAGING"

# The bootstrap age key — the one out-of-band artifact per host. agenix on
# the target uses this as its decryption identity (configured via
# `age.identityPaths = [ "/etc/age/host.key" ]` in modules/secrets.nix);
# everything else (SSH host priv, user-cert privs, etc.) is encrypted to
# the corresponding bootstrap age PUB and decrypted at activation.
BOOT_CACHE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/host-bootstrap-keys"
BOOT_KEY="$BOOT_CACHE_DIR/${HOSTNAME}.key"
[ -f "$BOOT_KEY" ] \
  || { echo "ERROR: missing bootstrap age key at $BOOT_KEY — did gen-host-key.sh complete?" >&2; exit 2; }
mkdir -p "$STAGING/etc/age"
install -m 400 -o root -g root "$BOOT_KEY" "$STAGING/etc/age/host.key" 2>/dev/null \
  || install -m 400 "$BOOT_KEY" "$STAGING/etc/age/host.key"
# (Fallback for macOS where -o root requires sudo we don't want; mode 400
# is preserved either way and nixos-anywhere chowns to root on the target.)

# Repo artifacts (SSH host pub + cert + agenix-encrypted priv) — sanity-check
# they exist; if they don't, the closure won't build. They aren't staged via
# extra-files anymore — they ride in the closure via environment.etc and
# age.secrets (see modules/services/openssh.nix).
for f in "$REPO_ROOT/lib/host-certs/${HOSTNAME}_ssh_host_ed25519_key.pub" \
         "$REPO_ROOT/lib/host-certs/${HOSTNAME}_ssh_host_ed25519_key-cert.pub" \
         "$REPO_ROOT/secrets/host-keys/${HOSTNAME}_ssh_host_ed25519_key.age"; do
  [ -f "$f" ] \
    || { echo "ERROR: missing $(echo "$f" | sed "s|$REPO_ROOT/||") — run scripts/gen-host-key.sh $HOSTNAME" >&2; exit 2; }
done

# User keys + certs for management hosts: again, just verify the repo
# artifacts exist. agenix decrypts on first activation; tmpfiles places
# pub+cert from the in-store paths.
if [ -n "$MGMT_USERS" ]; then
  for u in $MGMT_USERS; do
    slot="${HOSTNAME}_${u}"
    age_f="$REPO_ROOT/secrets/users/${slot}_id_ed25519.age"
    pub_f="$REPO_ROOT/lib/users/${slot}_id_ed25519.pub"
    cert_f="$REPO_ROOT/lib/users/${slot}_id_ed25519-cert.pub"
    for f in "$age_f" "$pub_f" "$cert_f"; do
      [ -f "$f" ] \
        || { echo "ERROR: missing $f — run scripts/provision-user-key.sh $HOSTNAME $u" >&2; exit 2; }
    done
  done
  echo "User-cert artifacts verified for: $MGMT_USERS"
fi

# ----- prep installer's hostid ---------------------------------------------

echo "Preflight on $TARGET as $INSTALL_USER (sudo for root ops):"
echo "  - set installer hostid to $HOSTID (for ZFS/disko)"
echo "  - seed /root/.ssh/authorized_keys (nixos-anywhere pivots to root@ mid-install)"
ssh "${SSH_OPTS[@]}" "$INSTALL_USER@$TARGET" "
  set -e
  sudo zgenhostid -fo /run/hostid $HOSTID
  sudo mount --bind /run/hostid /etc/hostid 2>/dev/null || true
  hostid

  sudo mkdir -p /root/.ssh
  sudo chmod 700 /root/.ssh
  # NixOS writes user-authorized keys to /etc/ssh/authorized_keys.d/<user>;
  # nixos-anywhere only looks at ~/.ssh/authorized_keys, so it can't auto-copy.
  # Try both sources; non-zero exit if neither exists.
  if [ -r /etc/ssh/authorized_keys.d/$INSTALL_USER ]; then
    sudo cp /etc/ssh/authorized_keys.d/$INSTALL_USER /root/.ssh/authorized_keys
  elif [ -r \$HOME/.ssh/authorized_keys ]; then
    sudo cp \$HOME/.ssh/authorized_keys /root/.ssh/authorized_keys
  else
    echo 'ERROR: no authorized_keys source found for $INSTALL_USER on target' >&2
    exit 1
  fi
  sudo chmod 600 /root/.ssh/authorized_keys
"

# ----- run nixos-anywhere --------------------------------------------------

echo
echo "Invoking nixos-anywhere → $INSTALL_USER@$TARGET (flake .#$HOSTNAME) …"
nix --extra-experimental-features 'nix-command flakes' \
    run github:nix-community/nixos-anywhere -- \
    --flake "$REPO_ROOT#$HOSTNAME" \
    --target-host "$INSTALL_USER@$TARGET" \
    --generate-hardware-config nixos-generate-config "$HOST_DIR/hardware-configuration.nix" \
    --extra-files "$STAGING" \
    --build-on remote \
    --ssh-option "StrictHostKeyChecking=no" \
    --ssh-option "UserKnownHostsFile=/dev/null"

# --build-on remote: blushda is darwin and can't build x86_64-linux closures.
# nixos-anywhere's default --build-on auto would otherwise run a probe
# derivation that prints a scary "required ... but I am darwin" error before
# silently falling back to remote anyway. Skipping the probe by being explicit.

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
