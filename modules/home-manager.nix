{ config, lib, ... }:
let
  cfg = config.my.home-manager;
in {
  options.my.home-manager = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Wire home-manager as a NixOS module for the schwim user.";
    };
  };

  config = lib.mkIf cfg.enable {
    home-manager.useGlobalPkgs   = true;
    home-manager.useUserPackages = true;
    home-manager.users.schwim    = import ../home/schwim.nix;
  };
}
