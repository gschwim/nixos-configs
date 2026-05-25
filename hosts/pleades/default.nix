{ config, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "pleades";
  networking.hostId   = "deadbeef";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  my.disko = {
    enable   = true;
    disk     = "/dev/nvme0n1";               # confirm before running disko
    swapSize = "8G";
  };

  my.network.static = {
    enable       = true;
    interface    = "wlp82s0";
    address      = "172.16.1.155";
    prefixLength = 24;
    gateway      = "172.16.1.254";
    nameservers  = [ "172.16.1.253" "8.8.8.8" ];
  };

  my.network.wireless = {
    enable      = true;
    interface   = "wlp82s0";
    secretsFile = config.age.secrets."wifi-secrets".path;
    networks = {
      "Canis Major".pskRaw = "ext:psk_canis_major";
    };
  };

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.desktop.gnome.enable      = true;
  my.services.xrdp.enable      = true;
  my.services.incus.enable     = true;       # flip off when laptop leaves the cluster
  my.power.preventSleep.enable = true;

  age.secrets."wifi-secrets".file = ../../secrets/wifi-secrets.age;

  system.stateVersion = "25.11";
}
