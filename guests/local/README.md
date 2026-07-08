# guests/local — machine-local guest overlays (the `.zlocal` pattern)

Throwaway, **gitignored** NixOS modules for one-off guest experiments. Drop a
`something.nix` here and layer it onto the base guest at build time — no commit,
no flake attr:

```bash
incus-guest build --extra-module ./guests/local/something.nix --alias nixos-something
incus-guest launch test01 --alias nixos-something
```

Because the file is gitignored (invisible to the flake), the build uses an impure
expr against the flake's `lib.mkGuest` (see `scripts/incus-guest.sh`). Everything
under this directory except this README and `.gitkeep` is ignored.

## Promotion

When a local overlay proves out, promote it to a committed, shareable breed:

```bash
git mv guests/local/something.nix guests/workloads/something.nix
# add to flake.nix nixosConfigurations:
#   guest-something = mkGuest { extraModules = [ ./guests/workloads/something.nix ]; };
incus-guest build --config guest-something
```

See `docs/guests.md` for the full model.
