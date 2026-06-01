# Incus operations on pleiades

Quick reference for launching instances on the incus host. The source of truth for all networks and profiles is [modules/services/incus.nix](modules/services/incus.nix).

## Networks

| Name | Type | Subnet | DHCP | NAT | Notes |
| --- | --- | --- | --- | --- | --- |
| `incusbr0` | NAT bridge | auto | yes | yes | Default isolated network. Containers reach the internet via SNAT; no inbound. |
| `prod` | Routed bridge | 172.16.4.0/24 | yes (dynamic .100-.200) | no | DHCP pool, gateway `.254`. |
| `vlan2` | L2 bridge over `dong0.2` | 172.16.0.0/24 | reservations only | no | Trunked to upstream VLAN 2. dnsmasq locked to `dhcp-ignore=tag:!known` — only registered MACs get a lease. |

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

Pick an unused address in 172.16.0.0/24 (avoid the gateway `.254`, pleiades's bridge `.249`, and anything in `incus list` or `cat /var/lib/incus/networks/vlan2/dnsmasq.leases`).

### Container

```bash
incus launch images:debian/12 web01 \
  --profile default \
  --profile basebuild01 \
  --profile net-vlan2 \
  --profile storage-40GB \
  --profile mem-4GB \
  -d eth0,ipv4.address=172.16.0.50
```

- `default` provides the root disk; `net-vlan2` overrides the eth0 device default brings (later profile wins).
- `basebuild01` is optional — drop it for a vanilla image.
- `-d eth0,ipv4.address=…` writes the dnsmasq reservation **before** the container boots, so first-boot DHCP gets the reserved IP.

### VM

Same as container, plus `--vm` and a CPU profile (containers default to host limits; VMs need an explicit shape):

```bash
incus launch images:debian/12 web01 --vm \
  --profile default \
  --profile basebuild01 \
  --profile net-vlan2 \
  --profile storage-40GB \
  --profile cpu-4 \
  --profile mem-4GB \
  -d eth0,ipv4.address=172.16.0.50
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

```bash
incus config device set web01 eth0 ipv4.address=172.16.0.51
incus restart web01
```

The set updates the dnsmasq reservation immediately; the restart forces the container to re-DHCP and pick up the new lease. Without the restart it'll keep its current lease until expiry.

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

**VM has no IPv4; in-guest interface is `enpXsY`, not `eth0`.**

The likely cause is that the cloud-init network-config inside the VM references `eth0`, which doesn't exist (VMs get predictable naming). The `net-vlan2` profile sidesteps this by setting an explicit `cloud-init.network-config` that match-globs on `e*`. If the VM was launched before that profile change landed, cloud-init has already written a stale netplan — either re-run cloud-init or just rebuild the VM. To force re-run:

```bash
incus exec demo -- cloud-init clean --logs
incus exec demo -- cloud-init init
incus exec demo -- netplan apply
```

Confirm the netplan inside the VM now matches:

```bash
incus exec demo -- cat /etc/netplan/*.yaml
# Expect a match: { name: "e*" } block with dhcp4: true
```

Then check the dnsmasq lease/reservation paths below to confirm the DHCP exchange completes.

**Instance has no IPv4 after first boot.**

1. Reservation registered?
   ```bash
   sudo cat /var/lib/incus/networks/vlan2/dnsmasq.hosts/web01.eth0
   ```
   Should contain `<mac>,172.16.0.50`. If missing, the `-d eth0,ipv4.address=…` flag didn't take — re-run `incus config device set web01 eth0 ipv4.address=…` and restart.

2. dnsmasq running for this network?
   ```bash
   ps -ef | grep 'dnsmasq.*incus.*vlan2'
   sudo cat /var/lib/incus/networks/vlan2/dnsmasq.raw
   ```
   The raw config must include `dhcp-ignore=tag:!known` (the lockdown). If dnsmasq isn't running at all, `incus network info vlan2` will show the network state.

3. dnsmasq actually handing out the lease?
   ```bash
   sudo cat /var/lib/incus/networks/vlan2/dnsmasq.leases
   ```
   You should see a line `<unix-timestamp> <mac> 172.16.0.50 web01 <client-id>`. Empty means no lease was issued — most likely the container's MAC doesn't match the reservation, which happens if you set `ipv4.address` *after* the container was launched without restarting it.

4. Container is sending DHCP requests?
   ```bash
   incus exec web01 -- journalctl -u systemd-networkd -b   # or networking.service on older debian
   ```
   If it's not even trying DHCP, the image isn't configured to DHCP on eth0 by default — either fix the image or add a `cloud-init.network-config` to the instance with the right interface name.

**Container can reach the bridge (172.16.0.249) but not the upstream gateway (172.16.0.254).**

Confirms the L2 path is fine and the issue is upstream of pleiades. Check the physical switch's VLAN 2 trunk config on the dong0 port, and confirm the upstream router/gateway is actually on VLAN 2.

**dnsmasq replying to clients we didn't reserve.**

The lockdown should prevent this. Confirm it's still in place:

```bash
sudo cat /var/lib/incus/networks/vlan2/dnsmasq.raw | grep dhcp-ignore
```

Must show `dhcp-ignore=tag:!known`. If it's missing, `raw.dnsmasq` in [modules/services/incus.nix](modules/services/incus.nix) was changed — restore it and `nixos-rebuild switch`.
