{ ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;

  services.zfs = {
    autoScrub.enable    = true;
    autoSnapshot.enable = true;
    trim.enable         = true;
  };
}
