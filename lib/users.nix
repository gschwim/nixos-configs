# Catalog of the people (and bots) who can have accounts on fleet hosts, plus
# named sets of them. Hosts don't hand-list users; they pick sets via
# `my.users.sets` (and one-offs via `my.users.extra`) — see modules/users.nix.
#
# To add someone to the fleet: add an entry under `people`, then add the name
# to a set (or list it in a host's `my.users.extra`). To change who lands on
# which hosts, edit `sets` here — no host file needs touching.
#
# Each `people.<name>` value is passed straight through as users.users.<name>,
# so any NixOS user option works. PUBLIC keys only — no hashes, no passwords
# beyond schwim's existing one-time bootstrap password (expired on first login
# by modules/base). uids are left unpinned (allocated per host), matching how
# schwim has always been defined; pinning them would collide with the uids
# already allocated on existing hosts.
#
# Referenced by:
#   - modules/users.nix → creates users.users.<name> for the selected sets
{ pkgs }:
{
  people = {
    schwim = {
      isNormalUser = true;
      description  = "Greg Schwimer";
      extraGroups  = [ "networkmanager" "wheel" "incus-admin" ];
      # Single source of truth for schwim's keys; the installer ISO imports
      # the same file directly.
      openssh.authorizedKeys.keys = import ./admin-keys.nix;
      # One-time login password. Expired immediately by the activation script
      # in modules/base, so PAM forces a change on first login (GDM, console,
      # or SSH).
      initialPassword = "changeme";
      shell = pkgs.zsh;
    };

    # Grok Bot agents. Key-only SSH, normal users, no wheel/sudo — mirrors the
    # per-bot accounts on grokhq01 (grokhq01-bots.nix: "normal users, no
    # wheel/sudo"). Private keys never live in this repo; only the pubkeys
    # the bots log in with. Grant more on a specific host in its own
    # hosts/<name>/default.nix if ever needed.
    finn = {
      isNormalUser = true;
      description  = "Finn (Grok Bot admin)";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBMz2qbHIFb71rdfNSez8tECV0WJurCh0V+ere1DULJR finn@grokbot"
      ];
    };

    it = {
      isNormalUser = true;
      description  = "Bot it";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIxtMFYt5OoDVa4jmac7hwWP5L8CRv0mHaj5Jgr+95y2 it@grokhq01"
      ];
    };

    ferb = {
      isNormalUser = true;
      description  = "Bot ferb";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL65uoY3G3+NiD93s+4ySbgzzfmesoV78Mel9Cx9Uifi ferb@grokhq01"
      ];
    };
  };

  sets = {
    admins = [ "schwim" ];
    bots   = [ "finn" "it" "ferb" ];
  };
}
