# Central Incus cluster topology — the single source of truth for "which host
# is in which cluster". Consumed by modules/services/incus.nix, which derives
# each host's role (seed vs member), cluster address, and join member_config
# from this map and surfaces it at /etc/incus-cluster.json for the
# `incus-cluster` helper (scripts/incus-cluster).
#
# Shape:
#   <clusterName> = {
#     seed    = <hostname>;          # the bootstrap node (`incus cluster enable`)
#     members = [ <hostname> ... ];  # every node in the cluster (incl. the seed)
#   };
#
# Membership only — NO IP addresses here. Each member's cluster address is read
# from that host's own `my.network.static.address` (defined once in its
# hosts/<host>/default.nix), so there are no duplicated IPs to keep in sync.
#
# Add a host to a cluster: add its hostname to `members`. Pull one out: remove
# it here, or override `my.services.incus.cluster.enable = false;` in the host.
#
# A node belongs to at most ONE cluster. Multiple clusters = multiple entries,
# each with its own seed.
#
# NOTE: a 2-node cluster has no fault tolerance (lose either → quorum stalls);
# 3 voting members are needed for HA. pleiades is a come-and-go laptop, so
# orion-1 is effectively iris-with-an-optional-guest until a 3rd stable node
# exists. See INCUS.md.

{
  orion-1 = {
    seed    = "iris";
    members = [ "iris" "pleiades" ];
  };
}
