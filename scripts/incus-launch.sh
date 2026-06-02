# incus-launch — launch an incus instance attached to one or more L2
# pass-through incus networks (no DHCP on the bridge). Generates
# MAC-pinned cloud-init network-config from per-network gateway/DNS
# kept in the NET_* tables below.
#
# Networks served by incus DHCP (incusbr0, prod) are NOT this script's
# job — attach to those via `-p net-<x>` directly on `incus launch`.
#
# Usage:
#   incus-launch <name> <image> [--vm] <net>:<ip>[/<prefix>] [<net>:<ip>...] [-- <incus-args>]
#
# Examples:
#   incus-launch web01 ubuntu:26.04 vlan2:172.16.0.66
#   incus-launch web02 images:debian/12 --vm vlan2:172.16.0.66 vlan3:10.0.3.66 -- -p storage-80GB -p mem-8GB

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
  incus-launch web01 ubuntu:26.04 vlan2:172.16.0.66
  incus-launch web02 ubuntu:26.04 --vm vlan2:172.16.0.66 vlan3:10.0.3.66 -- -p mem-8GB
EOF
  exit "${1:-1}"
}

# ---- per-network metadata --------------------------------------------------
# Add a row when standing up a new L2-passthrough incus network.
# Skip incus-DHCP networks (incusbr0, prod) — those don't go here.

declare -A NET_GW NET_DNS NET_PREFIX
NET_GW[vlan2]="172.16.0.254"; NET_DNS[vlan2]="172.16.1.253"; NET_PREFIX[vlan2]="24"

# ---- helpers ---------------------------------------------------------------

# Deterministic MAC from (instance-name, network-name). 0x02 prefix marks
# the MAC as locally-administered + unicast. Same (name, net) always
# yields the same MAC, so re-launching the same instance name keeps its
# upstream ARP cache entry valid.
gen_mac() {
  local h
  h=$(printf '%s|%s' "$1" "$2" | sha256sum | cut -c1-10)
  printf '02:%s:%s:%s:%s:%s' "${h:0:2}" "${h:2:2}" "${h:4:2}" "${h:6:2}" "${h:8:2}"
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

# ---- build device flags + cloud-init network-config ------------------------

DEVICE_ARGS=()
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

  # type=nic + network=<incus-managed-network> lets -d create the device
  # from scratch (when no profile defines eth0) or override an existing
  # one (e.g. basebuild01's eth0 on incusbr0). Using `network=` is the
  # right spec for incus-managed networks; `parent=` is for unmanaged
  # bridges and would conflict with profiles that set `network=`.
  DEVICE_ARGS+=(-d "${iface},type=nic,network=${net},hwaddr=${mac}")

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

# ---- launch ----------------------------------------------------------------

incus launch "$IMAGE" "$NAME" \
  "${VM_FLAG[@]}" \
  "${DEVICE_ARGS[@]}" \
  --config "cloud-init.network-config=${NETWORK_CONFIG}" \
  "${EXTRA_ARGS[@]}"
