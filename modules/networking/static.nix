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

    bridge = lib.mkOption {
      type        = lib.types.nullOr lib.types.str;
      default     = null;
      example     = "users1";
      description = ''
        If set, create this Linux bridge enslaving `interface`, and put the
        host's static IP on the BRIDGE instead of the bare interface. Used to
        give incus instances L2 access to the interface's native (untagged)
        VLAN: attach instances to this bridge (e.g. an incus `bridged` NIC with
        `parent = <bridge>`) and they land on the same segment as the host.

        Note: the management IP moves off `interface` onto the bridge — plan a
        reboot and have console access when first applying this to a live host.
        Tagged VLAN subifs declared on `interface` (networking.vlans."<if>.N")
        keep working alongside the bridge.
      '';
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

  config = lib.mkIf cfg.enable (
    let
      # Where the L3 address lives: the bridge when bridging, else the iface.
      ipIface = if cfg.bridge != null then cfg.bridge else cfg.interface;
    in {
      networking.interfaces.${ipIface} = {
        useDHCP = false;
        ipv4.addresses = [{
          address      = cfg.address;
          prefixLength = cfg.prefixLength;
        }];
      };

      networking.defaultGateway = {
        address   = cfg.gateway;
        interface = ipIface;
      };

      networking.nameservers = cfg.nameservers;

      # When bridging, NixOS creates the bridge and enslaves the primary iface;
      # the iface itself becomes a bare bridge port (no L3).
      networking.bridges = lib.mkIf (cfg.bridge != null) {
        ${cfg.bridge}.interfaces = [ cfg.interface ];
      };
    }
  );
}
