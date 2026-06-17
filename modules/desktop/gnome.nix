# GNOME desktop environment — GNOME-specific bits only.
#
# Shared desktop infra (xserver, display manager, audio, printing, browser) lives
# in modules/desktop/default.nix and activates whenever any DE is on.
#
# Remote access: xrdp (modules/services/xrdp.nix) is the DE-agnostic primary — it
# serves a fresh X11 session for whatever DE the host runs. GNOME ALSO keeps its
# native gnome-remote-desktop here (the GNOME module enables it by default); it
# shares the *live* session on demand and does not bind RDP/3389 unless you turn
# on Settings → Sharing, so the two coexist without conflict.

{ config, lib, pkgs, ... }:
let
  cfg = config.my.desktop.gnome;
in {
  options.my.desktop.gnome = {
    enable = lib.mkEnableOption "GNOME desktop environment";
  };

  config = lib.mkIf cfg.enable {
    services.desktopManager.gnome.enable = true;

    # GNOME's native remote desktop (live-session sharing, on-demand). Kept
    # alongside xrdp; see the header note. Explicit here to make intent clear
    # even though the GNOME module also enables it by default.
    services.gnome.gnome-remote-desktop.enable = true;

    # GNOME is only supported behind GDM (NixOS GNOME wiki). Guard against an
    # accidental SDDM override on a GNOME host.
    assertions = [{
      assertion = config.my.desktop.displayManager == "gdm";
      message   = ''
        GNOME (my.desktop.gnome.enable) requires my.desktop.displayManager = "gdm";
        GNOME on a non-GDM login manager is unsupported.
      '';
    }];

    environment.systemPackages = with pkgs; [
      gnome-remote-desktop           # grdctl + the daemon package
      gnomeExtensions.appindicator   # legacy tray icons (Dropbox, Slack, etc.)
    ];

    # Fleet-wide GNOME defaults. Applied via dconf's system database, so every
    # user inherits these on first login but can still override per-user with
    # gsettings / GNOME Settings. NOT locks — these are defaults, not policy.
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

        # Enable installed shell extensions. New users get this by default;
        # existing users who've touched their extension list have their
        # per-user value override this — toggle from the GNOME Extensions
        # app if so.
        "org/gnome/shell" = {
          enabled-extensions = [
            "appindicatorsupport@rgcjonas.gmail.com"
          ];
        };
      };
    }];
  };
}
