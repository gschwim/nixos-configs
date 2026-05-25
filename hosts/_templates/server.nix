{ ... }:
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "@HOSTNAME@";
  networking.hostId   = "@HOSTID@";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  my.disko = {
    enable   = true;
    disk     = "/dev/sda";                   # confirm at install
    swapSize = "4G";
  };

  my.network.static = {
    enable       = true;
    interface    = "eno1";                   # confirm at install
    address      = "172.16.1.NNN";           # set real address
    prefixLength = 24;
    gateway      = "172.16.1.254";
    nameservers  = [ "172.16.1.253" "8.8.8.8" ];
  };

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  # Common server toggles:
  # my.services.incus.enable = true;

  system.stateVersion = "25.11";
}
