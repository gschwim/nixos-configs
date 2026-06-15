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
  my.host.management.enable = true;          # pleiades runs the fleet incus cluster

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
  bridge       = "users1";                  # mgmt IP lives on the users1 bridge;
                                            # dong0's native VLAN is shared with
                                            # incus instances (attach to users1).
  address      = "172.16.1.249";           # placeholder — choose real value
  prefixLength = 24;
  gateway      = "172.16.1.254";
  nameservers  = [ "172.16.1.253" ];
  };

  # Tagged VLAN trunks on dong0. Each subif carries no IP — it's enslaved by an
  # incus L2-passthrough bridge (modules/services/incus.nix): dong0.100 →
  # infra100, dong0.104 → cloud104.
  networking.vlans."dong0.100" = {
    id        = 100;
    interface = "dong0";
  };
  networking.vlans."dong0.104" = {
    id        = 104;
    interface = "dong0";
  };

  # The NM auto-exclusion in modules/networking/default.nix only fires for
  # ifaces with a declared ipv4.addresses. The VLAN subifs have none; and dong0
  # itself is now a bare bridge port (its IP moved to the users1 bridge), so NM
  # would otherwise try to manage it. Name them all. (users1 holds the IP, so
  # it's auto-excluded.)
  my.networking.networkmanager.unmanaged = [
    "interface-name:dong0"
    "interface-name:dong0.100"
    "interface-name:dong0.104"
  ];

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.desktop.gnome.enable      = true;
  my.services.xrdp.enable      = true;
  my.services.incus.enable     = true;       # flip off when laptop leaves the cluster
  my.services.incus.cluster.enable = false; # turning off until we need it
  # This host's VLAN trunks. The incus module enslaves each into its bridge and
  # pins incus to start after the respective <iface>-netdev (cold-boot race fix).
  my.services.incus.infra100Trunk = "dong0.100";
  my.services.incus.cloud104Trunk = "dong0.104";
  # preventSleep is on by default via my.host.role = "server" above.

  system.stateVersion = "25.11";
}
