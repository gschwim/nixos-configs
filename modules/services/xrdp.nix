{ config, lib, pkgs, ... }:
let
  cfg = config.my.services.xrdp;
in {
  options.my.services.xrdp = {
    enable = lib.mkEnableOption "xrdp remote desktop (requires a desktop environment)";
  };

  config = lib.mkIf cfg.enable {
    services.xrdp.enable               = true;
    services.xrdp.openFirewall         = true;
    services.xrdp.defaultWindowManager = "${pkgs.gnome-session}/bin/gnome-session";
  };
}
