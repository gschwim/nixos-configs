{ config, lib, ... }:
let
  cfg = config.my.services.incus;
in {
  options.my.services.incus = {
    enable = lib.mkEnableOption "Incus virtualisation (host)";

    storagePool = lib.mkOption {
      type        = lib.types.str;
      default     = "rpool/incus";
      description = "ZFS dataset used as the 'default' Incus storage pool source.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.incus = {
      enable = true;

      preseed = {
        config = {
          "core.https_address" = ":8443";
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
            name = "prod";
            type = "bridge";
            config = {
              "ipv4.address"      = "172.16.4.254/24";
              "ipv4.nat"          = "false";
              "ipv4.dhcp"         = "true";
              "dns.nameservers"   = "172.16.1.253";
              "ipv4.dhcp.ranges"  = "172.16.4.100-172.16.4.200";
            };
          }
          {
            # Incus-managed bridge for VLAN 2. The bridge enslaves dong0.2
            # (the tagged trunk subif declared on the host) AND holds an IP
            # on VLAN 2 so incus can run a dnsmasq on it for per-container
            # DHCP reservations.
            #
            # Per-container IP assignment:
            #   incus config device set <ct> eth0 ipv4.address=172.16.0.X
            # That writes a dhcp-host= entry into this network's dnsmasq;
            # the container DHCPs at boot and receives the reserved IP plus
            # the gateway (DHCP option 3) and DNS (option 6) announced below.
            #
            # WARNING: do not drop raw.dnsmasq=dhcp-ignore=tag:!known.
            # Because dong0.2 is a port on this bridge, dnsmasq sees DHCP
            # broadcasts from the entire VLAN 2 segment. Without that
            # directive it would reply to any unknown client and become a
            # rogue DHCP server on the VLAN.
            name = "vlan2";
            type = "bridge";
            config = {
              "bridge.external_interfaces" = "dong0.2";
              "ipv4.address"               = "172.16.0.249/24";
              "ipv4.nat"                   = "false";
              "ipv4.dhcp"                  = "true";
              "ipv4.dhcp.gateway"          = "172.16.0.254";
              "dns.nameservers"            = "172.16.1.253";
              "ipv6.address"               = "none";
              "raw.dnsmasq"                = "dhcp-ignore=tag:!known";
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
            name = "basebuild01";
            description = "Base VM/Container image";
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
            };
          }

          { name = "storage-10GB";  description = "Root disk: 10 GB";  devices.root = { type = "disk"; pool = "default"; path = "/"; size = "10GiB";  }; }
          { name = "storage-40GB";  description = "Root disk: 40 GB";  devices.root = { type = "disk"; pool = "default"; path = "/"; size = "40GiB";  }; }
          { name = "storage-80GB";  description = "Root disk: 80 GB";  devices.root = { type = "disk"; pool = "default"; path = "/"; size = "80GiB";  }; }
          { name = "storage-100GB"; description = "Root disk: 100 GB"; devices.root = { type = "disk"; pool = "default"; path = "/"; size = "100GiB"; }; }

          { name = "net-prod";     description = "Attach to prod routed bridge (172.16.4.0/24)"; devices.eth0 = { type = "nic"; network = "prod";     name = "eth0"; }; }
          { name = "net-incusbr0"; description = "Attach to default NAT bridge";                  devices.eth0 = { type = "nic"; network = "incusbr0"; name = "eth0"; }; }

          # Per-container IP: `incus config device set <ct> eth0 ipv4.address=172.16.0.X`.
          # The container DHCPs at boot; the vlan2 network's dnsmasq serves
          # the reserved IP plus gateway 172.16.0.254 and DNS 172.16.1.253.
          { name = "net-vlan2"; description = "Attach to VLAN 2 bridge (172.16.0.0/24, gw .254, DHCP reservations only)"; devices.eth0 = { type = "nic"; network = "vlan2"; name = "eth0"; }; }

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
      };
    };

    networking.firewall.allowedTCPPorts = [ 8443 ];
    # vlan2 deliberately NOT trusted: the bridge has an IP on VLAN 2, so
    # trusting it would expose pleiades's services to every device on that
    # VLAN — not just containers we own. Containers reach out via the bridge
    # freely; inbound to pleiades from VLAN 2 still goes through the firewall.
    networking.firewall.trustedInterfaces = [ "incusbr0" "prod" ];
  };
}
