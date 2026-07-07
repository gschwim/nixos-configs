# Builder for cattle NixOS guests — the incus-VM analog of lib/mkHost.nix, but
# lean. Guests are disposable and identical, so this deliberately does NOT wire
# in disko (incus manages the qcow2 root), agenix (no per-guest secrets), or a
# per-host hosts/<name>/ dir. The whole config is guests/base.nix; per-instance
# identity is injected by incus at launch.
#
# nixpkgs' virtualisation/incus-virtual-machine.nix supplies the VM plumbing and
# the two build targets we import into incus:
#   config.system.build.metadata   → the image metadata tarball
#   config.system.build.qemuImage  → the qcow2 root disk
# See scripts/incus-guest.sh for the build+import+launch flow.

inputs: { system ? "x86_64-linux", extraModules ? [ ] }:
inputs.nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = { inherit inputs; };
  modules = [
    "${inputs.nixpkgs}/nixos/modules/virtualisation/incus-virtual-machine.nix"
    ../guests/base.nix
  ] ++ extraModules;
}
