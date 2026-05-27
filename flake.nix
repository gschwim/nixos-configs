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
  };

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      mkHost = import ./lib/mkHost.nix inputs;
    in {
      nixosConfigurations = {
        pleiades   = mkHost { hostName = "pleiades";   system = "x86_64-linux"; };
        iris      = mkHost { hostName = "iris";      system = "x86_64-linux"; };
        installer = mkHost { hostName = "installer"; system = "x86_64-linux"; };
      };
    };
}
