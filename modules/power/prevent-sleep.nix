{ config, lib, ... }:
let
  cfg = config.my.power.preventSleep;
in {
  options.my.power.preventSleep = {
    enable = lib.mkEnableOption "disable sleep/suspend/hibernate (laptop-as-server)";
  };

  config = lib.mkIf cfg.enable {
    systemd.targets.sleep.enable        = false;
    systemd.targets.suspend.enable      = false;
    systemd.targets.hibernate.enable    = false;
    systemd.targets.hybrid-sleep.enable = false;
  };
}
