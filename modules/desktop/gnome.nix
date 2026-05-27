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

    # Fleet-wide GNOME defaults. Applied via dconf's system database, so
    # every user inherits these on first login but can still override per-
    # user with gsettings / GNOME Settings. NOT locks — these are defaults,
    # not policy.
    programs.dconf.profiles.user.databases = [{
      settings = with lib.gvariant; {
        "org/gnome/desktop/peripherals/touchpad" = {
          natural-scroll               = mkBoolean false;
          tap-to-click                 = mkBoolean true;
          two-finger-scrolling-enabled = mkBoolean true;
          edge-scrolling-enabled       = mkBoolean false;
          click-method                 = "fingers";
          speed                        = mkDouble 0.35;
        };

        "org/gnome/desktop/peripherals/mouse" = {
          natural-scroll = mkBoolean false;
          speed          = mkDouble 0.35;
          accel-profile  = "default";
        };

        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
        };

        "org/gnome/desktop/screensaver" = {
          lock-enabled = mkBoolean true;
          lock-delay   = mkUint32 300;
        };

        "org/gnome/desktop/notifications" = {
          show-in-lock-screen = mkBoolean false;
        };
      };
    }];
  };
}
