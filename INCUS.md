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
| | `basebuild01` | cloud-init: apt update/upgrade, installs openssh-server + neovim + zsh, creates a sudo user with SSH key. No devices. |
| Network | `net-incusbr0` | `eth0` on `incusbr0` (NAT). |
| | `net-prod` | `eth0` on `prod` (routed 172.16.4.0/24). |
| | `net-vlan2` | `eth0` on `vlan2` (VLAN 2, DHCP reservations only). |
| Storage | `storage-10GB` / `40GB` / `80GB` / `100GB` | Sized root disk on `default` pool. |
| | `disk-default` | Root disk on `default` pool, unsized. |
| CPU | `cpu-1` / `cpu-4` / `cpu-8` | `limits.cpu` =N. |
| Memory | `mem-1GB` / `mem-2GB` / `mem-4GB` / `mem-8GB` / `mem-16GB` | `limits.memory` =N. |

## Deploy on `vlan2` with a static IP

The `vlan2` bridge has no DHCP. Each instance gets its IP, gateway, and DNS from a `cloud-init.network-config` set at launch time. Use a Ubuntu image (`ubuntu:26.04`, official Ubuntu remote) — it ships cloud-init. The minimal `images:ubuntu/<release>` variants do not.

Pick an unused address in 172.16.0.0/24 (avoid the gateway `.254` and anything in `incus list`).

### Container

```bash
incus launch ubuntu:26.04 web01 \
  --profile default \
  --profile basebuild01 \
  --profile net-vlan2 \
  --profile storage-40GB \
  --profile mem-4GB \
  --config cloud-init.network-config="version: 2
ethernets:
  primary:
    match: { name: e* }
    addresses: [172.16.0.50/24]
    gateway4: 172.16.0.254
    nameservers: { addresses: [172.16.1.253] }
"
```

- `default` provides the root disk; `net-vlan2` overrides the eth0 device default brings (later profile wins).
- `basebuild01` is optional — drop it for a vanilla image.
- `match: { name: e* }` matches both `eth0` (containers) and `enpXsY` (VMs).

### VM

Same recipe with `--vm` and a CPU profile (containers default to host limits; VMs need an explicit shape):

```bash
incus launch ubuntu:26.04 web01 --vm \
  --profile default \
  --profile basebuild01 \
  --profile net-vlan2 \
  --profile storage-40GB \
  --profile cpu-4 \
  --profile mem-4GB \
  --config cloud-init.network-config="version: 2
ethernets:
  primary:
    match: { name: e* }
    addresses: [172.16.0.50/24]
    gateway4: 172.16.0.254
    nameservers: { addresses: [172.16.1.253] }
"
```

### One-line helper (recommended for repeat use)

Drop this in `~/.zshrc` to centralize the VLAN 2 gateway/DNS values:

```bash
vlan2-launch() {
  local name=$1 ip=$2; shift 2
  incus launch ubuntu:26.04 "$name" --vm \
    -p default -p net-vlan2 -p storage-40GB -p basebuild01 \
    --config cloud-init.network-config="version: 2
ethernets:
  primary:
    match: { name: e* }
    addresses: [$ip/24]
    gateway4: 172.16.0.254
    nameservers: { addresses: [172.16.1.253] }
" "$@"
}
# usage:  vlan2-launch web01 172.16.0.50
```

## Verify it worked

```bash
incus list web01                                      # state Running, IPv4 = 172.16.0.50
incus exec web01 -- ip -4 addr                        # 172.16.0.50/24 on eth0 (container) or enpXsY (VM)
incus exec web01 -- ip route                          # default via 172.16.0.254
incus exec web01 -- resolvectl dns                    # 172.16.1.253 (or check /etc/resolv.conf)
incus exec web01 -- ping -c 2 172.16.0.254            # reach the upstream gateway
```

If `incus list` shows the instance Running but with no IPv4, see Troubleshooting below.

> **VMs vs containers and interface names.** Containers see the NIC as `eth0` (incus presents the veth's container side with that name). VMs see it as whatever their kernel's predictable naming yields — typically `enp5s0` or `ens3`. The `net-vlan2` profile carries a `cloud-init.network-config` that match-globs on `e*` so DHCP runs on either name. Don't reach inside the VM and assume `eth0`.

## Change the IP later

Rewrite the instance's `cloud-init.network-config` and either re-run cloud-init in place or rebuild the instance.

In-place (no rebuild):

```bash
incus config set web01 cloud-init.network-config="version: 2
ethernets:
  primary:
    match: { name: e* }
    addresses: [172.16.0.51/24]
    gateway4: 172.16.0.254
    nameservers: { addresses: [172.16.1.253] }
"
incus exec web01 -- cloud-init clean --logs
incus exec web01 -- cloud-init init
incus exec web01 -- netplan apply
```

Or just rebuild it (`incus delete --force web01 && vlan2-launch web01 172.16.0.51`) — usually faster if you don't have state to preserve.

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
