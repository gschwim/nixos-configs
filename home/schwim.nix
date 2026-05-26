# PLACEHOLDER — not normally consumed.
#
# This file is only imported when `my.home-manager.enable = true` on a host
# (see modules/home-manager.nix). The fleet default is OFF: users manage
# their own dotfiles via STANDALONE home-manager, run by the user themselves
# (`home-manager switch --flake <dotfiles-repo>#<attr>`). The CLI for that
# is installed system-wide in modules/base/default.nix.
#
# Leave this file in place as a starting point for any future appliance-style
# host (kiosk, single-purpose box) where the system flake should own user
# state and `nixos-rebuild switch` should apply both at once. To activate:
#   1. Set `my.home-manager.enable = true;` in that host's default.nix.
#   2. Add the actual HM config here (or refactor to import from elsewhere).
#
# Do NOT add real personal config here. Personal dotfiles belong in the
# user's standalone HM repo so they stay portable across Macs, non-NixOS
# Linuxes, etc.
{ ... }:
{
  home.username      = "schwim";
  home.homeDirectory = "/home/schwim";
  home.stateVersion  = "25.11";

  programs.home-manager.enable = true;
}
