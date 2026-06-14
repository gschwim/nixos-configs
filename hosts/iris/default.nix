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

  # Tagged VLAN trunks on enp3s0, each enslaved by an incus L2-passthrough
  # bridge: enp3s0.100 → infra100, enp3s0.104 → cloud104.
  networking.vlans."enp3s0.100" = {
    id = 100;
    interface = "enp3s0";
  };
  networking.vlans."enp3s0.104" = {
    id = 104;
    interface = "enp3s0";
  };

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.services.incus.enable = true;
  my.services.incus.cluster.enable = false; # we will enable clustering if/when needed
  # This host's VLAN trunks. The incus module enslaves each into its bridge and
  # pins incus to start after the respective <iface>-netdev (cold-boot race fix).
  my.services.incus.infra100Trunk = "enp3s0.100";
  my.services.incus.cloud104Trunk = "enp3s0.104";

  system.stateVersion = "25.11";
}
