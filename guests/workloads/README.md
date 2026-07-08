# guests/workloads — committed guest overlays (L1)

Small, declarative NixOS modules, **one capability each** (a `systemd.services.*`,
a package, a `services.*`). They compose with `guests/base.nix` to form a **breed**
— a reproducible image you stamp out as many identical instances of.

Nothing incus-specific belongs here; these are ordinary NixOS modules.

## Adding a breed

1. Write the overlay, e.g. `guests/workloads/hermes.nix`.
2. Wire a flake attr in `flake.nix` `nixosConfigurations`:
   ```nix
   guest-hermes = mkGuest { extraModules = [ ./guests/workloads/hermes.nix ]; };
   ```
   Multiple overlays compose — the arg is a list:
   `mkGuest { extraModules = [ ./guests/workloads/a.nix ./guests/workloads/b.nix ]; }`.
3. Build + import: `incus-guest build --config guest-hermes` (alias `nixos-guest-hermes`).
4. Launch: `incus-guest launch h01 --alias nixos-guest-hermes`.

See `docs/guests.md` for the L0/L1/L2 model, and `guests/local/` for the
uncommitted one-off (`.zlocal`) pattern that promotes into this directory.
