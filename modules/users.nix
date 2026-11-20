# Templated user accounts. Hosts pick named sets of people from the catalog in
# lib/users.nix instead of hand-listing users.users.<name> blocks, so changing
# who gets an account on which hosts is a one-line edit to a set.
#
# Per-host usage (hosts/<name>/default.nix or a guest overlay):
#   my.users.sets  = [ "admins" "bots" ];   # default: [ "admins" ]
#   my.users.extra = [ "ferb" ];            # one-off people, no set needed
#
# Every named set and person must exist in the catalog; a typo fails eval with
# a clear assertion instead of silently creating nothing.
#
# Imported by modules/default.nix (pets) and guests/base.nix (cattle).

{ config, lib, pkgs, ... }:
let
  cfg = config.my.users;
  catalog = import ../lib/users.nix { inherit pkgs; };

  missingSets = lib.filter (s: !(catalog.sets ? ${s})) cfg.sets;
  selected = lib.unique
    (lib.concatMap (s: catalog.sets.${s} or [ ]) cfg.sets ++ cfg.extra);
  missingPeople = lib.filter (u: !(catalog.people ? ${u})) selected;
in {
  options.my.users = {
    sets = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [ "admins" ];
      description = ''
        Named sets from lib/users.nix whose members get an account on this
        host. Defaults to just the admins (schwim) — today's fleet baseline.
      '';
    };

    extra = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [ ];
      description = ''
        Individual people from lib/users.nix to add on top of `sets`, for
        one-off access that doesn't warrant a new set.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = missingSets == [ ];
        message   = "my.users.sets: unknown set(s) ${toString missingSets} (see lib/users.nix)";
      }
      {
        assertion = missingPeople == [ ];
        message   = "my.users: unknown user(s) ${toString missingPeople} (see lib/users.nix)";
      }
    ];

    users.users = lib.genAttrs
      (lib.filter (u: catalog.people ? ${u}) selected)
      (u: catalog.people.${u});
  };
}
