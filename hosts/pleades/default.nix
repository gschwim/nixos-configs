{ config, inputs, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p1
    ./hardware-configuration.nix
  ];

  # embiggen the boot loader!
  boot.loader.systemd-boot.consoleMode = "2";

  networking.hostName = "pleades";
  networking.hostId   = "a4cc034f";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  # Acting as a 24/7 server (incus host), even though the hardware is a
  # laptop. Drives preventSleep on by default and any future server defaults.
  my.host.role = "server";

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

  my.network.static = {
  enable       = true;
  interface    = "enp0s20f0u1";                   # confirm at install
  address      = "172.16.1.249";           # placeholder — choose real value
  prefixLength = 24;
  gateway      = "172.16.1.254";
  nameservers  = [ "172.16.1.253" ];
  };

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.desktop.gnome.enable      = true;
  my.services.xrdp.enable      = true;
  my.services.incus.enable     = true;       # flip off when laptop leaves the cluster
  # preventSleep is on by default via my.host.role = "server" above.

  system.stateVersion = "25.11";
}
