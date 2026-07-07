# incus-guest — build, import, and launch cattle NixOS guests on incus.
#
# These are disposable NixOS VMs built from one golden config
# (guests/base.nix, flake attr nixosConfigurations.guest): Docker enabled, the
# admin SSH keys + home-manager tooling from modules/base, no per-guest state.
# Build the image ONCE on this (Linux) incus host, then launch as many
# identical throwaway copies as you like.
#
# Usage:
#   incus-guest build [--alias <name>]        # build + (re)import the golden image
#   incus-guest launch <name> [-- <incus flags>]   # launch a NAT guest from it
#   incus-guest help
#
# Examples:
#   incus-guest build
#   incus-guest launch dock01
#   incus-guest launch dock01 -- -p storage-80GB -p mem-8GB
#
# For a guest on an L2 network with a static IP, the imported image is just a
# local alias, so reuse the existing helper:
#   incus-launch dock02 nixos-guest --vm infra100:172.16.0.60 -- -p mem-4GB
#
# The build must run on a LINUX x86_64 host (the Mac workstation can't build
# x86_64-linux) — run it on the incus host itself, where the image is imported.
#
# Env:
#   GUEST_FLAKE   flake ref holding nixosConfigurations.guest
#                 (default: ${NIXOS_CONFIGS:-$HOME/src/nixos-configs})
#   GUEST_ALIAS   default image alias (default: nixos-guest)

set -euo pipefail

ALIAS_DEFAULT="${GUEST_ALIAS:-nixos-guest}"
FLAKE="${GUEST_FLAKE:-${NIXOS_CONFIGS:-$HOME/src/nixos-configs}}"

usage() {
  cat >&2 <<'EOF'
incus-guest — build, import, and launch cattle NixOS guests on incus.

Usage:
  incus-guest build [--alias <name>]              build + (re)import the golden image
  incus-guest launch <name> [-- <incus flags>]    launch a NAT guest from it
  incus-guest help

Examples:
  incus-guest build
  incus-guest launch dock01
  incus-guest launch dock01 -- -p storage-80GB -p mem-8GB

For a guest on an L2 network with a static IP, reuse the existing helper
(the imported image is just a local alias):
  incus-launch dock02 nixos-guest --vm infra100:172.16.0.60 -- -p mem-4GB

Build runs on a LINUX x86_64 host (the Mac can't build x86_64-linux) — run it
on the incus host itself.

Env:
  GUEST_FLAKE   flake ref with nixosConfigurations.guest
                (default: ${NIXOS_CONFIGS:-$HOME/src/nixos-configs})
  GUEST_ALIAS   default image alias (default: nixos-guest)
EOF
  exit "${1:-1}"
}

die() { echo "ERROR: $*" >&2; exit 2; }

# Print the single file under $1 matching glob $2, or die.
one_file() {
  local dir="$1" pat="$2" f
  f="$(find "$dir" -maxdepth 2 -name "$pat" -type f | head -n1)"
  [ -n "$f" ] || die "no file matching '$pat' under $dir"
  printf '%s' "$f"
}

cmd_build() {
  local alias="$ALIAS_DEFAULT"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --alias) alias="${2:?--alias needs a value}"; shift 2 ;;
      -h|--help) usage 0 ;;
      *) die "unknown build arg: $1" ;;
    esac
  done

  echo "Building golden guest image from ${FLAKE}#guest …"
  local meta_out img_out meta_tar img_qcow
  meta_out="$(nix build --no-link --print-out-paths \
    "${FLAKE}#nixosConfigurations.guest.config.system.build.metadata")"
  img_out="$(nix build --no-link --print-out-paths \
    "${FLAKE}#nixosConfigurations.guest.config.system.build.qemuImage")"

  meta_tar="$(one_file "$meta_out" '*.tar.xz')"
  img_qcow="$(one_file "$img_out" '*.qcow2')"

  echo "  metadata: $meta_tar"
  echo "  rootfs:   $img_qcow"

  # Re-import replaces the previous golden image so cattle relaunch off the
  # latest build. Deleting by alias is a no-op the first time.
  if incus image info "$alias" >/dev/null 2>&1; then
    echo "Removing existing image '$alias' …"
    incus image delete "$alias"
  fi

  echo "Importing as alias '$alias' …"
  incus image import "$meta_tar" "$img_qcow" --alias "$alias"
  echo "Done. Launch with: incus-guest launch <name>"
}

cmd_launch() {
  [ "$#" -ge 1 ] || usage
  local name="$1"; shift
  local extra=()
  if [ "${1:-}" = "--" ]; then shift; extra=("$@"); fi

  echo "Launching cattle guest '$name' from '$ALIAS_DEFAULT' (NAT) …"
  # security.secureboot=false: the NixOS VM image is not Secure-Boot signed.
  incus launch "$ALIAS_DEFAULT" "$name" --vm \
    -c security.secureboot=false \
    "${extra[@]}"
  echo "Launched. Check: incus list $name"
}

[ "$#" -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  build)  cmd_build  "$@" ;;
  launch) cmd_launch "$@" ;;
  help|-h|--help) usage 0 ;;
  *) die "unknown subcommand: $sub (try: build | launch | help)" ;;
esac
