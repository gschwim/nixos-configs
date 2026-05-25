{ config, lib, ... }:
let
  cfg = config.my.network.wireless;
in {
  options.my.network.wireless = {
    enable = lib.mkEnableOption "wpa_supplicant wireless networking";

    interface = lib.mkOption {
      type        = lib.types.str;
      description = "Wireless interface (e.g. wlp82s0).";
    };

    secretsFile = lib.mkOption {
      type        = lib.types.nullOr lib.types.path;
      default     = null;
      description = ''
        Path to a wpa_supplicant secrets file (key=value pairs, one per line).
        Per-network pskRaw fields reference these as "ext:<key>".
        Typically supplied via agenix: config.age.secrets."wifi-secrets".path.
      '';
    };

    networks = lib.mkOption {
      type    = lib.types.attrsOf (lib.types.submodule {
        options.pskRaw = lib.mkOption {
          type        = lib.types.str;
          description = ''
            Either a literal 64-hex-char PSK, or an external reference
            "ext:<key>" pointing into secretsFile.
          '';
        };
      });
      default = {};
      description = "SSID -> network configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.wireless = {
      enable      = true;
      interfaces  = [ cfg.interface ];
      secretsFile = cfg.secretsFile;
      networks    = lib.mapAttrs (_: net: { pskRaw = net.pskRaw; }) cfg.networks;
    };
  };
}
