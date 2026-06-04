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

  # Pre-stage schwim's home on first boot:
  #  - default ~/.zshrc so zsh-newuser-install doesn't prompt interactively
  #    (home-manager intentionally overwrites this file on first `switch`)
  #  - fleet repos under ~/src (HTTPS clone; user can `git remote set-url`
  #    to ssh later if they want to push)
  #
  # Both checks are idempotent. The .zshrc check runs every boot (cheap
  # stat-check; only writes if missing). The clone is marker-gated so it
  # runs once per host's lifetime.
  systemd.services.schwim-staging = {
    description = "Pre-stage schwim's home: default .zshrc + fleet repos";
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

      # 1. Default .zshrc — matches what `zsh-newuser-install` option 2
      #    would create. With this in place the interactive prompt
      #    doesn't fire on first login.
      if [ ! -e "$HOME/.zshrc" ]; then
        cat > "$HOME/.zshrc" <<'ZSHRC'
# Lines configured by zsh-newuser-install
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000
bindkey -e
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '~/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall
ZSHRC
      fi

      # 2. Fleet repos. Marker-gated so we don't re-clone on every boot.
      SRC_DIR="$HOME/src"
      DONE_MARKER="$HOME/.cache/nixos-configs/staging-done"
      if [ ! -e "$DONE_MARKER" ]; then
        mkdir -p "$SRC_DIR" "$(dirname "$DONE_MARKER")"
        for repo in nix-home-manager nixos-configs; do
          [ -d "$SRC_DIR/$repo" ] && continue
          ${pkgs.git}/bin/git -C "$SRC_DIR" clone \
            "https://github.com/gschwim/$repo.git"
        done
        touch "$DONE_MARKER"
      fi
    '';
  };

  # First-login hint, self-clearing. Prints on login shells (not on every
  # subshell open) while the user hasn't yet run `home-manager switch` —
  # detected by the absence of the HM profile marker. Once HM has been
  # set up, the marker exists and the message stops appearing. No /etc/motd
  # to clean up manually.
  programs.zsh.loginShellInit = ''
    if [ "$USER" = "schwim" ] && [ ! -e "$HOME/.local/state/nix/profiles/home-manager" ]; then
      cat <<'MSG'

    ── First-time setup ─────────────────────────────────
      Stage your home environment:
        cd ~/src/nix-home-manager && home-manager switch

      Repos in ~/src are cloned via HTTPS. For SSH push:
        git -C ~/src/<repo> remote set-url origin \
          git@github.com:gschwim/<repo>.git
    ─────────────────────────────────────────────────────

    MSG
    fi
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
