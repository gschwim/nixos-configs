{ config, inputs, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p1
    ./hardware-configuration.nix
  ];

  # embiggen the boot loader!
  boot.loader.systemd-boot.consoleMode = "2";

  networking.hostName = "pleiades";
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

  systemd.network.links."10-usb-ethernet" = {
    matchConfig.MACAddress = "00:50:b6:e5:48:99";    # paste from step 1
    linkConfig.Name        = "dong0";             # whatever you want to call it
  };


  my.network.static = {
  enable       = true;
  interface    = "dong0";                   # confirm at install
  address      = "172.16.1.249";           # placeholder — choose real value
  prefixLength = 24;
  gateway      = "172.16.1.254";
  nameservers  = [ "172.16.1.253" ];
  };

  # Tagged VLAN 2 trunk on dong0. The subif itself carries no IP — it's
  # enslaved by the incus 'vlan2' bridge (modules/services/incus.nix) as a
  # straight L2 pass-through to container veths.
  networking.vlans."dong0.2" = {
    id        = 2;
    interface = "dong0";
  };

  # The NM auto-exclusion in modules/networking/default.nix only fires for
  # ifaces with a declared ipv4.addresses; dong0.2 has none, so name it.
  my.networking.networkmanager.unmanaged = [ "interface-name:dong0.2" ];

  # Pin incus start order behind dong0.2-netdev. Without this, on cold boot
  # incus.service can win the race, create the vlan2 bridge with no enslaved
  # port, and never retry — leaving every container/VM on net-vlan2 with no
  # path to the upstream VLAN until someone restarts incus by hand.
  systemd.services.incus = {
    after = [ "dong0.2-netdev.service" ];
    wants = [ "dong0.2-netdev.service" ];
  };

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.desktop.gnome.enable      = true;
  my.services.xrdp.enable      = true;
  my.services.incus.enable     = true;       # flip off when laptop leaves the cluster
  # preventSleep is on by default via my.host.role = "server" above.

  system.stateVersion = "25.11";
}
