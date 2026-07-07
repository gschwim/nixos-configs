# Cattle NixOS guest — the golden image for disposable incus VMs running Docker
# workloads. Built once with `incus-guest build` and launched as many identical,
# throwaway copies as needed (`incus-guest launch <name>` / `incus-launch`).
#
# CATTLE, not pets: no per-guest hosts/<name>/ dir, no per-guest hostId (the root
# is ext4 on a virtio disk — no ZFS, so the ZFS-hostid gotcha doesn't apply), no
# per-guest agenix key or SSH-CA ceremony. One config, many instances; replace,
# don't babysit. Per-instance identity (hostname, network) is injected by incus
# at launch via cloud-init.
#
# The base VM plumbing (ext4 root, systemd-boot, the incus guest agent) comes
# from nixpkgs' virtualisation/incus-virtual-machine.nix, wired in by
# lib/mkGuest.nix. This file carries only the cattle-specific bits.

{ config, lib, pkgs, ... }:
{
  # schwim user + admin SSH keys (lib/admin-keys.nix) + fleet tooling, INCLUDING
  # the standalone home-manager CLI and the staged ~/.zshrc bootstrap. Importing
  # this is what makes SSH access and home-manager behave IDENTICALLY to the pets
  # (see the plan). Deliberately NOT importing ../modules/services/openssh.nix
  # (CA/agenix host-key machinery — pet-only) or setting my.home-manager.enable
  # (that would bind the home/schwim.nix placeholder and break HM parity).
  imports = [ ../modules/base ];

  # Docker workloads — the whole point of these guests.
  virtualisation.docker.enable = true;
  users.users.schwim.extraGroups = [ "docker" ];   # merges with base's list

  # Always-on, key-only sshd. Overrides the on-demand default from
  # nixpkgs' lxc-instance-common.nix; PasswordAuthentication off means the
  # admin keys from base are the only way in — same as the pets.
  services.openssh = {
    enable                          = true;
    startWhenNeeded                 = false;
    settings.PasswordAuthentication = false;
  };

  # Per-instance identity (hostname + network) injected by incus at launch.
  # cloud-init is the SINGLE network manager: it renders config to
  # systemd-networkd. When incus supplies no network-config (a plain NAT
  # launch) cloud-init falls back to DHCP on the primary NIC; when
  # incus-launch supplies a static network-config (the L2 path) cloud-init
  # applies that instead. Same MAC-pinned flow the Ubuntu guests use.
  services.cloud-init = {
    enable         = true;
    network.enable = true;
  };

  # networkd owns the interfaces (cloud-init writes networkd units). Disable
  # the legacy dhcpcd path so the two don't both manage the same NIC — the
  # "loss of networking" combo NixOS warns about.
  networking.useNetworkd = true;
  networking.useDHCP     = false;

  # (virtualisation.incus.agent.enable is already mkDefault true in nixpkgs'
  # incus-virtual-machine.nix — no need to set it here.)

  system.stateVersion = "25.11";
}
