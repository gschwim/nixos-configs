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

  environment.systemPackages = with pkgs; [
    neovim
    btop
    tcpdump
    wget
    tmux
    git
    lsof
  ];

  programs.neovim = {
    enable        = true;
    defaultEditor = true;
    viAlias       = true;
    vimAlias      = true;
  };
}
