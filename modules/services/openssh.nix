{ config, lib, ... }:
let
  cfg      = config.my.services.openssh;
  hostName = config.networking.hostName;
in {
  options.my.services.openssh = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "OpenSSH server (default-on baseline).";
    };

    useHostCertificate = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Present a CA-signed host certificate to clients AND deploy the
        full host identity declaratively from the repo. When on:

          - /etc/ssh/ssh_host_ed25519_key.pub  ← lib/host-certs/<host>_…pub
          - /etc/ssh/ssh_host_ed25519_key-cert.pub
                                                ← lib/host-certs/<host>_…-cert.pub
          - /etc/ssh/ssh_host_ed25519_key (priv) ← agenix-decrypted from
              secrets/host-keys/<host>_ssh_host_ed25519_key.age at activation,
              using the host's bootstrap age key at /etc/age/host.key as the
              decryption identity (set by modules/secrets.nix).

        Tampering with any of these reverts on next nixos-rebuild switch.
        Rotation = re-run gen-host-key.sh + commit + rebuild.

        Disable on ephemeral live ISOs (no declarative artifacts staged).
      '';
    };

    trustUserCA = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Trust user SSH certificates signed by the SSH User CA. The CA pubkey
        is committed to the repo at lib/user-ca.pub and staged at
        /etc/ssh/user_ca.pub; sshd references it via TrustedUserCAKeys.
        Hosts with this off fall back to authorized_keys-only auth.
      '';
    };

    trustHostCA = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Trust HOST SSH certificates signed by the SSH Host CA. Client-side
        only — installs an `@cert-authority * <CA>` line into
        /etc/ssh/ssh_known_hosts (fleet-wide, every user) so outbound SSH
        from this host accepts any peer presenting a Host-CA-signed cert
        with no TOFU prompt. The CA pubkey is committed to the repo at
        lib/host-ca.pub. Mirror of blushda's @cert-authority line installed
        by scripts/trust-ssh-ca.sh.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.openssh.enable = true;
      services.openssh.settings = lib.mkMerge [
        {
          # Installed systems: never allow root SSH. Admin via schwim + sudo.
          # (The installer ISO overrides this to "prohibit-password" because
          # nixos-anywhere pivots to root@ mid-install — see hosts/installer.)
          PermitRootLogin        = lib.mkDefault "no";
          PasswordAuthentication = lib.mkDefault false;
        }
        (lib.mkIf cfg.useHostCertificate {
          HostCertificate = "/etc/ssh/ssh_host_ed25519_key-cert.pub";
        })
        (lib.mkIf cfg.trustUserCA {
          TrustedUserCAKeys = "/etc/ssh/user_ca.pub";
        })
      ];
    }
    (lib.mkIf cfg.trustUserCA {
      environment.etc."ssh/user_ca.pub".source = ../../lib/user-ca.pub;
    })
    (lib.mkIf cfg.useHostCertificate {
      # Pub + cert: plaintext, committed to lib/host-certs/, placed via
      # environment.etc → symlinks into /etc/ssh/. Any local edit reverts
      # on next rebuild.
      environment.etc."ssh/ssh_host_ed25519_key.pub".source =
        ../../lib/host-certs + "/${hostName}_ssh_host_ed25519_key.pub";
      environment.etc."ssh/ssh_host_ed25519_key-cert.pub".source =
        ../../lib/host-certs + "/${hostName}_ssh_host_ed25519_key-cert.pub";

      # Priv: agenix-decrypted at activation. age.secrets.<name>.path puts
      # the decrypted file directly at /etc/ssh/ssh_host_ed25519_key (as a
      # symlink to /run/agenix/…, which sshd follows fine).
      age.secrets."ssh-host-key-${hostName}" = {
        file  = ../../secrets/host-keys + "/${hostName}_ssh_host_ed25519_key.age";
        path  = "/etc/ssh/ssh_host_ed25519_key";
        owner = "root";
        group = "root";
        mode  = "0600";
      };
    })
    (lib.mkIf cfg.trustHostCA {
      # `programs.ssh.knownHosts.<name>` writes entries into
      # /etc/ssh/ssh_known_hosts (system-wide, consulted before per-user
      # ~/.ssh/known_hosts). certAuthority = true produces an
      # `@cert-authority <hostNames> <publicKey>` line — pattern `*` means
      # trust any host signed by this CA; the cert's own validation provides
      # the boundary, same as blushda's known_hosts setup.
      programs.ssh.knownHosts.host-ca = {
        certAuthority = true;
        hostNames     = [ "*" ];
        publicKey     = lib.removeSuffix "\n" (builtins.readFile ../../lib/host-ca.pub);
      };
    })
  ]);
}
