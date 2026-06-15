{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.my.services.incus;

  # Central cluster topology (single source of truth). See lib/incus-clusters.nix.
  clusters = import ../../lib/incus-clusters.nix;
  hostName = config.networking.hostName;

  # Which cluster (if any) lists this host as a member.
  clusterNameAuto =
    lib.findFirst (n: lib.elem hostName clusters.${n}.members) null
      (lib.attrNames clusters);

  # --- derived cluster facts (after options resolve) -----------------------
  clusterEnabled = cfg.cluster.enable;
  selfAddr       = cfg.cluster.address;
  isSeed         = cfg.cluster.seed;

  # Concrete, reachable cluster address when clustered; wildcard otherwise.
  httpsAddr = if clusterEnabled then "${selfAddr}:8443" else ":8443";

  # Read another member's cluster address straight from its own config, so IPs
  # live in exactly one place (the host's my.network.static.address). Safe from
  # infinite recursion: static.address is a plain literal independent of this
  # incus module, so forcing it does not pull incus config back in.
  memberAddr = h: inputs.self.nixosConfigurations.${h}.config.my.network.static.address;

  # Per-member keys that MUST all be supplied at join time, exactly as incus's
  # interactive `incus admin init` prompts for them — an incomplete set breaks
  # the whole "initialize storage pools and networks" join phase. For the ZFS
  # 'default' pool that's BOTH `source` and `zfs.pool_name` (incus treats them
  # as distinct member-specific keys, even when equal). The L2 bridges' external
  # trunks (infra100, cloud104) are per-node too (absent on hosts without one).
  memberConfig =
    [ { entity = "storage-pool"; name = "default"; key = "source";        value = cfg.storagePool; }
      { entity = "storage-pool"; name = "default"; key = "zfs.pool_name"; value = cfg.storagePool; }
    ]
    ++ lib.optional (cfg.infra100Trunk != "")
         { entity = "network"; name = "infra100"; key = "bridge.external_interfaces"; value = cfg.infra100Trunk; }
    ++ lib.optional (cfg.cloud104Trunk != "")
         { entity = "network"; name = "cloud104"; key = "bridge.external_interfaces"; value = cfg.cloud104Trunk; };

  # VLAN trunk netdev units to order incus after (cold-boot race fix) — one per
  # configured L2-passthrough trunk on this host.
  trunkUnits = map (t: "${t}-netdev.service")
    (lib.filter (t: t != "") [ cfg.infra100Trunk cfg.cloud104Trunk ]);

  # The descriptor surfaced at /etc/incus-cluster.json for the helper + operator.
  clusterDescriptor = name: {
    inherit name;
    seed         = clusters.${name}.seed;
    role         = if isSeed then "seed" else "member";
    address      = selfAddr;
    members      = lib.genAttrs clusters.${name}.members memberAddr;
    memberConfig = memberConfig;
    storagePool  = cfg.storagePool;
  };
in {
  options.my.services.incus = {
    enable = lib.mkEnableOption "Incus virtualisation (host)";

    storagePool = lib.mkOption {
      type        = lib.types.str;
      default     = "rpool/incus";
      description = "ZFS dataset used as the 'default' Incus storage pool source.";
    };

    infra100Trunk = lib.mkOption {
      type        = lib.types.str;
      default     = "";
      example     = "dong0.100";
      description = ''
        The host's tagged VLAN 100 trunk subif, enslaved into the 'infra100'
        L2-passthrough bridge. Set this per host to the local interface name
        (e.g. "dong0.100" on pleiades, "enp3s0.100" on iris) — the network is
        otherwise defined uniformly across the fleet.

        Empty string (the default) = no trunk on this host: the 'infra100' bridge
        is created but carries no external port (inert locally), and no start-
        order edge is added. Pair this option with a matching
        `networking.vlans."<trunk>"` declaration on the host.

        When set, the module also pins incus to start after the trunk's netdev
        unit, and supplies the value as per-member join config when clustering.
      '';
    };

    cloud104Trunk = lib.mkOption {
      type        = lib.types.str;
      default     = "";
      example     = "dong0.104";
      description = ''
        The host's tagged VLAN 104 trunk subif, enslaved into the 'cloud104'
        L2-passthrough bridge. Identical in shape to infra100Trunk, just a
        different VLAN/segment. Set per host (e.g. "dong0.104" on pleiades,
        "enp3s0.104" on iris).

        Empty string (the default) = no trunk on this host: the 'cloud104'
        bridge is created but carries no external port (inert locally), and no
        start-order edge is added. Pair this option with a matching
        `networking.vlans."<trunk>"` declaration on the host.
      '';
    };

    cluster = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = clusterNameAuto != null;
        description = ''
          Participate in an Incus cluster. Defaults true when this host is
          listed in lib/incus-clusters.nix. Set false in a host's default.nix
          to pull it out (reverts to a standalone daemon on :8443).
        '';
      };

      name = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = clusterNameAuto;
        description = "Cluster this host belongs to (derived from lib/incus-clusters.nix).";
      };

      seed = lib.mkOption {
        type        = lib.types.bool;
        default     = clusterNameAuto != null && clusters.${clusterNameAuto}.seed == hostName;
        description = ''
          Whether this host is the cluster seed (the bootstrap node that runs
          `incus cluster enable`). Derived from lib/incus-clusters.nix.
        '';
      };

      address = lib.mkOption {
        type        = lib.types.str;
        default     = config.my.network.static.address;
        description = ''
          This node's cluster address (without port). Defaults to its static
          IPv4 address; the daemon advertises <address>:8443 to peers.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.incus = {
      enable = true;

      preseed = {
        config = {
          "core.https_address" = httpsAddr;
        };

        storage_pools = [
          {
            name   = "default";
            driver = "zfs";
            config = {
              source = cfg.storagePool;
            };
          }
        ];

        networks = [
          {
            name = "incusbr0";
            type = "bridge";
            config = {
              "ipv4.address" = "auto";
              "ipv4.nat"     = "true";
            };
          }
          {
            # Pure L2 pass-through for VLAN 104 (cloud network) — identical in
            # shape to infra100, different segment. Enslaves the host's tagged
            # trunk subif (cfg.cloud104Trunk, set per host); NO IP, NO DHCP, NO
            # NAT. Instances reach the upstream VLAN 104 gateway (172.16.4.254)
            # directly; per-instance IPs via cloud-init (use incus-launch).
            name = "cloud104";
            type = "bridge";
            config = {
              "ipv4.address" = "none";
              "ipv6.address" = "none";
            } // lib.optionalAttrs (cfg.cloud104Trunk != "") {
              "bridge.external_interfaces" = cfg.cloud104Trunk;
            };
          }
          {
            # Pure L2 pass-through for VLAN 100. The bridge enslaves the host's
            # tagged trunk subif (cfg.infra100Trunk, set per host) and carries
            # NO IP, NO DHCP, NO NAT. Containers/VMs on this bridge sit on the
            # same L2 segment as the rest of VLAN 100 and reach the upstream
            # gateway (172.16.0.254) directly.
            #
            # Per-instance IPs are set via cloud-init.network-config on each
            # instance (or the launch helper) — incus runs no dnsmasq here,
            # so DHCP-style reservations don't apply. See INCUS.md.
            name = "infra100";
            type = "bridge";
            config = {
              "ipv4.address" = "none";
              "ipv6.address" = "none";
            } // lib.optionalAttrs (cfg.infra100Trunk != "") {
              "bridge.external_interfaces" = cfg.infra100Trunk;
            };
          }
        ];

        profiles = [
          {
            name = "default";
            devices = {
              root = { type = "disk"; pool = "default"; path = "/"; };
              eth0 = { type = "nic";  network = "incusbr0"; name = "eth0"; };
            };
          }

          {
            # Standalone starter profile: root disk + eth0 on the NAT
            # bridge + cloud-init for the admin user. Apply alone (with
            # optional storage/cpu/mem profiles) — no need to also apply
            # `default`. incus-launch overrides eth0's network when
            # attaching to L2-passthrough networks like infra100.
            name = "basebuild01";
            description = "Base VM/Container image (root + eth0/incusbr0 + cloud-init)";
            config = {
              "user.user-data" = ''
                #cloud-config
                package_update: true
                package_upgrade: true

                packages:
                  - openssh-server
                  - neovim
                  - zsh

                users:
                  - name: schwim
                    groups: sudo, docker
                    sudo: ALL=(ALL) NOPASSWD:ALL
                    ssh_authorized_keys:
                      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCrlcz/L98ZWYZ/QzkRxoO95Rz/GkBj1H08u2HGPm1vz1Qb8NzIUFQYNCVYuV54qpEF9t3ZX/sayWow6fB8490KYNxKvN1sGuPGorhKFoP169vUo5KUknrFhlXwTQSjvS8Dx629SjjcCkWBDpi5s5ZYkTqV0zb89/pRhTtgVWDiyvo8EWnv1eS4gDk5hTVxfgwChyYEa++g+9IaTzYYgwkM833Pt+W9jQE6RD23MSSuiVfMBsVjMlwsMWDi70dB7DHOImDQzIjyYHxkgRcb3VAJmY0/aQM9tr1JTW0Knvuds1to68qTqwwvUhXkW5OtgmgY25BJst+/0rgeirE1OvK/UgdDeKVQcU3u9Oym+2/gNwRzE7VQ+STVVznfNXzIdGbmoO5W7ZcE2GuiJEx1gq8a7/m8e07zfok8N+DdAgVyH0Rhs7uZLoovRwFyJLDX+atEDyB26hNAU+iTHX44NG8cwuMh3NiKZsNmQwFpCXRa9bKNQKKXRRxOQ00AniXd6HU= schwim@blushda.local

                final_message: "The system is finally up, after $UPTIME seconds"
              '';
            };
            devices = {
              root = { type = "disk"; pool = "default"; path = "/"; };
              eth0 = { type = "nic";  network = "incusbr0"; name = "eth0"; };
            };
          }

          { name = "storage-10GB";  description = "Root disk: 10 GB";  devices.root = { type = "disk"; pool = "default"; path = "/"; size = "10GiB";  }; }
          { name = "storage-40GB";  description = "Root disk: 40 GB";  devices.root = { type = "disk"; pool = "default"; path = "/"; size = "40GiB";  }; }
          { name = "storage-80GB";  description = "Root disk: 80 GB";  devices.root = { type = "disk"; pool = "default"; path = "/"; size = "80GiB";  }; }
          { name = "storage-100GB"; description = "Root disk: 100 GB"; devices.root = { type = "disk"; pool = "default"; path = "/"; size = "100GiB"; }; }

          { name = "net-incusbr0"; description = "Attach to default NAT bridge"; devices.eth0 = { type = "nic"; network = "incusbr0"; name = "eth0"; }; }

          # users1 is a NixOS-managed bridge (modules/networking/static.nix) over
          # the host's primary NIC — it carries the host's mgmt IP and bridges the
          # native VLAN (172.16.0.0/16 mgmt segment). So incus does NOT manage it;
          # instances attach with a `bridged` NIC whose parent is the bridge
          # (nictype/parent, not network=). If the native VLAN has DHCP, a bare
          # `-p net-users1` gets an address; otherwise inject one via incus-launch.
          { name = "net-users1"; description = "Attach to the users1 bridge (host primary NIC native VLAN)"; devices.eth0 = { type = "nic"; nictype = "bridged"; parent = "users1"; name = "eth0"; }; }

          # No net-infra100 / net-cloud104 profile: those L2-passthrough bridges
          # have no DHCP, so a bare attachment is insufficient (instance also
          # needs IP/GW/DNS injected). Use `incus-launch` (scripts/incus-launch.sh)
          # — it emits both the device attachment and cloud-init network-
          # config in one shot, with stable MAC-based per-NIC matching.
          # Profile-style attachment also doesn't compose for multi-NIC
          # (two profiles can't both define eth0).

          { name = "disk-default"; description = "Root disk on default ZFS pool"; devices.root = { type = "disk"; pool = "default"; path = "/"; }; }

          { name = "cpu-1"; config."limits.cpu" = "1"; }
          { name = "cpu-4"; config."limits.cpu" = "4"; }
          { name = "cpu-8"; config."limits.cpu" = "8"; }

          { name = "mem-1GB";  config."limits.memory" = "1GiB";  }
          { name = "mem-2GB";  config."limits.memory" = "2GiB";  }
          { name = "mem-4GB";  config."limits.memory" = "4GiB";  }
          { name = "mem-8GB";  config."limits.memory" = "8GiB";  }
          { name = "mem-16GB"; config."limits.memory" = "16GiB"; }
        ];
      } // lib.optionalAttrs (clusterEnabled && isSeed) {
        # A freshly installed seed auto-bootstraps the cluster on first init.
        # No-op on an already-initialized seed (preseed is one-shot) — there
        # the `incus-cluster enable` helper performs the in-place enable.
        cluster = {
          enabled     = true;
          server_name = hostName;
        };
      };
    };

    # Surface the central topology for the `incus-cluster` helper + operators.
    environment.etc."incus-cluster.json" = lib.mkIf clusterEnabled {
      text = builtins.toJSON (clusterDescriptor cfg.cluster.name);
    };

    # Fleet-wide launch helper for L2-passthrough networks (no DHCP on the
    # bridge). Generates MAC-pinned cloud-init network-config from the
    # network metadata baked into the script. Source: scripts/incus-launch.sh.
    #
    # incus-cluster: drives the imperative cluster steps (enable/token/join/
    # leave) from the central topology. Source: scripts/incus-cluster.
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "incus-launch";
        runtimeInputs = with pkgs; [ incus coreutils openssl ];
        text = builtins.readFile ../../scripts/incus-launch.sh;
      })
      (pkgs.writeShellApplication {
        name = "incus-cluster";
        runtimeInputs = with pkgs; [ incus openssh coreutils jq gnugrep systemd psmisc procps util-linux iproute2 zfs ];
        # SC2029: the remote `incus cluster add <self>` is built from local
        # values we intend to expand client-side before sending — that's the point.
        excludeShellChecks = [ "SC2029" ];
        text = builtins.readFile ../../scripts/incus-cluster;
      })
    ];

    # Cold-boot race fix, derived uniformly from the host's trunk(s): without
    # this, incus.service can win the race against a VLAN netdev, create the
    # L2-passthrough bridge with no enslaved port, and never retry — leaving
    # every instance on it with no path to the upstream VLAN until incus is
    # restarted by hand. Pin incus after each trunk's <iface>-netdev.service.
    # (Assumes each *Trunk is a declared `networking.vlans."<trunk>"` subif.)
    systemd.services.incus = lib.mkIf (trunkUnits != []) {
      after = trunkUnits;
      wants = trunkUnits;
    };

    networking.firewall.allowedTCPPorts = [ 8443 ];
    # The L2-passthrough bridges (infra100, cloud104) are deliberately NOT
    # trusted: they sit on shared VLANs, so trusting them would expose this
    # host's services to every device on those VLANs — not just containers we
    # own. Only the host-local NAT bridge is trusted.
    networking.firewall.trustedInterfaces = [ "incusbr0" ];
  };
}
