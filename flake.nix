{
  description = "schwim NixOS configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Source of nixos-anywhere's kexec-installer image; we build a custom
    # dual-console variant from its module (see packages.kexec-vga below).
    # We only consume its nixosModule (evaluated against our own nixpkgs), so
    # its nixos-stable/unstable inputs are left as-is (no `follows` to dedupe).
    nixos-images.url = "github:nix-community/nixos-images";

    # alyssadowdell.com site source (private). Served by web01 from the store
    # (guests/workloads/web01.nix). Fetched over SSH through the `github-allys`
    # host alias, which maps to github.com with the repo's own deploy key, so
    # it never touches the nixos-configs deploy key. Whoever evaluates web01
    # needs that alias in ~/.ssh/config (grokhq01 finn has it):
    #   Host github-allys
    #     HostName github.com
    #     User git
    #     IdentityFile ~/.ssh/allys_website_deploy   # KeePass has the key
    #     IdentitiesOnly yes
    # Update the site: `nix flake update allys-website`, commit flake.lock, deploy.
    allys-website = {
      url   = "git+ssh://git@github-allys/gschwim/allys-website";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, nixos-images, ... }:
    let
      mkHost  = import ./lib/mkHost.nix inputs;
      mkGuest = import ./lib/mkGuest.nix inputs;
    in {
      nixosConfigurations = {
        pleiades   = mkHost { hostName = "pleiades";   system = "x86_64-linux"; };
        iris      = mkHost { hostName = "iris";      system = "x86_64-linux"; };
        studio    = mkHost { hostName = "studio";    system = "x86_64-linux"; };
        installer = mkHost { hostName = "installer"; system = "x86_64-linux"; };

        # Cattle NixOS guest — the golden image for disposable incus Docker VMs.
        # Build + import + launch via `incus-guest` (scripts/incus-guest.sh).
        # Breeds (base + committed overlays from guests/workloads/) are added as
        # siblings here, e.g.:
        #   guest-hermes = mkGuest { extraModules = [ ./guests/workloads/hermes.nix ]; };
        guest      = mkGuest { system = "x86_64-linux"; };

        # web01 — nginx front end replacing fw02 (no Docker). See the overlay.
        web01      = mkGuest { system = "x86_64-linux"; extraModules = [ ./guests/workloads/web01.nix ]; };
      };

      # Exposed so `incus-guest build --extra-module <path>` can layer a
      # gitignored local overlay onto the base via an impure expr (a flake attr
      # can't see an untracked file). See docs/guests.md and scripts/incus-guest.sh.
      lib.mkGuest = mkGuest;

      # Dual-console kexec-installer image (serial ttyS0 + VGA tty0). The stock
      # nixos-images kexec image logs to serial only, so a kexec install that
      # hangs "goes dark" on a VGA-only box. This variant prints boot/panic
      # messages to both. Build on a LINUX host (blushda is darwin and can't
      # build x86_64-linux — same constraint as the installer ISO):
      #   nix build .#kexec-vga         # tarball lands in ./result
      # then point install-host.sh at it:
      #   scripts/install-host.sh <host> <ip> --force --kexec ./result
      packages.x86_64-linux.kexec-vga =
        (nixpkgs.lib.nixosSystem {
          system  = "x86_64-linux";
          modules = [
            nixos-images.nixosModules.kexec-installer
            { boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ]; }
          ];
        }).config.system.build.kexecInstallerTarball;
    };
}
