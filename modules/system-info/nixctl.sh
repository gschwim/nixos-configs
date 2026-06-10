#!/usr/bin/env bash
# nixctl — surface or act on this host's NixOS-flake metadata.
#
# Subcommands:
#   nixctl info               Pretty-print /etc/nixos-host-info plus the
#                             rebuild date (computed from the persistent
#                             system profile symlink's mtime).
#   nixctl rebuild [<target>] Run `sudo nixos-rebuild switch --flake $NIXOS_CONFIGS_DIR#<target>`.
#                             Without <target>, uses FLAKE_TARGET from the
#                             info file. Override to rebuild a sibling
#                             host's config locally for testing.
#
# Repo discovery: NIXOS_CONFIGS_DIR is expected to be set by home-manager.
# Hard-fail otherwise (no fallback) — the bootstrap moment without HM is
# rare enough to do `cd <repo> && sudo nixos-rebuild …` directly.

set -euo pipefail

INFO_FILE=/etc/nixos-host-info
PROFILE=/nix/var/nix/profiles/system

info() {
  . "$INFO_FILE"
  rebuild_date=$(date -u -d "@$(stat -c %Y "$PROFILE")" +%Y-%m-%dT%H:%M:%SZ)
  {
    echo "FIELD=VALUE"
    echo "HOSTNAME=$HOSTNAME"
    echo "FLAKE_TARGET=$FLAKE_TARGET"
    echo "ROLE=$ROLE"
    echo "DESKTOP_ENVIRONMENT=$DESKTOP_ENVIRONMENT"
    echo "REBUILD_COMMIT=$REBUILD_COMMIT"
    echo "REBUILD_DATE=$rebuild_date"
  } | column -t -s '='
}

find_repo() {
  if [ -n "${NIXOS_CONFIGS_DIR:-}" ] && [ -d "$NIXOS_CONFIGS_DIR" ]; then
    echo "$NIXOS_CONFIGS_DIR"
    return 0
  fi
  cat >&2 <<EOF
nixctl: \$NIXOS_CONFIGS_DIR not set or doesn't point at a directory.
  This var is expected to be set by your home-manager configuration.
  Until that's set up, use 'cd <repo> && sudo nixos-rebuild …' directly.
EOF
  return 1
}

rebuild() {
  local target
  if [ "$#" -gt 0 ] && [ "${1:0:1}" != "-" ]; then
    target="$1"; shift
  else
    target=$(. "$INFO_FILE" && echo "$FLAKE_TARGET")
  fi
  local repo
  repo=$(find_repo) || exit 1

  if [ "$(id -u)" -ne 0 ]; then
    exec sudo --preserve-env=HOME,NIXOS_CONFIGS_DIR "$0" rebuild "$target" "$@"
  fi
  exec nixos-rebuild switch --flake "$repo#$target" "$@"
}

case "${1:-info}" in
  info)      info ;;
  rebuild)   shift; rebuild "$@" ;;
  -h|--help) echo "usage: nixctl [info|rebuild [<target-override>]]" ;;
  *)         echo "nixctl: unknown subcommand: $1" >&2; exit 1 ;;
esac
