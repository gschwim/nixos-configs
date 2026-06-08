# Host-level metadata, used to drive sensible defaults across other modules
# without each host having to opt in to every individual switch.
#
# Currently wired up:
#   - modules/power/prevent-sleep.nix
#       my.power.preventSleep.enable defaults to (role == "server")
#
# Future candidates (review when adding/changing a host or when one of these
# starts feeling tedious to set per-host):
#   - my.desktop.gnome.enable, my.services.xrdp.enable  → default to (role == "desktop")
#   - my.networking.networkmanager.enable               → default to (role == "desktop")
#   - powerManagement.cpuFreqGovernor                   → "performance" (server) vs
#                                                          "ondemand" / "powersave" (desktop)
#   - services.journald.extraConfig                     → longer retention on servers
#   - system.autoUpgrade.enable                         → on for servers, off for desktops
#   - services.thermald / tlp / power-profiles-daemon   → desktop/laptop-only
#   - networking.firewall defaults                      → tighter on servers
#
# Add new candidates here as they come up; promote to actual defaults when
# you find yourself setting the same value on every host of a given role.
{ config, lib, ... }:
let
  mgmt = config.my.host.management;
in {
  options.my.host = {
    role = lib.mkOption {
      type    = lib.types.enum [ "server" "desktop" ];
      default = "desktop";
      description = ''
        Describes how this host is USED, not its hardware. Drives defaults
        in other modules (currently: power/sleep behavior; will expand).

          - "server":  headless / always-on. Sleep/suspend disabled by default.
                       A laptop kept on as a fileserver is `role = "server"`.
          - "desktop": interactive workstation. Normal sleep/idle behavior.

        Individual knobs always override the role default — e.g. a desktop
        host that still shouldn't sleep can set
        `my.power.preventSleep.enable = true;` explicitly.
      '';
    };

    management = {
      enable = lib.mkEnableOption "management host (gets a CA-signed user keypair staged into ~/.ssh/)";

      users = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [ "schwim" ];
        description = ''
          Users on this host that should have id_ed25519, id_ed25519.pub,
          and id_ed25519-cert.pub staged into their ~/.ssh/. Each user
          must already exist on the host (this module doesn't create them).

          scripts/install-host.sh (fresh installs) and scripts/deploy-user-key.sh
          (running hosts) consult this list via `nix eval` to decide what
          to stage. NixOS-side, the only effect is ensuring /home/<u>/.ssh/
          exists with mode 0700 so install-staged files land in a
          properly-permissioned directory.

          The keypair + cert are NOT managed by NixOS at runtime — they're
          delivered once (at install or via deploy-user-key.sh) and then
          sit at /home/<u>/.ssh/. OpenSSH client auto-discovers *-cert.pub
          next to the key; receiving hosts trust the User CA via
          my.services.openssh.trustUserCA.
        '';
      };
    };
  };

  config = lib.mkIf mgmt.enable {
    # Two rules per user:
    #   d — create /home/<u>/.ssh at 0700 owned by <u>:users if it doesn't
    #       exist; if it does (because install-host.sh's --extra-files
    #       staged files into it before user activation), adjust owner+mode.
    #   Z — recursively chown the contents (the staged keys arrive as
    #       root:root from --extra-files). Mode '-' = leave file modes
    #       alone, preserving the 600 that install-host.sh set on the
    #       private key.
    systemd.tmpfiles.rules = lib.concatMap (u: [
      "d /home/${u}/.ssh 0700 ${u} users -"
      "Z /home/${u}/.ssh - ${u} users -"
    ]) mgmt.users;
  };
}
