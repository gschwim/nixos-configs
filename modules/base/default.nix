{ pkgs, ... }:
let
  adminKeys = import ../../lib/admin-keys.nix;
in {
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  nixpkgs.config.allowUnfree = true;

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS        = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT    = "en_US.UTF-8";
    LC_MONETARY       = "en_US.UTF-8";
    LC_NAME           = "en_US.UTF-8";
    LC_NUMERIC        = "en_US.UTF-8";
    LC_PAPER          = "en_US.UTF-8";
    LC_TELEPHONE      = "en_US.UTF-8";
    LC_TIME           = "en_US.UTF-8";
  };

  users.users.schwim = {
    isNormalUser = true;
    description  = "Greg Schwimer";
    extraGroups  = [ "networkmanager" "wheel" "incus-admin" ];
    openssh.authorizedKeys.keys = adminKeys;
    # One-time login password. Expired immediately by the activation script
    # below, so PAM forces a change on first login (GDM, console, or SSH).
    initialPassword = "changeme";
    shell = pkgs.zsh;
  };

  # Force schwim to change the initial password on first login. `chage -d 0`
  # marks it as last-changed at epoch, which PAM treats as expired. Runs once;
  # the marker file prevents re-expiring after a successful change.
  system.activationScripts.expireSchwimInitialPassword = {
    deps = [ "users" ];
    text = ''
      if [ ! -e /var/lib/nixos-configs/schwim-initial-password-expired ]; then
        mkdir -p /var/lib/nixos-configs
        ${pkgs.shadow}/bin/chage -d 0 schwim || true
        touch /var/lib/nixos-configs/schwim-initial-password-expired
      fi
    '';
  };

  # Wheel group: passwordless sudo so schwim can administer over SSH-key auth
  # without juggling another password.
  security.sudo.wheelNeedsPassword = false;

  # Pre-stage schwim's working dir with the fleet's repos. Runs once per
  # host (marker file in $HOME/.cache); idempotent on rerun. Cloned via
  # HTTPS so it works without SSH keys being set up yet — user can
  # `git remote set-url` to ssh later if they want to push.
  systemd.services.schwim-staging = {
    description = "Pre-clone fleet repos into schwim's home";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    serviceConfig = {
      Type            = "oneshot";
      User            = "schwim";
      Group           = "users";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      SRC_DIR="$HOME/src"
      DONE_MARKER="$HOME/.cache/nixos-configs/staging-done"

      [ -e "$DONE_MARKER" ] && exit 0

      mkdir -p "$SRC_DIR" "$(dirname "$DONE_MARKER")"

      for repo in nix-home-manager nixos-configs; do
        [ -d "$SRC_DIR/$repo" ] && continue
        ${pkgs.git}/bin/git -C "$SRC_DIR" clone \
          "https://github.com/gschwim/$repo.git"
      done

      touch "$DONE_MARKER"
    '';
  };

  # First-login walk-through. Shown on every login until the user removes
  # /etc/motd or sets `users.motd = ""` in the host's nix file.
  users.motd = ''

    ── First-time setup ─────────────────────────────────────────────────
      1. zsh-newuser-install will prompt: press [2] to accept the
         recommended default ~/.zshrc (home-manager will overwrite it
         in step 2 anyway, so the exact choice doesn't matter — just
         pick something so zsh stops asking).

      2. Stage your home environment:
           cd ~/src/nix-home-manager && home-manager switch

    Repos pre-cloned in ~/src/ via HTTPS. To push, switch the remote:
      git -C ~/src/<repo> remote set-url origin git@github.com:gschwim/<repo>.git
    ─────────────────────────────────────────────────────────────────────

  '';

  environment.systemPackages = with pkgs; [
    neovim
    btop
    tcpdump
    wget
    tmux
    git
    lsof
    tlrc
    dust
    fd
    curl
    difftastic
    # standalone home-manager CLI for per-user dotfile management
    # (the NixOS-module variant is wired up in modules/home-manager.nix
    # but defaults off — users own their own HM, not the system flake).
    home-manager
  ];

  programs.neovim = {
    enable        = true;
    defaultEditor = true;
    viAlias       = true;
    vimAlias      = true;
  };

  programs.zsh = {
    enable        = true;
  };
}
