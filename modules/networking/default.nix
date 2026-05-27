{ config, lib, ... }:
let
  cfg = config.my.networking;
  nmOn = cfg.enable && cfg.networkmanager.enable;

  # Interfaces that have any explicit Nix-side static IP configuration get
  # auto-excluded from NM so declarative + NM coexist without fighting.
  # Mechanism: list ifaces under `networking.interfaces.<name>.ipv4.addresses`
  # or `.ipv6.addresses`. The my.network.static module already emits one of
  # those, and hosts can add more directly.
  staticIfaces = lib.attrNames (
    lib.filterAttrs
      (_: iface: iface.ipv4.addresses != [] || iface.ipv6.addresses != [])
      config.networking.interfaces
  );

  # Incus bridges + container/VM virtual ifaces. NM has no business touching
  # any of these; incus and its DHCP server own them.
  incusIfaces = lib.optionals config.my.services.incus.enable
    (map (n: n.name) config.virtualisation.incus.preseed.networks);

  # Always-unmanaged glob patterns when NM is on (container/VM dynamic ifaces).
  alwaysUnmanagedGlobs = [
    "interface-name:veth*"
    "interface-name:tap*"
    "interface-name:incusbr*"
  ];
in {
  options.my.networking = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Fleet baseline networking (nftables firewall + NetworkManager toggle).";
    };

    networkmanager = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = ''
          Enable NetworkManager on this host. Off across the fleet by default.

          When on:
          - Any iface with declarative `networking.interfaces.<x>.ipv4.addresses`
            (including those set via my.network.static) is auto-excluded from NM.
          - Incus bridges + veth* / tap* / incusbr* globs are auto-excluded.
          - Declarative wifi profiles (modules/networking/wifi-profiles.nix)
            are installed; users can also add ad-hoc profiles via nmcli that
            persist across reboots.
        '';
      };

      unmanaged = lib.mkOption {
        type    = lib.types.listOf lib.types.str;
        default = [];
        example = [ "interface-name:enp7s0" "interface-name:tun*" ];
        description = ''
          Extra NM match strings (full form, e.g. "interface-name:foo") for
          interfaces NM should ignore beyond the auto-excluded ones above.
          Use for out-of-band tunnels or interfaces you want hands-off but
          which don't have a static IP set in `networking.interfaces`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.networkmanager.enable = cfg.networkmanager.enable;
    networking.nftables.enable       = true;
    networking.firewall.enable       = true;

    networking.networkmanager.unmanaged = lib.mkIf nmOn (lib.unique (
      cfg.networkmanager.unmanaged
      ++ map (n: "interface-name:${n}") (staticIfaces ++ incusIfaces)
      ++ alwaysUnmanagedGlobs
    ));
  };

  # Don't route via interfaces that lost carrier — otherwise a multi-homed
  # host with a higher-metric fallback (wifi behind wired, etc.) keeps
  # sending traffic out the dead iface because Linux's default is to honor
  # linkdown routes. Single-homed hosts are unaffected.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.ignore_routes_with_linkdown"     = 1;
    "net.ipv4.conf.default.ignore_routes_with_linkdown" = 1;
    "net.ipv6.conf.all.ignore_routes_with_linkdown"     = 1;
    "net.ipv6.conf.default.ignore_routes_with_linkdown" = 1;
  };


}
