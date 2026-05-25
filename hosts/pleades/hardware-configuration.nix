# STUB — replace with output of `nixos-generate-config --no-filesystems --root /mnt`
# after running disko on the target hardware. Disko provides fileSystems & swapDevices,
# so the --no-filesystems variant is what you want.
{ lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
