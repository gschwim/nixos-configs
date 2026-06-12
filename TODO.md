# TODO

## Fleet management gaps

### deploy-rs push-from-workstation

Plan written at `.claude/plans/ok-next-on-the-sleepy-harbor.md`. Summary:
- Add `deploy-rs` flake input (follows nixpkgs)
- Add `deploy` output with iris + pleiades nodes, `remoteBuild = true` (avoids Mac→Linux cross-build); hostnames read from `my.network.static.address`
- Add `checks` output for schema validation; `devShells` for both darwin arches so `nix develop` gives the `deploy` CLI
- No host config changes needed — consumes existing `nixosConfigurations` as-is

Usage: `deploy .#iris`, `deploy .#pleiades`, `deploy .` (all). Auto-rollback on activation failure.

### Optional: `null` boot preseed for cluster-only members

Cluster members currently get the **full** standalone preseed (pool + networks +
profiles) so they're functional standalone and can be **joined to a cluster
after running standalone** — a required workflow. The cost: on join, the helper
must destructively wipe that standalone state (empty the ZFS pool, wipe
`/var/lib/incus`, kill leftover dnsmasq, `ip link delete` the leftover
incusbr0/prod/vlan2 bridges — see `cmd_join` in
[scripts/incus-cluster](scripts/incus-cluster)).

A node that will **only ever** be a cluster member (never standalone) could
instead get `virtualisation.incus.preseed = null`: it boots uninitialized, with
no standalone pool/bridges to wipe, so the join needs no destructive reset.

Decide whether to add a per-host opt-in (e.g.
`my.services.incus.cluster.standaloneCapable = false`) that switches a member to
the `null`-preseed path. **Not a default** — it sacrifices standalone use and
join-after-standalone, both of which we rely on. Keep the destructive reset path
as the supported general case regardless.

### Document every helper/command in one place

We've accumulated a pile of helper commands and scripts; their docs are
scattered (some inline in headers, some in [INCUS.md](INCUS.md), some nowhere).
Audit all of them and ensure each is documented in a central place (e.g. a
"Commands" section in [README.md](README.md) or a dedicated doc), with a
one-line purpose + usage and a link to source:

- `incus-launch` ([scripts/incus-launch.sh](scripts/incus-launch.sh)) — documented in INCUS.md.
- `incus-cluster` ([scripts/incus-cluster](scripts/incus-cluster)) — documented in INCUS.md.
- `nixctl` ([modules/system-info/nixctl.sh](modules/system-info/nixctl.sh)) — `info` / `switch` / `pull`.
- `installer-console` / `installer-dashboard` ([scripts/](scripts/)) — installer ISO console UX.
- `makeiso` ([scripts/makeiso.sh](scripts/makeiso.sh)) — build/flash the installer ISO.
- `gen-host-key`, `install-host`, `new-host`, `provision-user-key`, `trust-ssh-ca` ([scripts/](scripts/)).

### Incus preseed reconciliation

`virtualisation.incus.preseed` is one-shot — `incus admin init --preseed` initializes a fresh incus but does not reconcile against existing state. When the preseed in nix changes (e.g., a network or profile is added, removed, or modified) and `nixos-rebuild switch` is run, the *file* updates but the *live incus state* stays stale. Manual sync via `incus network edit` / `incus profile edit` / `incus network unset` is currently required after every relevant rebuild.

This is a known issue in the incus + NixOS community; the upstream `incus admin init` doesn't have a "force re-apply with reconcile" mode.

**Path forward** (deferred while we're still iterating; full rebuilds via [scripts/install-host.sh](scripts/install-host.sh) suffice for now):

- Write a reconciler in [scripts/](scripts/) that reads the rendered preseed YAML at `/etc/incus/preseed.yaml`, compares against live state via `incus network show` / `incus profile show`, and emits `incus network set/unset` + `incus profile edit` to bring live state into alignment. Default to `--dry-run`; require `--apply` to execute. Install via the same `writeShellApplication` machinery as `incus-launch` so it lands on every incus host.
- Optionally wire it as a `systemd.services.incus-reconcile` oneshot ordered `After=incus.service`, firing on every nixos-rebuild activation. Only enable once the script has been hand-run enough to be trusted.

---

# Pre-public-release cleanup

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

# Misc

## install-host.sh safety checks

The script should detect if it is installing against the installer or base image or a live system to be extra sure it doesn't clobber a running system in error. Allow --force to override.

##  install-host.sh 

