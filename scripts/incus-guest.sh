# incus-guest — build, import, and launch NixOS guests on incus.
#
# Guests compose as L0 base + L1 overlays (see docs/guests.md):
#   - base:  guests/base.nix  → flake attr `guest`         (Docker + tooling)
#   - breed: base + committed overlay(s) from guests/workloads/, wired as a
#            flake attr e.g. `guest-hermes` → build with `--config guest-hermes`
#   - local: base + a gitignored one-off from guests/local/, layered at build
#            time with `--extra-module <path>` (no commit, no flake attr)
#
# Build the image ONCE on this (Linux) incus host, then launch as many
# identical throwaway copies as you like.
#
# Usage:
#   incus-guest build  [--config <attr>] [--alias <name>] [--extra-module <path>]
#   incus-guest launch <name> [--alias <name>] [-- <incus flags>]
#   incus-guest help
#
# Examples:
#   incus-guest build                                   # base image → alias nixos-guest
#   incus-guest build --config guest-hermes             # a breed  → alias nixos-guest-hermes
#   incus-guest build --extra-module ./guests/local/probe.nix --alias nixos-probe
#   incus-guest launch dock01
#   incus-guest launch web01 --alias nixos-guest-hermes -- -p mem-8GB
#
# For a guest on an L2 network with a static IP, the imported image is just a
# local alias, so reuse the existing helper:
#   incus-launch dock02 nixos-guest --vm infra100:172.16.0.60 -- -p mem-4GB
#
# The build must run on a LINUX x86_64 host (the Mac workstation can't build
# x86_64-linux) — run it on the incus host itself, where the image is imported.
#
# Env:
#   GUEST_FLAKE   flake ref holding the guest nixosConfigurations + lib.mkGuest
#                 (default: ${NIXOS_CONFIGS:-$HOME/src/nixos-configs})
#   GUEST_ALIAS   default image alias for launch (default: nixos-guest)

set -euo pipefail

ALIAS_DEFAULT="${GUEST_ALIAS:-nixos-guest}"
FLAKE="${GUEST_FLAKE:-${NIXOS_CONFIGS:-$HOME/src/nixos-configs}}"

usage() {
  cat >&2 <<'EOF'
incus-guest — build, import, and launch NixOS guests on incus.

Usage:
  incus-guest build  [--config <attr>] [--alias <name>] [--extra-module <path>]
  incus-guest launch <name> [--alias <name>] [-- <incus flags>]
  incus-guest help

build:
  --config <attr>        nixosConfigurations.<attr> to build (default: guest).
                         Use for committed breeds, e.g. --config guest-hermes.
  --alias <name>         image alias to import as (default: nixos-<config>).
  --extra-module <path>  layer a gitignored local overlay onto the base guest
                         (the .zlocal pattern); implies an impure build.

launch:
  <name>                 instance name.
  --alias <name>         image to launch from (default: $GUEST_ALIAS = nixos-guest).
  -- <incus flags>       passed verbatim to `incus launch` (e.g. -p mem-8GB).

Examples:
  incus-guest build
  incus-guest build --config guest-hermes
  incus-guest build --extra-module ./guests/local/probe.nix --alias nixos-probe
  incus-guest launch dock01
  incus-guest launch web01 --alias nixos-guest-hermes -- -p mem-8GB

For an L2 static IP, reuse the existing helper (the image is just an alias):
  incus-launch dock02 nixos-guest --vm infra100:172.16.0.60 -- -p mem-4GB

Build runs on a LINUX x86_64 host (the Mac can't build x86_64-linux) — run it
on the incus host itself.

Env:
  GUEST_FLAKE   flake ref with the guest configs + lib.mkGuest
                (default: ${NIXOS_CONFIGS:-$HOME/src/nixos-configs})
  GUEST_ALIAS   default launch alias (default: nixos-guest)
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

# Build one system.build.<target> and print its out-path. With a local overlay
# ($3 set) we can't use a flake attr (the file is gitignored → invisible to the
# flake), so build via an impure expr that calls the flake's lib.mkGuest with the
# overlay as an absolute path literal. Otherwise build the flake attr directly.
build_target() {
  local config="$1" target="$2" modabs="${3:-}" flakeabs
  if [ -n "$modabs" ]; then
    flakeabs="$(realpath "$FLAKE" 2>/dev/null || printf '%s' "$FLAKE")"
    nix build --impure --no-link --print-out-paths --expr \
      "((builtins.getFlake \"$flakeabs\").lib.mkGuest { extraModules = [ $modabs ]; }).config.system.build.$target"
  else
    nix build --no-link --print-out-paths \
      "${FLAKE}#nixosConfigurations.${config}.config.system.build.${target}"
  fi
}

cmd_build() {
  local config="guest" alias="" mod=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)       config="${2:?--config needs a value}"; shift 2 ;;
      --alias)        alias="${2:?--alias needs a value}"; shift 2 ;;
      --extra-module) mod="${2:?--extra-module needs a path}"; shift 2 ;;
      -h|--help)      usage 0 ;;
      *) die "unknown build arg: $1" ;;
    esac
  done
  [ -n "$alias" ] || alias="nixos-${config}"

  local modabs=""
  if [ -n "$mod" ]; then
    [ -f "$mod" ] || die "extra module not found: $mod"
    modabs="$(realpath "$mod")"
    echo "Building guest image (base + local overlay $modabs) …"
  else
    echo "Building guest image from ${FLAKE}#${config} …"
  fi

  local meta_out img_out meta_tar img_qcow
  meta_out="$(build_target "$config" metadata  "$modabs")"
  img_out="$( build_target "$config" qemuImage "$modabs")"
  meta_tar="$(one_file "$meta_out" '*.tar.xz')"
  img_qcow="$(one_file "$img_out" '*.qcow2')"

  echo "  metadata: $meta_tar"
  echo "  rootfs:   $img_qcow"

  # Re-import replaces the previous image under this alias so relaunches pick up
  # the latest build. Deleting by alias is a no-op the first time.
  if incus image info "$alias" >/dev/null 2>&1; then
    echo "Removing existing image '$alias' …"
    incus image delete "$alias"
  fi

  echo "Importing as alias '$alias' …"
  incus image import "$meta_tar" "$img_qcow" --alias "$alias"
  echo "Done. Launch with: incus-guest launch <name> --alias $alias"
}

cmd_launch() {
  local alias="$ALIAS_DEFAULT" name="" extra=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --alias)   alias="${2:?--alias needs a value}"; shift 2 ;;
      --)        shift; extra=("$@"); break ;;
      -h|--help) usage 0 ;;
      -*)        die "unknown launch arg: $1" ;;
      *)         if [ -z "$name" ]; then name="$1"; shift; else die "unexpected arg: $1"; fi ;;
    esac
  done
  [ -n "$name" ] || usage

  echo "Launching guest '$name' from '$alias' (NAT) …"
  # security.secureboot=false: the NixOS VM image is not Secure-Boot signed.
  incus launch "$alias" "$name" --vm \
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
