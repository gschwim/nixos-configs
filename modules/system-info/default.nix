# Host metadata at /etc/nixos-host-info + `nixctl` helper command.
#
# The metadata file is declaratively managed via environment.etc (store
# symlink, tampering reverts on next `ls`). All fields are build-time-known:
#
#   HOSTNAME              networking.hostName
#   FLAKE_TARGET          same as HOSTNAME (our flake.nix convention)
#   ROLE                  my.host.role
#   DESKTOP_ENVIRONMENT   derived from my.desktop.*.enable
#   REBUILD_COMMIT        inputs.self.dirtyRev / .rev / "unknown"
#
# REBUILD_DATE is NOT stored in the file — it's computed from the mtime of
# /nix/var/nix/profiles/system by the `nixctl info` helper. That symlink
# is updated by nixos-rebuild switch/boot, lives on persistent storage, and
# is the canonical source for "when did this rebuild's generation activate."

{ config, lib, pkgs, inputs, ... }:
let
  hostName = config.networking.hostName;
  role     = config.my.host.role;

  desktopEnv =
    if config.my.desktop.gnome.enable then "gnome"
    else                                   "none";

  rebuildCommit =
    inputs.self.dirtyRev or inputs.self.rev or "unknown";

  # writeShellApplication validates the script (shellcheck + bash -n) at
  # build time, which catches typos and quoting issues early.
  #
  # excludeShellChecks: SC1090 ("can't follow non-constant source") fires on
  # `. "$INFO_FILE"` — fair as a generic warning but the source path is
  # under our control (placed at /etc/nixos-host-info by environment.etc
  # above), so the check has nothing useful to add.
  nixctl = pkgs.writeShellApplication {
    name = "nixctl";
    runtimeInputs = [ pkgs.util-linux pkgs.git ];   # `column` (util-linux) + `pull`
    excludeShellChecks = [ "SC1090" ];
    text = builtins.readFile ./nixctl.sh;
  };
in {
  environment.etc."nixos-host-info".text = ''
    HOSTNAME=${hostName}
    FLAKE_TARGET=${hostName}
    ROLE=${role}
    DESKTOP_ENVIRONMENT=${desktopEnv}
    REBUILD_COMMIT=${rebuildCommit}
  '';

  environment.systemPackages = [ nixctl ];
}
