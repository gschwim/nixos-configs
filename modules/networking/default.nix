{ config, lib, ... }:
let
  cfg = config.my.networking;
in {
  options.my.networking = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Fleet baseline networking (nftables firewall, NetworkManager off).";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.networkmanager.enable = false;
    networking.nftables.enable       = true;
    networking.firewall.enable       = true;
  };
}
