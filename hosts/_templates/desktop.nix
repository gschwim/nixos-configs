{ config, inputs, ... }:
{
  imports = [
    # Hardware module from nixos-hardware, if applicable. Examples:
    #   inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p1
    #   inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    # Run `nix eval --json --apply 'm: builtins.attrNames m' \
    #      github:NixOS/nixos-hardware#nixosModules | jq` to discover.
    ./hardware-configuration.nix
  ];

  networking.hostName = "@HOSTNAME@";
  networking.hostId   = "@HOSTID@";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  my.disko = {
    enable   = true;
    disk     = "/dev/nvme0n1";               # confirm before install
    swapSize = "8G";
  };

  my.network.static = {
    enable       = true;
    interface    = "wlp82s0";                # confirm at install
    address      = "172.16.1.NNN";           # set real address
    prefixLength = 24;
    gateway      = "172.16.1.254";
    nameservers  = [ "172.16.1.253" "8.8.8.8" ];
  };

  # Uncomment + populate when wifi secret is encrypted for this host:
  # my.network.wireless = {
  #   enable      = true;
  #   interface   = "wlp82s0";
  #   secretsFile = config.age.secrets."wifi-secrets".path;
  #   networks = {
  #     "Canis Major".pskRaw = "ext:psk_canis_major";
  #   };
  # };
  # age.secrets."wifi-secrets".file = ../../secrets/wifi-secrets.age;

  # Default-on toggles (openssh, networking baseline, home-manager) need no entry.
  my.desktop.gnome.enable      = true;
  my.services.xrdp.enable      = true;
  # my.services.incus.enable     = true;     # uncomment if joining an incus cluster
  # my.power.preventSleep.enable = true;     # if laptop is acting as a server

  system.stateVersion = "25.11";
}
