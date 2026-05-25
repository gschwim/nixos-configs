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
  };
}
