# Declarative NetworkManager wifi profiles, installed automatically on any
# host that turns on `my.networking.networkmanager.enable`. Per-host overrides
# (e.g. setting ipv4.method = "manual" + addresses for the home network) are
# done by adding to `networking.networkmanager.ensureProfiles.profiles.<id>`
# in the host's default.nix — NixOS module merging combines the leaves.
#
# Per-host requirement: the host's SSH host pubkey must be in the publicKeys
# list for secrets/wifi-secrets.age (see secrets/secrets.nix), or activation
# fails at decryption.
{ config, lib, ... }:
let
  nmOn = config.my.networking.enable && config.my.networking.networkmanager.enable;
in {
  config = lib.mkIf nmOn {
    age.secrets."wifi-secrets".file = ../../secrets/wifi-secrets.age;

    networking.networkmanager.ensureProfiles = {
      environmentFiles = [ config.age.secrets."wifi-secrets".path ];

      profiles."canis-major" = {
        connection = {
          id          = "Canis Major";
          type        = "wifi";
          autoconnect = "true";
        };
        wifi = {
          ssid = "Canis Major";
          mode = "infrastructure";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk      = "$psk_canis_major";
        };
        # Defaults: DHCP. Hosts override the ipv4/ipv6 sections to pin a
        # static IP, custom DNS, etc.
        ipv4.method = lib.mkDefault "auto";
        ipv6.method = lib.mkDefault "auto";
      };
    };
  };
}
