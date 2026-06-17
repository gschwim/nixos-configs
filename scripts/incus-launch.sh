# incus-launch — launch an incus instance attached to one or more L2
# pass-through incus networks (no DHCP on the bridge). Generates
# MAC-pinned cloud-init network-config from per-network gateway/DNS
# kept in the NET_* tables below.
#
# Networks served by incus DHCP (incusbr0) are NOT this script's
# job — attach to those via `-p net-<x>` directly on `incus launch`.
#
# Usage:
#   incus-launch <name> <image> [--vm] <net>:<ip>[/<prefix>] [<net>:<ip>...] [-- <incus-args>]
#
# Examples:
#   incus-launch web01 ubuntu:26.04 infra100:172.16.0.66
#   incus-launch web02 images:debian/12 --vm cloud104:172.16.4.66 infra100:172.16.0.66 -- -p storage-80GB -p mem-8GB

usage() {
  cat >&2 <<'EOF'
incus-launch — launch instance on L2-passthrough incus network(s) with
              MAC-pinned cloud-init network-config.

Usage:
  incus-launch <name> <image> [--vm] <net>:<ip>[/<prefix>] [<net>:<ip>...] [-- <incus-args>]

  <name>     instance name
  <image>    incus image (e.g., ubuntu:26.04, images:debian/12)
  --vm       launch as VM (omit for container)
  <net>:<ip> network and IP for each NIC. Per-network gateway/DNS/prefix
             defaults live in NET_* tables in this script.
  --         everything after is passed verbatim to `incus launch`
             (e.g., -p storage-80GB -p mem-8GB)

Examples:
  incus-launch web01 ubuntu:26.04 infra100:172.16.0.66
  incus-launch web02 ubuntu:26.04 --vm cloud104:172.16.4.66 infra100:172.16.0.66 -- -p mem-8GB
EOF
  exit "${1:-1}"
}

# ---- per-network metadata --------------------------------------------------
# Add a row when standing up a new L2-passthrough incus network.
# Skip incus-DHCP networks (incusbr0) — those don't go here.

declare -A NET_GW NET_DNS NET_PREFIX NET_PARENT
NET_GW[infra100]="172.16.0.254"; NET_DNS[infra100]="172.16.1.253"; NET_PREFIX[infra100]="24"
NET_GW[cloud104]="172.16.4.254"; NET_DNS[cloud104]="172.16.1.253"; NET_PREFIX[cloud104]="24"

# users1 is a NixOS-managed bridge (modules/networking/static.nix) over the host's
# primary NIC native VLAN, NOT an incus-managed network. Attach via a `bridged`
# NIC whose parent is the bridge (NET_PARENT below) rather than `network=`. The
# native VLAN has no incus DHCP, so we still pin a static IP via cloud-init.
NET_GW[users1]="172.16.1.254"; NET_DNS[users1]="172.16.1.253"; NET_PREFIX[users1]="24"; NET_PARENT[users1]="users1"

# ---- helpers ---------------------------------------------------------------

# Random locally-administered unicast MAC. 0x02 prefix = LA+unicast.
# Stored in the incus instance config at launch — travels with the
# instance on export/import/move. Not re-derived on re-launch.
gen_mac() {
  printf '02:%s:%s:%s:%s:%s' \
    "$(openssl rand -hex 1)" "$(openssl rand -hex 1)" "$(openssl rand -hex 1)" \
    "$(openssl rand -hex 1)" "$(openssl rand -hex 1)"
}

die() { echo "ERROR: $*" >&2; exit 2; }

# ---- arg parse -------------------------------------------------------------

[ "$#" -ge 3 ] || usage

NAME="$1"; shift
IMAGE="$1"; shift

VM_FLAG=()
if [ "${1:-}" = "--vm" ]; then
  VM_FLAG=(--vm)
  shift
fi

NET_SPECS=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  NET_SPECS+=("$1")
  shift
done

[ "${#NET_SPECS[@]}" -ge 1 ] || die "at least one <net>:<ip> required"

EXTRA_ARGS=()
if [ "${1:-}" = "--" ]; then
  shift
  EXTRA_ARGS=("$@")
fi

# ---- build init args + extra device list + cloud-init network-config ------

# incus's `-d` flag is strictly OVERRIDE syntax (`<device>,<key>=<value>`,
# single key per flag — incus merges multiple flags for the same device).
# It cannot create devices. `-d eth1,nic` errors with "Bad device override
# syntax". The only way to add a new device via the CLI is via the separate
# `incus config device add` command, which means we can't use `incus launch`
# (single-shot) for multi-NIC.
#
# Flow: `incus init` (creates without starting) → `incus config device add`
# for each NIC beyond eth0 → `incus start`. Single-NIC launches go through
# the same path; init+start is equivalent to launch with no extra overhead.

INIT_ARGS=()        # -d/--config flags passed to `incus init`
EXTRA_DEVICES=()    # ethN (N>0): "iface|net|mac", added post-init
NETPLAN_BLOCKS=""

i=0
for spec in "${NET_SPECS[@]}"; do
  net="${spec%%:*}"
  rest="${spec#*:}"
  [ "$net" != "$spec" ] || die "bad spec '$spec' (expected <net>:<ip>)"

  ip="${rest%%/*}"
  if [[ "$rest" == */* ]]; then
    prefix="${rest#*/}"
  else
    prefix="${NET_PREFIX[$net]:-}"
  fi

  [ -n "$prefix" ] || die "no prefix for '$net' (not in NET_PREFIX, not in spec)"
  [ -n "${NET_GW[$net]:-}"  ] || die "no gateway for '$net' (add to NET_GW in $0)"
  [ -n "${NET_DNS[$net]:-}" ] || die "no DNS for '$net' (add to NET_DNS in $0)"

  gw="${NET_GW[$net]}"
  dns="${NET_DNS[$net]}"
  mac=$(gen_mac "$NAME" "$net")
  iface="eth$i"
  key="net$i"

  # Two attach styles: incus-managed networks use `network=<net>`; host bridges
  # (NET_PARENT, e.g. users1) use a `bridged` NIC with `parent=<bridge>`.
  # eth0 is provided by basebuild01 (on incusbr0) — override at init time via -d.
  # eth1+ don't exist yet — defer to post-init device-add (encoded kind|target).
  parent="${NET_PARENT[$net]:-}"
  if [ -n "$parent" ]; then
    if [ "$i" -eq 0 ]; then
      INIT_ARGS+=(-d "${iface},nictype=bridged")
      INIT_ARGS+=(-d "${iface},parent=${parent}")
      INIT_ARGS+=(-d "${iface},hwaddr=${mac}")
    else
      EXTRA_DEVICES+=("${iface}|bridged|${parent}|${mac}")
    fi
  else
    if [ "$i" -eq 0 ]; then
      INIT_ARGS+=(-d "${iface},network=${net}")
      INIT_ARGS+=(-d "${iface},hwaddr=${mac}")
    else
      EXTRA_DEVICES+=("${iface}|network|${net}|${mac}")
    fi
  fi

  NETPLAN_BLOCKS="${NETPLAN_BLOCKS}
  ${key}:
    match: { macaddress: \"${mac}\" }
    addresses: [\"${ip}/${prefix}\"]
    gateway4: \"${gw}\"
    nameservers: { addresses: [\"${dns}\"] }"

  i=$((i+1))
done

NETWORK_CONFIG="version: 2
ethernets:${NETPLAN_BLOCKS}
"

# ---- init → device-add for ethN (N>0) → start ------------------------------

echo "Initializing ${NAME} from ${IMAGE}"
incus init "$IMAGE" "$NAME" \
  "${VM_FLAG[@]}" \
  "${INIT_ARGS[@]}" \
  --config "cloud-init.network-config=${NETWORK_CONFIG}" \
  "${EXTRA_ARGS[@]}"

for entry in "${EXTRA_DEVICES[@]}"; do
  IFS='|' read -r iface kind target mac <<<"$entry"
  echo "Adding device ${iface} on ${target}"
  if [ "$kind" = "bridged" ]; then
    incus config device add "$NAME" "$iface" nic nictype=bridged parent="$target" hwaddr="$mac"
  else
    incus config device add "$NAME" "$iface" nic network="$target" hwaddr="$mac"
  fi
done

echo "Starting ${NAME}"
incus start "$NAME"
