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

  # Pre-stage a default ~/.zshrc for schwim. The file is a working zsh
  # config (matches zsh-newuser-install option 2) plus a first-login
  # bootstrap block that prompts the user whether to clone the fleet
  # repos into ~/src. Declining defers the prompt to the next login;
  # accepting clones and then prints the home-manager hint. After
  # `home-manager switch`, HM overwrites this file with its own config.
  #
  # systemd-tmpfiles `C` copies the source if /home/schwim/.zshrc doesn't
  # exist. It never replaces an existing file, so an HM-managed .zshrc
  # or anything the user wrote by hand is left alone.
  environment.etc."nixos-configs/schwim-zshrc.zsh".source = ./schwim-zshrc.zsh;
  systemd.tmpfiles.rules = [
    "C /home/schwim/.zshrc 0644 schwim users - /etc/nixos-configs/schwim-zshrc.zsh"
  ];

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
