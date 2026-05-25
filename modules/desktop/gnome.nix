{ config, lib, pkgs, ... }:
let
  cfg = config.my.desktop.gnome;
in {
  options.my.desktop.gnome = {
    enable = lib.mkEnableOption "GNOME desktop environment (GDM, Pipewire, printing, Firefox)";
  };

  config = lib.mkIf cfg.enable {
    services.xserver.enable           = true;
    services.xserver.xkb.layout       = "us";
    services.displayManager.gdm.enable = true;
    services.desktopManager.gnome.enable = true;

    services.gnome.gnome-remote-desktop.enable = true;

    services.printing.enable = true;

    services.pulseaudio.enable = false;
    security.rtkit.enable      = true;
    services.pipewire = {
      enable            = true;
      alsa.enable       = true;
      alsa.support32Bit = true;
      pulse.enable      = true;
    };

    programs.firefox.enable = true;

    environment.systemPackages = with pkgs; [ gnome-remote-desktop ];
  };
}
