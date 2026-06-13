# Incus operations on pleiades

Quick reference for launching instances on the incus host. The source of truth for all networks and profiles is [modules/services/incus.nix](modules/services/incus.nix).

## Networks

| Name | Type | Subnet | DHCP | NAT | Notes |
| --- | --- | --- | --- | --- | --- |
| `incusbr0` | NAT bridge | auto | yes | yes | Default isolated network. Containers reach the internet via SNAT; no inbound. |
| `prod` | Routed bridge | 172.16.4.0/24 | yes (dynamic .100-.200) | no | DHCP pool, gateway `.254`. |
| `vlan2` | L2 bridge over `dong0.2` | 172.16.0.0/24 | none (set via cloud-init) | no | Pure pass-through. No IP on the bridge, no dnsmasq. Instances reach the upstream VLAN 2 gateway (172.16.0.254) directly. |

## Profile menu

Compose multiple profiles on launch — later profiles override same-named devices in earlier ones.

| Category | Profile | Effect |
| --- | --- | --- |
| Bootstrap | `default` | Root disk on `default` pool + `eth0` on `incusbr0`. |
| | `basebuild01` | Standalone starter: same root + eth0 as `default`, plus cloud-init (apt update/upgrade, openssh-server + neovim + zsh, sudo user with SSH key). Apply alone — no need to also apply `default`. |
| Network | `net-incusbr0` | `eth0` on `incusbr0` (NAT). |
| | `net-prod` | `eth0` on `prod` (routed 172.16.4.0/24). |
| | _(none for `vlan2`)_ | L2-passthrough networks have no profile — use `incus-launch` instead. |
| Storage | `storage-10GB` / `40GB` / `80GB` / `100GB` | Sized root disk on `default` pool. |
| | `disk-default` | Root disk on `default` pool, unsized. |
| CPU | `cpu-1` / `cpu-4` / `cpu-8` | `limits.cpu` =N. |
| Memory | `mem-1GB` / `mem-2GB` / `mem-4GB` / `mem-8GB` / `mem-16GB` | `limits.memory` =N. |

## Deploy on `vlan2` with a static IP

`vlan2` is a pure L2 pass-through — no DHCP on the bridge. Each instance needs its IP/gateway/DNS injected via cloud-init at launch. The `incus-launch` command (installed system-wide on any host with `my.services.incus.enable = true`; source at [scripts/incus-launch.sh](scripts/incus-launch.sh)) does this in one shot.

```
incus-launch <name> <image> [--vm] <net>:<ip>[/<prefix>] [<net>:<ip>...] [-- <extra incus flags>]
```

Use a cloud-init-capable image — `ubuntu:<release>` (official Ubuntu remote) is the easy choice; the minimal `images:ubuntu/<release>` variants do not ship cloud-init.

Pick an unused address in 172.16.0.0/24 (avoid the gateway `.254` and anything in `incus list`).

### Container

```bash
incus-launch web01 ubuntu:26.04 vlan2:172.16.0.50 \
  -- -p basebuild01 -p storage-40GB -p mem-4GB
```

### VM

```bash
incus-launch web02 ubuntu:26.04 --vm vlan2:172.16.0.50 \
  -- -p basebuild01 -p storage-40GB -p cpu-4 -p mem-4GB
```

### Two NICs (e.g., vlan2 + vlan3)

```bash
incus-launch web03 ubuntu:26.04 --vm vlan2:172.16.0.50 vlan3:10.0.3.50 \
  -- -p basebuild01 -p storage-40GB -p mem-4GB
```

`basebuild01` is the recommended starter — it provides the root disk, cloud-init for the admin user, *and* an `eth0` on `incusbr0` that `incus-launch` overrides to your chosen network. You don't need to also apply `-p default`.

The script auto-generates a stable MAC per `(instance-name, network-name)` pair and writes a netplan that matches on MAC, so the same instance name always gets the same MACs (upstream ARP caches stay valid across re-launches) and multi-NIC matching can't get confused by kernel naming.

### Adding a new L2-passthrough network

1. Define the incus network in [modules/services/incus.nix](modules/services/incus.nix) (mirror the `vlan2` shape: `bridge.external_interfaces = "<trunk>"`, `ipv4.address = "none"`).
2. Add a row to the `NET_GW`/`NET_DNS`/`NET_PREFIX` tables at the top of [scripts/incus-launch.sh](scripts/incus-launch.sh).
3. `nixos-rebuild switch` on each host that runs incus. Plan for a reboot ([see the network-changes-need-a-reboot pattern](#troubleshooting)).

## Verify it worked

```bash
incus list web01                                      # state Running, IPv4 = 172.16.0.50
incus exec web01 -- ip -4 addr                        # 172.16.0.50/24 on eth0 (container) or enpXsY (VM)
incus exec web01 -- ip route                          # default via 172.16.0.254
incus exec web01 -- resolvectl dns                    # 172.16.1.253 (or check /etc/resolv.conf)
incus exec web01 -- ping -c 2 172.16.0.254            # reach the upstream gateway
```

If `incus list` shows the instance Running but with no IPv4, see Troubleshooting below.

> **VMs vs containers and interface names.** Containers see the NIC as `eth0` (incus presents the veth's container side with that name). VMs see it as whatever their kernel's predictable naming yields — typically `enp5s0` or `ens3`. `incus-launch` sidesteps this entirely by matching on the MAC it generated, not the interface name. Don't reach inside the VM and assume `eth0`.

## Change the IP later

The MAC the script generates is keyed on `(instance-name, network-name)`, so re-launching the same instance name gets the same MAC. Easiest path is to delete and re-launch with the new IP:

```bash
incus delete --force web01
incus-launch web01 ubuntu:26.04 vlan2:172.16.0.51 -- -p default -p storage-40GB
```

In-place change without rebuild (preserves instance state):

```bash
# Render the netplan you want, then:
incus config set web01 cloud-init.network-config="version: 2
ethernets:
  net0:
    match: { macaddress: \"<mac>\" }      # same MAC as currently configured
    addresses: [172.16.0.51/24]
    gateway4: 172.16.0.254
    nameservers: { addresses: [172.16.1.253] }
"
incus exec web01 -- cloud-init clean --logs
incus exec web01 -- cloud-init init
incus exec web01 -- netplan apply
```

(Get the existing MAC from `incus config show web01 --expanded | grep hwaddr`.)

## Other lifecycle operations

```bash
incus list                              # all instances
incus start  web01
incus stop   web01
incus restart web01
incus exec   web01 -- bash              # shell inside (containers)
incus console web01                     # serial console (VMs)
incus delete --force web01              # tear down; --force skips the running check
incus snapshot create web01 pre-upgrade
incus snapshot restore web01 pre-upgrade
```

## Clustering (`orion-1`)

Cluster membership is defined in **one place** — [lib/incus-clusters.nix](lib/incus-clusters.nix):

```nix
{
  orion-1 = { seed = "iris"; members = [ "iris" "pleiades" ]; };
}
```

The incus module derives each host's role from this map: the **seed** (`iris`)
defines the cluster-wide pools/networks/profiles and bootstraps the cluster; a
**member** (`pleiades`) inherits that config when it joins. Each node's cluster
address is read from its own `my.network.static.address` (no duplicated IPs).
The resolved topology is written to `/etc/incus-cluster.json` and surfaced by the
`incus-cluster` helper ([scripts/incus-cluster](scripts/incus-cluster)).

**Pull a node out:** `my.services.incus.cluster.enable = false;` in its
`hosts/<host>/default.nix` (reverts to a standalone daemon on `:8443`); or
`incus-cluster leave` to remove a live member.

### Why a helper instead of pure preseed

Incus join tokens are **single-use and expire (~3h)**, the trust-password was
removed, and the NixOS preseed is **one-shot** (first init only). So the join
step is inherently imperative. The helper keeps it driven from the central
topology — it mints a fresh token on the seed over SSH at join time, so there
are no token secrets to commit or rotate.

### Bring up the cluster

```bash
# On the seed (iris) — non-destructive, keeps existing data:
sudo incus-cluster enable
incus-cluster status                 # topology + `incus cluster list`

# On a member (pleiades) — ONE-TIME, DESTRUCTIVE (wipes local incus):
sudo incus-cluster join              # SSHes the seed for a token, resets, joins
```

`incus-cluster token <member>` mints a token by hand if you want to join a node
manually. The full per-member `member_config` Incus requires — storage-pool
`source` **and** `zfs.pool_name`, plus the `vlan2` `bridge.external_interfaces`
trunk — is supplied automatically at join, from the descriptor. The join also
resets local Incus to a clean slate first (empties the ZFS pool, wipes
`/var/lib/incus`, and deletes leftover `incusbr0`/`prod`/`vlan2` bridge devices
that would otherwise make the join fail with a misleading "Network not found").

### Caveats

- **Quorum / HA.** A 2-node cluster has **no fault tolerance** — losing either
  member stalls the cluster DB (Incus uses Raft; majority of 2 is 2). `pleiades`
  is a come-and-go laptop, so until a **3rd stable node** exists, run `iris` as a
  healthy 1-node cluster and treat `pleiades` as an optional guest. A laptop that
  *vanishes* (vs. a graceful `incus-cluster leave`) strands quorum until it
  returns or you `incus cluster remove --force` it.
- **Join is destructive.** `incus-cluster join` wipes the joiner's local Incus
  (instances/images/profiles). `incus export` anything worth keeping first.
- **VLAN 2 trunk is per-host.** Each host sets `my.services.incus.vlan2Trunk` to
  its local trunk subif (`enp3s0.2` on `iris`, `dong0.2` on `pleiades`) and
  declares a matching `networking.vlans."<trunk>"`. A host that omits it gets an
  inert `vlan2` bridge (created, but with no external port); it still clusters fine.

## Troubleshooting

**Instance has no IPv4 after first boot.**

1. Did cloud-init actually consume the network-config? The image must ship cloud-init — `images:ubuntu/<release>` minimal variants do *not*; use `ubuntu:<release>` instead.
   ```bash
   incus exec web01 -- which cloud-init
   incus exec web01 -- cat /etc/netplan/*.yaml
   ```
   Expect a netplan that includes your address/gateway/nameservers. If the netplan is some default (e.g., `dhcp4: true` only), cloud-init didn't run or didn't get the config.

2. Did the launch carry the right config?
   ```bash
   incus config show web01 | grep -A20 network-config
   ```

3. Force a cloud-init re-run (in case it ran before networking was ready):
   ```bash
   incus exec web01 -- cloud-init clean --logs
   incus exec web01 -- cloud-init init
   incus exec web01 -- netplan apply
   incus exec web01 -- ip -4 addr
   ```

**Instance has the right IP but can't reach the upstream gateway (172.16.0.254).**

L2 path through the bridge is broken. Diagnose from pleiades:

```bash
ip -d link show dong0.2                 # exists, up, vlan id 2?
bridge link show | grep dong0.2         # master vlan2 state forwarding?
ping -c 2 -I vlan2 172.16.0.254         # can pleiades reach the gateway via the bridge?
```

- If `dong0.2` is missing → the VLAN subif didn't come up; `systemctl status dong0.2-netdev.service` and start it if needed.
- If `bridge link` doesn't show dong0.2 enslaved → incus didn't enslave it. `sudo systemctl restart incus.service` usually fixes; if not, `sudo ip link set dong0.2 master vlan2`.
- If pleiades itself can't ping the gateway via vlan2 → upstream switch isn't trunking VLAN 2 on the dong0 port, or the gateway isn't on VLAN 2.

**Rebooted pleiades, vlan2 bridge has no ports.**

This is the cold-boot race between `dong0.2-netdev.service` and `incus.service`. The systemd ordering edge in [hosts/pleiades/default.nix](hosts/pleiades/default.nix) (`systemd.services.incus.after = [ "dong0.2-netdev.service" ]; wants = [ ... ];`) prevents it. If it recurs, confirm the edge is still present and active: `systemctl show incus.service -p After | grep dong0.2-netdev`.
