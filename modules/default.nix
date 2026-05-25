{
  imports = [
    ./base
    ./boot/zfs.nix
    ./disko
    ./networking
    ./networking/static.nix
    ./networking/wireless.nix
    ./desktop/gnome.nix
    ./services/openssh.nix
    ./services/xrdp.nix
    ./services/incus.nix
    ./power/prevent-sleep.nix
    ./secrets.nix
    ./home-manager.nix
  ];
}
