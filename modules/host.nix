# Host-level metadata, used to drive sensible defaults across other modules
# without each host having to opt in to every individual switch.
#
# Currently wired up:
#   - modules/power/prevent-sleep.nix
#       my.power.preventSleep.enable defaults to (role == "server")
#   - my.host.management (this file's config block)
#       declares the host as a "management host," wires agenix decryption
#       and placement of each user's CA-signed keypair + cert.
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
  hostName = config.networking.hostName;

  # Per-user file paths in the repo. The .age priv-key file is required for
  # the build to succeed — eval will fail with a clear "path does not exist"
  # if a user is in mgmt.users but hasn't been provisioned yet via
  # scripts/provision-user-key.sh.
  slot = u: "${hostName}_${u}_id_ed25519";
  ageFile = u: ../secrets/users + "/${slot u}.age";
  pubFile = u: ../lib/users + "/${slot u}.pub";
  certFile = u: ../lib/users + "/${slot u}-cert.pub";
in {
  options.my.host = {
    role = lib.mkOption {
      type    = lib.types.enum [ "server" "desktop" ];
      default = "desktop";
      description = ''
        Describes how this host is USED, not its hardware. Drives behavioral
        defaults in other modules (currently: power/sleep behavior; will expand).

        Capabilities (services like incus, and the desktop environment) are
        deliberately NOT gated by role today — server and desktop share one base,
        and any host can enable any capability. Role only stages behavioral
        defaults. We keep the option open to add role-conditional behavior later
        (server-only / desktop-only) as a deliberate choice, not a rule.

          - "server":  headless / always-on. Sleep/suspend disabled by default.
                       A laptop kept on as a fileserver is `role = "server"`.
          - "desktop": interactive workstation. Normal sleep/idle behavior.

        Individual knobs always override the role default — e.g. a desktop
        host that still shouldn't sleep can set
        `my.power.preventSleep.enable = true;` explicitly.
      '';
    };

    management = {
      enable = lib.mkEnableOption "management host (deploys a CA-signed user keypair to listed users)";

      users = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [ "schwim" ];
        description = ''
          Users on this host that should have a CA-signed SSH keypair
          deployed to their ~/.ssh/. Each user must already exist on the
          host (this module doesn't create them).

          For each listed user, three artifacts must exist in the repo —
          produced by scripts/provision-user-key.sh:

            secrets/users/<host>_<user>_id_ed25519.age      encrypted priv
                                                            (recipient = the
                                                            host's SSH host key)
            lib/users/<host>_<user>_id_ed25519.pub          pubkey
            lib/users/<host>_<user>_id_ed25519-cert.pub     signed cert

          Missing artifacts cause nix flake check to fail with a "path does
          not exist" error pointing at the missing file — the user fixes
          by running scripts/provision-user-key.sh <host> <user>.

          On the host, on every nixos-rebuild:
            - agenix decrypts the .age file and places id_ed25519 at the
              right path (mode 600, owned by <user>).
            - tmpfiles places id_ed25519.pub and id_ed25519-cert.pub next
              to it (mode 644, owned by <user>).
            - The user can immediately SSH out — receiving hosts trust the
              User CA via my.services.openssh.trustUserCA.
        '';
      };
    };
  };

  config = lib.mkIf mgmt.enable {
    # ~/.ssh perms. The 'd' rule ensures the directory exists at 0700
    # owned by the user, and is also evaluated against an existing dir —
    # so if anything's wrong it gets corrected. (Z would recursively chown
    # contents too, but agenix already owns the priv it lays down and
    # tmpfiles handles the pub/cert below.)
    systemd.tmpfiles.rules = lib.concatMap (u: [
      "d /home/${u}/.ssh 0700 ${u} users -"
      # Force-copy pub + cert from /etc/ssh/users/ into the user's ~/.ssh/.
      # 'C+' = force copy (overwrite if exists); files end up real, not
      # symlinks (some SSH clients like real files better in $HOME).
      "C+ /home/${u}/.ssh/id_ed25519.pub 0644 ${u} users - /etc/ssh/users/${slot u}.pub"
      "C+ /home/${u}/.ssh/id_ed25519-cert.pub 0644 ${u} users - /etc/ssh/users/${slot u}-cert.pub"
    ]) mgmt.users;

    # Stage the pub + cert (public artifacts) at /etc/ssh/users/. The
    # tmpfiles rules above copy them from here into each user's ~/.ssh/.
    environment.etc = lib.listToAttrs (lib.concatMap (u: [
      { name = "ssh/users/${slot u}.pub";       value.source = pubFile u; }
      { name = "ssh/users/${slot u}-cert.pub";  value.source = certFile u; }
    ]) mgmt.users);

    # agenix decrypts the priv key on every activation. `path` puts the
    # decrypted file directly at /home/<u>/.ssh/id_ed25519 (as a symlink
    # to /run/agenix/<name>, which is fine — sshd/ssh follow symlinks).
    age.secrets = lib.listToAttrs (map (u: {
      name = "user-key-${hostName}-${u}";
      value = {
        file  = ageFile u;
        path  = "/home/${u}/.ssh/id_ed25519";
        owner = u;
        group = "users";
        mode  = "0600";
      };
    }) mgmt.users);
  };
}
