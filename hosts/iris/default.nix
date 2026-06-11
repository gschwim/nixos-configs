{ ... }:
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "iris";
  networking.hostId   = "feedface";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  my.host.role = "server";
  my.host.management.enable = true;          # iris needs outbound SSH to other hosts

  my.disko = {
    enable   = true;
    disk     = "/dev/nvme0n1";                   # confirm at install
    swapSize = "4G";
  };

  my.network.static = {
    enable       = true;
    interface    = "enp3s0";                   # confirm at install
    address      = "172.16.1.248";           # placeholder — choose real value
    prefixLength = 24;
    gateway      = "172.16.1.254";
    nameservers  = [ "172.16.1.253" ];
  };

  networking.vlans."enp3s0.2" = {
    id = 2;
    interface = "enp3s0";
  };

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.services.incus.enable = true;
  # This host's VLAN 2 trunk. The incus module enslaves it into the vlan2
  # bridge and pins incus to start after enp3s0.2-netdev (cold-boot race fix).
  my.services.incus.vlan2Trunk = "enp3s0.2";

  system.stateVersion = "25.11";
}
