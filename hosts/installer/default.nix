# Custom NixOS installer ISO.
#
# Build:    nix build .#nixosConfigurations.installer.config.system.build.isoImage
# Output:   result/iso/nixos-*-x86_64-linux.iso
# Flash:    sudo dd if=result/iso/nixos-*.iso of=/dev/rdiskN bs=4m status=progress
# VM use:   attach the ISO as a CD/DVD device, boot from it.
#
# What this ISO does differently from the stock minimal installer:
# - Console output goes to BOTH tty1 (VGA) and ttyS0 (serial) so it works in
#   VMs and headless boxes without a display.
# - sshd is enabled with key-only auth; schwim's pubkey from blushda is
#   embedded — `ssh schwim@<ip>` from blushda works immediately.
# - schwim has passwordless sudo (installer is ephemeral, SSH-key-protected).
# - Bundles git, vim, htop, nix-output-monitor, cryptsetup for live use.
# - Disables our home-manager baseline (no persistent /home on a live ISO).

{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # Identity. hostId is required for ZFS to load (disko needs it during
  # installs). Any 8-hex value works — the installer never imports existing
  # pools; install-host.sh sets the *target* hostid before creating any pool.
  networking.hostName = "nixos-installer";
  networking.hostId   = "00bada55";

  # Mirror console output to both VGA and serial. The last `console=` is the
  # one systemd uses as the controlling terminal — serial wins, which is
  # what we want for headless VMs.
  boot.kernelParams = [ "console=tty1" "console=ttyS0,115200n8" ];

  # SSH: key-only, no root login.
  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = lib.mkForce false;
    PermitRootLogin        = lib.mkForce "no";
    KbdInteractiveAuthentication = lib.mkForce false;
  };

  # Authorize blushda's ed25519 key for the schwim user (defined in
  # modules/base/default.nix). The installation-cd module marks the wheel
  # group as passwordless-sudo by default; we ensure that's on.
  users.users.schwim.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILi2IaOSC8y928fh5BqIYnGTqqngr/W5URgRTnfOD5YA schwim@blushda.local"
  ];
  security.sudo.wheelNeedsPassword = false;

  # Turn off our fleet baselines that conflict with installer defaults:
  # - home-manager assumes a real /home (live ISO has tmpfs)
  # - networking baseline disables NetworkManager; the installer wants it on
  my.home-manager.enable = false;
  my.networking.enable   = false;

  # Extra live-environment tools beyond what minimal already includes.
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    nix-output-monitor
    cryptsetup
  ];

  # The installation-cd module sets stateVersion via the installer base; do
  # not override.
}
