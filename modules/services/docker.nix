{ config, lib, ... }:
let
  cfg = config.my.services.docker;
in {
  options.my.services.docker = {
    enable = lib.mkEnableOption "Docker engine (on by default for incus guests via guests/base.nix)";
    users = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [ "schwim" ];
      description = "Users added to the docker group.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;
    users.users = lib.genAttrs cfg.users (_: { extraGroups = [ "docker" ]; });
  };
}
