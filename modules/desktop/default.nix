# Shared, DE-agnostic desktop infrastructure + the login-manager selector.
#
# Activates whenever ANY desktop environment (GNOME, KDE, …) is enabled, so the
# per-DE modules below only carry their DE-specific bits. The display manager is
# chosen here and is decoupled from the DE: GDM (the default, and GNOME's only
# supported DM) launches GNOME or Plasma; a KDE host may override to SDDM.

{ config, lib, pkgs, ... }:
let
  cfg   = config.my.desktop;
  anyDE = cfg.gnome.enable || cfg.kde.enable;
in {
  imports = [ ./gnome.nix ./kde.nix ];

  options.my.desktop.displayManager = lib.mkOption {
    type        = lib.types.enum [ "gdm" "sddm" ];
    default     = "gdm";
    description = ''
      Login manager for desktop hosts. DE-agnostic — GDM and SDDM can both launch
      GNOME or Plasma. Defaults to GDM (fleet standard, and the only DM the NixOS
      GNOME wiki supports for GNOME). Override per host (e.g. "sddm" for a native
      Plasma login).
    '';
  };

  config = lib.mkIf anyDE {
    services.xserver.enable     = true;
    services.xserver.xkb.layout = lib.mkDefault "us";

    # Login manager — exactly one of gdm|sddm, per the option above.
    services.displayManager.${cfg.displayManager}.enable = true;

    # Audio: PipeWire (replaces PulseAudio). DE-agnostic.
    services.pulseaudio.enable = false;
    security.rtkit.enable      = true;
    services.pipewire = {
      enable            = true;
      alsa.enable       = true;
      alsa.support32Bit = true;
      pulse.enable      = true;
    };

    # Sensible desktop defaults a host may drop (mkDefault).
    services.printing.enable = lib.mkDefault true;
    programs.firefox.enable  = lib.mkDefault true;
  };
}
