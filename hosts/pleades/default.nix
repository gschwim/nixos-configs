{ config, inputs, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p1
    ./hardware-configuration.nix
  ];

  # embiggen the boot loader!
  boot.loader.systemd-boot.consoleMode = "0";

  networking.hostName = "pleades";
  networking.hostId   = "a4cc034f";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  my.disko = {
    enable   = true;
    disk     = "/dev/nvme0n1";               # confirm before running disko
    swapSize = "8G";
  };

  # NetworkManager owns wifi + USB ethernet etc. on the laptop. The shared
  # Canis Major profile (modules/networking/wifi-profiles.nix) is DHCP-by-default
  # and auto-installed; we don't override it here.
  # To statically configure additional ifaces (e.g. a USB ethernet dongle),
  # set `networking.interfaces.<iface>.ipv4.addresses` — the networking module
  # auto-excludes that iface from NM. To leave it for NM to manage instead,
  # don't declare it here and configure via nmcli post-boot.
  my.networking.networkmanager.enable = true;

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.desktop.gnome.enable      = true;
  my.services.xrdp.enable      = true;
  my.services.incus.enable     = true;       # flip off when laptop leaves the cluster
  my.power.preventSleep.enable = true;

  system.stateVersion = "25.11";
}
