{ config, lib, ... }:
let
  cfg = config.my.services.openssh;
in {
  options.my.services.openssh = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "OpenSSH server (default-on baseline).";
    };

    useHostCertificate = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Present a CA-signed host certificate to clients. Requires the file
        /etc/ssh/ssh_host_ed25519_key-cert.pub to exist — install-host.sh
        stages it as part of the install. Disable on ephemeral live ISOs
        and any host whose key hasn't been signed yet.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh.enable = true;
    services.openssh.settings = lib.mkMerge [
      {
        # Installed systems: never allow root SSH. Admin via schwim + sudo.
        # (The installer ISO overrides this to "prohibit-password" because
        # nixos-anywhere pivots to root@ mid-install — see hosts/installer.)
        PermitRootLogin        = lib.mkDefault "no";
        PasswordAuthentication = lib.mkDefault false;
      }
      (lib.mkIf cfg.useHostCertificate {
        HostCertificate = "/etc/ssh/ssh_host_ed25519_key-cert.pub";
      })
    ];
  };
}
