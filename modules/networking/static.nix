{ config, lib, ... }:
let
  cfg = config.my.network.static;
in {
  options.my.network.static = {
    enable = lib.mkEnableOption "static IPv4 configuration on a single interface";

    interface = lib.mkOption {
      type        = lib.types.str;
      description = "Network interface to configure (e.g. eno1, wlp82s0).";
    };

    address = lib.mkOption {
      type        = lib.types.str;
      description = "IPv4 address (no prefix).";
    };

    prefixLength = lib.mkOption {
      type        = lib.types.int;
      default     = 24;
      description = "IPv4 prefix length.";
    };

    gateway = lib.mkOption {
      type        = lib.types.str;
      description = "Default gateway IPv4 address.";
    };

    nameservers = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [];
      description = "DNS resolvers.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.interfaces.${cfg.interface} = {
      useDHCP = false;
      ipv4.addresses = [{
        address      = cfg.address;
        prefixLength = cfg.prefixLength;
      }];
    };

    networking.defaultGateway = {
      address   = cfg.gateway;
      interface = cfg.interface;
    };

    networking.nameservers = cfg.nameservers;
  };
}
