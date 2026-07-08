# Guest composition architecture

How NixOS guests on incus are built and differentiated. The operational runbook
(build/launch/networking/teardown) lives in [INCUS.md](../INCUS.md#nixos-guests-cattle);
this doc is the *model*.

## One model for the whole fleet: L0 + L1 + L2

Every host this repo produces — metal, named box, or anonymous guest — is the same
three layers:

- **L0 — base.** The shared substrate. For guests that's
  [guests/base.nix](../guests/base.nix): OS + Docker + tooling + admin SSH access
  (inherited from [modules/base](../modules/base/default.nix), so SSH and
  home-manager behave exactly as on the metal hosts).
- **L1 — overlays.** Small, declarative capability modules, one job each, composed
  onto the base. A **breed** = base + chosen overlays. Committed overlays live in
  [guests/workloads/](../guests/workloads/); machine-local one-offs in
  [guests/local/](../guests/local/).
- **L2 — instance params.** Per-instance data, never an image: hostname, config
  source, and incus profiles (`cpu-*`/`mem-*`/`storage-*`/`net-*`, defined in
  [modules/services/incus.nix](../modules/services/incus.nix)). Composed at launch.

## "Pet" vs "cattle" is a label, not an architecture

Both use L0+L1+L2. The only real difference is **where state lives** and whether you
gave the instance a **name/role**:

- **Anonymous (cattle):** rank-and-file, disposable, replaced without ceremony.
- **Named (pet):** you gave it a role ("the Hermes box"). Still built the same way.

What actually makes reconstitution work is that **durable state lives off-host**
(Dropbox / Drive / git) and the box merely consumes it. Rehydration after a rebuild
is currently a **manual** step — fine for a small fleet that rarely loses a host.
Automating it is a future TODO, not a requirement.

So a "pet" here is just a named breed instance whose off-host state you care about —
not a hand-crafted snowflake. The guardrail: **per-instance difference is data
(L2) or an overlay (L1), never a hand-edit on a running box.**

## Breeds (committed overlays)

Bounded by workload *types*, never by instances — N small git-tracked modules, each
reproducible. Add one:

```nix
# flake.nix nixosConfigurations
guest-hermes = mkGuest { extraModules = [ ./guests/workloads/hermes.nix ]; };
```

```bash
incus-guest build  --config guest-hermes         # → image alias nixos-guest-hermes
incus-guest launch h01 --alias nixos-guest-hermes
```

Overlays compose (the arg is a list), so you never need one monolithic image per
combination — see [guests/workloads/README.md](../guests/workloads/README.md).

## Local overlays (the `.zlocal` pattern)

For a one-off or an experiment you don't want to commit yet: drop a gitignored
module in [guests/local/](../guests/local/) and layer it at build time.

```bash
incus-guest build --extra-module ./guests/local/probe.nix --alias nixos-probe
incus-guest launch test01 --alias nixos-probe
```

Because the file is gitignored, the flake can't see it, so the build uses an impure
expr against the flake's `lib.mkGuest` (exposed in `flake.nix`) with the module as
an absolute path — zero git interaction, exactly like `.zshrc` sourcing `.zlocal`.

**Promotion** is one motion: a local overlay that proves out graduates to a shared
breed (and could later graduate again into `modules/` for any host, cattle or
named):

```bash
git mv guests/local/probe.nix guests/workloads/probe.nix
# + add a guest-probe attr to flake.nix, then:
incus-guest build --config guest-probe
```

## When it's genuinely a pet

If a box has irreplaceable **local** state you'd *recover* rather than rebuild, use
the metal path: a real [hosts/&lt;name&gt;/](../hosts/) entry with its own hostId/agenix,
installed via [scripts/install-host.sh](../scripts/install-host.sh). Reserve this
for the rare case where state can't be externalized — everything else stays a breed.

## Future directions (see TODO.md)

- Automate rehydration if the fleet grows.
- A `my.guest.<workload>.enable` toggle namespace if overlay composition gets rich.
- Decide composable-multi-overlay vs one-overlay-per-breed once there's >1 workload.
- Extend the local-overlay + promotion pattern to `hosts/` so metal/named/anonymous
  share one composition model.
