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
{
  options.my.host.role = lib.mkOption {
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
}
