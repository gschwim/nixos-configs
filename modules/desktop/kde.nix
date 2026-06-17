# KDE Plasma 6 desktop environment.
#
# Shared desktop infra (display manager, audio, printing, browser) comes from
# modules/desktop/default.nix. The login manager defaults to GDM (which launches
# Plasma fine); set `my.desktop.displayManager = "sddm"` on the host for a native
# Plasma login. Remote desktop is xrdp (DE-derived to the Plasma X11 session).

{ config, lib, pkgs, ... }:
let
  cfg = config.my.desktop.kde;
in {
  options.my.desktop.kde = {
    enable = lib.mkEnableOption "KDE Plasma 6 desktop environment";
  };

  config = lib.mkIf cfg.enable {
    services.desktopManager.plasma6.enable = true;

    # Plasma 6 defaults to Wayland; an X11 session is also available (and is what
    # xrdp launches). To trim default apps, set e.g.:
    #   environment.plasma6.excludePackages = with pkgs.kdePackages; [ elisa ];
  };
}
