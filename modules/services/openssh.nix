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
  };

  config = lib.mkIf cfg.enable {
    services.openssh.enable = true;
    services.openssh.settings = {
      # Installed systems: never allow root SSH. Admin via schwim + sudo.
      # (The installer ISO overrides this to "prohibit-password" because
      # nixos-anywhere pivots to root@ mid-install — see hosts/installer.)
      PermitRootLogin        = lib.mkDefault "no";
      PasswordAuthentication = lib.mkDefault false;
    };
  };
}
