{ ... }:
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "@HOSTNAME@";
  networking.hostId   = "@HOSTID@";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  my.host.role = "server";

  my.disko = {
    enable   = true;
    # MUST EDIT before install. Default is intentionally invalid so disko
    # fails-fast instead of wiping whichever real device happens to be at
    # /dev/sda on the target — that path could be the installer USB itself.
    # Set to the actual install disk (e.g. /dev/nvme0n1, /dev/vda).
    disk     = "/dev/????";
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
