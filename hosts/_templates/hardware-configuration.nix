# STUB — replaced by nixos-anywhere (or nixos-generate-config --no-filesystems
# during a manual install) once the host hardware exists.
{ lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
