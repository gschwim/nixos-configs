inputs: { hostName, system }:
inputs.nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = { inherit inputs hostName; };
  modules = [
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    inputs.agenix.nixosModules.default
    ../modules
    ../hosts/${hostName}
  ];
}
