#!/usr/bin/env bash
# makeiso.sh — build the custom installer ISO and, optionally, write it to USB.
#
# Usage:
#   scripts/makeiso.sh [--device /dev/sdX] [--yes]
#
# Options:
#   --device /dev/sdX   Write to this disk without the "which disk?" prompt.
#   -y, --yes           Skip interactive confirmations (USB write still needs
#                       --device; without it there is nothing to confirm).
#
# What it does:
#   1. Refuses to run on anything that is not Linux (the installer image is
#      x86_64-linux; both the build and the dd-to-USB step need Linux).
#   2. nix build .#nixosConfigurations.installer.config.system.build.isoImage
#   3. Resolves the built .iso under ./result/iso/.
#   4. Offers to copy it to a USB disk: lists candidate disks, takes the
#      target, double-confirms the destructive write, then dd's it via sudo.
#
# Run this on a Linux machine with Nix (ideally NixOS). On macOS it stops
# early — build on / copy from a NixOS box instead.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAKE_ATTR='.#nixosConfigurations.installer.config.system.build.isoImage'

DEVICE=""
ASSUME_YES=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)   DEVICE="${2:?--device needs an argument}"; shift 2 ;;
    --device=*) DEVICE="${1#*=}"; shift ;;
    -y|--yes)   ASSUME_YES=1; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage 1 ;;
  esac
done

# --- 1. Host sanity ---------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
  cat >&2 <<EOF
ERROR: makeiso.sh must run on a Linux machine.
  Detected: $(uname -s) $(uname -m)
  The installer ISO is x86_64-linux; building it and writing it to USB both
  need Linux. On macOS, run this on a NixOS box (or a Linux remote builder).
EOF
  exit 1
fi

if ! command -v nix >/dev/null 2>&1; then
  echo "ERROR: 'nix' is not on PATH — this needs a Nix/NixOS system." >&2
  exit 1
fi

# Linux + Nix but not NixOS: the flake build can still work, just flag it.
if [ -r /etc/os-release ] && ! grep -q '^ID=nixos' /etc/os-release; then
  echo "NOTE: this is Linux with Nix but doesn't look like NixOS — proceeding." >&2
fi

# --- 2. Build ---------------------------------------------------------------
echo "==> Building installer ISO (this can take a while)…"
cd "$REPO_ROOT"
nix build "$FLAKE_ATTR" --print-build-logs

# --- 3. Locate the .iso -----------------------------------------------------
shopt -s nullglob
isos=(result/iso/*.iso)
shopt -u nullglob
if [ "${#isos[@]}" -eq 0 ]; then
  echo "ERROR: build finished but no .iso found under result/iso/" >&2
  exit 1
fi
ISO="$(readlink -f "${isos[0]}")"
echo "==> Built: $ISO ($(du -h "$ISO" | cut -f1))"

# --- 4. Optional: write to USB ---------------------------------------------
if [ -z "$DEVICE" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    echo "==> --yes with no --device: skipping USB write. ISO at $ISO"
    exit 0
  fi
  read -rp "Copy this ISO to a USB disk now? (y/N) " ans
  case "$ans" in
    [Yy]*) ;;
    *) echo "Done. ISO at $ISO"; exit 0 ;;
  esac
  echo
  echo "Available disks:"
  lsblk -dpno NAME,SIZE,MODEL,TRAN | awk '{print "  " $0}'
  echo
  read -rp "Target device (e.g. /dev/sdb): " DEVICE
fi

[ -n "$DEVICE" ] || { echo "No device given. Done — ISO at $ISO"; exit 0; }

if [ ! -b "$DEVICE" ]; then
  echo "ERROR: '$DEVICE' is not a block device." >&2
  exit 1
fi

# Guard: never clobber the disk backing the running root filesystem.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
case "$ROOT_SRC" in
  "$DEVICE"|"$DEVICE"[0-9]*|"${DEVICE}p"[0-9]*)
    echo "ERROR: $DEVICE backs the running root filesystem. Refusing to write." >&2
    exit 1 ;;
esac

echo
echo "About to OVERWRITE the following device — ALL DATA ON IT WILL BE LOST:"
lsblk -po NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,TRAN "$DEVICE" | awk '{print "  " $0}'
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  read -rp "Re-type the device path to confirm ($DEVICE): " confirm
  [ "$confirm" = "$DEVICE" ] || { echo "Mismatch — aborting, nothing written."; exit 1; }
fi

echo "==> Writing ISO to $DEVICE (sudo required)…"
sudo -v

# Unmount any mounted partitions of the target before writing.
while IFS= read -r part; do
  [ "$part" = "$DEVICE" ] && continue
  sudo umount "$part" 2>/dev/null || true
done < <(lsblk -lnpo NAME "$DEVICE")

sudo dd if="$ISO" of="$DEVICE" bs=4M status=progress conv=fsync
sudo sync

echo "==> Done. ISO written to $DEVICE — safe to remove."
