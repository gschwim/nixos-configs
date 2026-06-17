{ config, lib, pkgs, ... }:
let
  cfg = config.my.services.xrdp;
in {
  options.my.services.xrdp = {
    enable = lib.mkEnableOption "xrdp remote desktop (requires a desktop environment)";
  };

  config = lib.mkIf cfg.enable {
    services.xrdp.enable       = true;
    services.xrdp.openFirewall = true;   # 3389/tcp → networking.firewall.allowedTCPPorts

    # Session derived from the active DE, so RDP login → desktop works on any DE.
    # xrdp serves a fresh X11 session, so each DE points at its X11 session entry.
    services.xrdp.defaultWindowManager =
      if config.my.desktop.kde.enable
      then "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-x11"
      else "${pkgs.gnome-session}/bin/gnome-session";

    assertions = [{
      assertion = config.my.desktop.gnome.enable || config.my.desktop.kde.enable;
      message   = "my.services.xrdp.enable requires a desktop environment (my.desktop.gnome.enable or my.desktop.kde.enable).";
    }];
  };
}
