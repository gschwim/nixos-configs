# TODO: pre-public-release cleanup

The [README.md](README.md) uses generic placeholders (`<user>`, `<workstation>`, `<path-to-kdbx>`, etc.) so the doc itself doesn't expose identifying information. The code and scripts, however, still hardcode several identifiers. None of these break anything as-is — changing them might. Each entry below lists the locations and the risk of cleaning it up.

## `<user>` (system username)

The admin user is hardcoded throughout. Renaming requires coordinated edits and a rebuild on every host.

- [modules/base/default.nix:24](modules/base/default.nix) — `users.users.<user> = { ... };` definition.
- [home/<user>.nix](home/) — filename + `home.username` + `home.homeDirectory`.
- [modules/home-manager.nix:24](modules/home-manager.nix) — `home-manager.users.<user> = import ../home/<user>.nix;`.
- [hosts/installer/default.nix:53-54](hosts/installer/default.nix) — `users.users.<user>.openssh.authorizedKeys.keys` and `users.users.root.…`.
- [modules/services/incus.nix:80,84](modules/services/incus.nix) — hardcoded cloud-init user block + an authorized SSH key comment.
- [lib/admin-keys.nix:6-7](lib/admin-keys.nix) — SSH key comment fields (`<user>@<workstation>.local`, `<user>@pleiades`).
- [modules/services/openssh.nix:16](modules/services/openssh.nix) — comment referencing the admin user.

**Risk:** medium-to-high. Renaming the system user breaks every deployed host until it rebuilds. The custom installer ISO's trust chain assumes this username — re-build and re-flash before installing a new host with a renamed admin user. Doable but coordinated.

## `<workstation>` (Mac workstation hostname)

Used as a label for the age authoring identity in `secrets.nix` and in SSH key comments. Renaming is cosmetic — the actual key material is the secret, not the name.

- [secrets/secrets.nix:18,41,104,107,124](secrets/secrets.nix) — age identity name + recipient list references + comment text.
- [scripts/install-host.sh:2,159](scripts/install-host.sh) — comments referencing the workstation.
- [hosts/installer/default.nix:11-12,47-48](hosts/installer/default.nix) — comments describing what the installer ISO authorizes.
- [lib/admin-keys.nix:6](lib/admin-keys.nix) — SSH key comment.
- [modules/services/incus.nix:84](modules/services/incus.nix) — comment in the cloud-init authorized key.

**Risk:** low. Pure rename. Even the `secrets.nix` reference is a Nix variable name (any identifier works) — the key material it binds is the actual recipient.

## Real name and personal organization

Hard-coded "Greg Schwimer" and "7e7":

- [modules/base/default.nix:26](modules/base/default.nix) — `users.users.<user>.description = "Greg Schwimer";` (GECOS field).
- [scripts/gen-host-key.sh:27,39](scripts/gen-host-key.sh) — kdbx default path is `$HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx`, in both the comment and the `KDBX_FILE` default. The script accepts `KDBX_FILE` overrides, so this is just a default for convenience.
- [modules/services/incus.nix:84](modules/services/incus.nix) — `7e7` appears as part of an old SSH key comment string.

**Risk:** low. GECOS can be anything. The kdbx default can be changed to a generic path (e.g. `~/.local/share/nixos-configs/secrets.kdbx`) — anyone using the script then either symlinks the real kdbx into that path or sets `KDBX_FILE` in their shell.

## Wifi SSID (`Canis Major`)

- [modules/networking/wifi-profiles.nix:22,27](modules/networking/wifi-profiles.nix) — profile id + ssid for one specific wifi network.
- [hosts/_templates/desktop.nix:39](hosts/_templates/desktop.nix) — commented-out example.

**Risk:** medium. The wifi-profiles module is referenced by hosts that actually connect to this network — renaming requires updating the host configs that consume the profile. The template reference is example-only (commented out), safe to scrub immediately.

## `starting-configs/`

`grep -r starting-configs flake.nix lib/ modules/ hosts/ home/` returns no matches — these files are not imported by the flake. They look like archived pre-flake configurations.

- [starting-configs/configuration.nix](starting-configs/configuration.nix)
- [starting-configs/incus.nix](starting-configs/incus.nix)
- [starting-configs/configuration.nix.old](starting-configs/configuration.nix.old)

**Risk:** none. Safe to delete the entire directory.
