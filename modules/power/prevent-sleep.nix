{ config, lib, ... }:
let
  cfg = config.my.power.preventSleep;
in {
  options.my.power.preventSleep = {
    enable = lib.mkOption {
      type    = lib.types.bool;
      default = config.my.host.role == "server";
      description = ''
        Disable sleep/suspend/hibernate end-to-end (systemd targets, logind
        events, and GNOME's idle-suspend pipeline). Defaults to true when
        `my.host.role = "server"`, false otherwise. Override per-host if
        needed (e.g. a desktop you want kept awake, or a server you
        deliberately want to suspend).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Mask systemd sleep targets — backstop in case something still tries.
    systemd.targets.sleep.enable        = false;
    systemd.targets.suspend.enable      = false;
    systemd.targets.hibernate.enable    = false;
    systemd.targets.hybrid-sleep.enable = false;

    # 2. Tell logind to ignore the events that would *initiate* a suspend.
    #    Without this, logind wall-broadcasts "The system will suspend now!"
    #    before the masked target fails — which is the noise you keep seeing.
    services.logind.settings.Login = {
      HandleLidSwitch              = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked        = "ignore";
      HandleSuspendKey             = "ignore";
      HandleHibernateKey           = "ignore";
      IdleAction                   = "ignore";
    };

    # 3. GNOME's settings-daemon power plugin has its own idle-suspend logic
    #    that routes through logind. Switch the actions to "nothing" + zero
    #    out the timeouts so it never requests a suspend in the first place.
    #    Only takes effect on hosts where the GNOME module is enabled.
    programs.dconf.profiles.user.databases =
      lib.optionals config.my.desktop.gnome.enable [{
        settings = with lib.gvariant; {
          "org/gnome/settings-daemon/plugins/power" = {
            sleep-inactive-ac-type         = "nothing";
            sleep-inactive-battery-type    = "nothing";
            sleep-inactive-ac-timeout      = mkInt32 0;
            sleep-inactive-battery-timeout = mkInt32 0;
            idle-dim                       = mkBoolean false;
          };
        };
      }];
  };
}
