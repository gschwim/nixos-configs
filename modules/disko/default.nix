{ config, lib, ... }:
let
  cfg = config.my.disko;
in {
  options.my.disko = {
    enable = lib.mkEnableOption "default single-disk ZFS layout (ESP + swap + rpool)";

    disk = lib.mkOption {
      type        = lib.types.str;
      default     = "/dev/sda";
      description = "Block device to partition.";
    };

    espSize = lib.mkOption {
      type        = lib.types.str;
      default     = "1G";
      description = "Size of the EFI system partition.";
    };

    swapSize = lib.mkOption {
      type        = lib.types.str;
      default     = "2G";
      description = "Size of the swap partition.";
    };

    poolName = lib.mkOption {
      type        = lib.types.str;
      default     = "rpool";
      description = "Name of the root ZFS pool.";
    };
  };

  config = lib.mkIf cfg.enable {
    disko.devices = {
      disk.main = {
        type   = "disk";
        device = cfg.disk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = cfg.espSize;
              type = "EF00";
              content = {
                type         = "filesystem";
                format       = "vfat";
                mountpoint   = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size    = cfg.swapSize;
              content = { type = "swap"; discardPolicy = "both"; };
            };
            zfs = {
              size    = "100%";
              content = { type = "zfs"; pool = cfg.poolName; };
            };
          };
        };
      };

      zpool.${cfg.poolName} = {
        type    = "zpool";
        options = { ashift = "12"; autotrim = "on"; };
        rootFsOptions = {
          compression = "zstd";
          acltype     = "posixacl";
          xattr       = "sa";
          atime       = "off";
          mountpoint  = "none";
          canmount    = "off";
        };
        datasets = {
          "root"    = { type = "zfs_fs"; mountpoint = "/";        options.mountpoint = "legacy"; };
          "nix"     = { type = "zfs_fs"; mountpoint = "/nix";     options.mountpoint = "legacy"; };
          "var"     = { type = "zfs_fs"; mountpoint = "/var";     options.mountpoint = "legacy"; };
          "var/log" = { type = "zfs_fs"; mountpoint = "/var/log"; options.mountpoint = "legacy"; };
          "home"    = { type = "zfs_fs"; mountpoint = "/home";    options.mountpoint = "legacy"; };
          "incus"   = { type = "zfs_fs"; options = { mountpoint = "none"; canmount = "off"; }; };
        };
      };
    };
  };
}
