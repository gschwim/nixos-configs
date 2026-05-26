{ config, lib, ... }:
let
  cfg = config.my.home-manager;
in {
  options.my.home-manager = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = ''
        Wire home-manager AS A NIXOS MODULE for the schwim user — applies HM
        config at `nixos-rebuild switch` time, owns ~/.config/, no separate
        `home-manager switch` command. Off across the fleet by default because
        users own their own dotfiles via standalone home-manager (the CLI is
        installed system-wide in modules/base/default.nix). Flip on only for
        appliance-style hosts where the system flake should be the single
        source of truth for user state.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home-manager.useGlobalPkgs   = true;
    home-manager.useUserPackages = true;
    home-manager.users.schwim    = import ../home/schwim.nix;
  };
}
