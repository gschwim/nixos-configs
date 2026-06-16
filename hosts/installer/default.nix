# Custom NixOS installer ISO.
#
# Build:    nix build .#nixosConfigurations.installer.config.system.build.isoImage
# Output:   result/iso/nixos-*-x86_64-linux.iso
# Flash:    sudo dd if=result/iso/nixos-*.iso of=/dev/rdiskN bs=4m status=progress
# VM use:   attach the ISO as a CD/DVD device, boot from it.
#
# What this ISO does differently from the stock minimal installer:
# - Console output goes to BOTH tty1 (VGA) and ttyS0 (serial) so it works in
#   VMs and headless boxes without a display.
# - On those consoles the autologin lands in a tmux split: a shell on the left,
#   a live system-info dashboard (IPs, lsblk, SSH sessions, nixos-anywhere
#   progress) on the right. See installer-console / installer-dashboard below.
# - sshd is enabled with key-only auth; schwim's pubkey from blushda is
#   embedded — `ssh schwim@<ip>` from blushda works immediately.
# - schwim has passwordless sudo (installer is ephemeral, SSH-key-protected).
# - Bundles git, vim, htop, nix-output-monitor, cryptsetup for live use.
# - Disables our home-manager baseline (no persistent /home on a live ISO).

{ config, lib, pkgs, modulesPath, ... }:
let
  adminKeys = import ../../lib/admin-keys.nix;

  # Live console dashboard + its tmux wrapper. Packaged the same way as
  # incus-launch (modules/services/incus.nix): a scripts/*.sh wrapped by
  # writeShellApplication, which runs shellcheck + `bash -n` at build time.
  installerDashboard = pkgs.writeShellApplication {
    name = "installer-dashboard";
    runtimeInputs = with pkgs; [ iproute2 util-linux procps gnugrep gawk coreutils ];
    # Display loop: a no-match grep must not abort a render frame.
    bashOptions = [ "nounset" "pipefail" ];
    # SC2009 ("use pgrep") — we grep `ps` output deliberately: we want the
    # formatted `sshd: <user>@<pty>` session line, not just the PIDs.
    excludeShellChecks = [ "SC2009" ];
    text = builtins.readFile ../../scripts/installer-dashboard.sh;
  };
  installerConsole = pkgs.writeShellApplication {
    name = "installer-console";
    runtimeInputs = [ pkgs.tmux ];
    bashOptions = [ "nounset" "pipefail" ];
    text = builtins.readFile ../../scripts/installer-console.sh;
  };
in {
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # Identity. hostId is required for ZFS to load (disko needs it during
  # installs). Any 8-hex value works — the installer never imports existing
  # pools; install-host.sh sets the *target* hostid before creating any pool.
  networking.hostName = "nixos-installer";
  networking.hostId   = "00bada55";

  # Mirror console output to both VGA and serial. The last `console=` is the
  # one systemd uses as the controlling terminal — serial wins, which is
  # what we want for headless VMs.
  boot.kernelParams = [
    "console=tty1" "console=ttyS0,115200n8"
    # IOMMU on for both CPU vendors so this ISO doubles as a GPU-passthrough /
    # VFIO test bed on any fleet host; the kernel ignores the non-matching
    # vendor's flag, and it's harmless on boxes without an IOMMU.
    "intel_iommu=on" "amd_iommu=on" "iommu=pt"
  ];

  # GPU-passthrough / reset test-bed gear (additive — the installer's normal
  # disko/nixos-anywhere flow is untouched). `vendor-reset` provides a working
  # PCI reset for AMD Polaris/Vega/Navi GPUs (the "AMD reset bug"); it is inert
  # on NVIDIA/Intel. `vfio-pci` is preloaded so any GPU can be bound to VFIO for
  # a passthrough test regardless of vendor. We deliberately set NO per-device
  # reset_method udev rule here — choose it by hand per card under test, e.g.
  #   echo device_specific > /sys/bus/pci/devices/<addr>/reset_method   # AMD Navi
  #   echo flr             > /sys/bus/pci/devices/<addr>/reset_method   # NVIDIA
  boot.extraModulePackages = [
    config.boot.kernelPackages.vendor-reset
    # Realtek RTL8811AU/8821AU USB wifi (e.g. TP-Link Archer T2U Nano, 2357:0120,
    # which is in this driver's device table). In-tree rtl8xxxu coverage of these
    # AC600/AC1200 dongles is spotty, so ship the dedicated morrownr driver; it
    # autoloads via USB modalias when the dongle is plugged in.
    config.boot.kernelPackages.rtl8821au
  ];
  boot.kernelModules        = [ "vendor-reset" "vfio-pci" ];

  # Mount/inspect installed-OS disks (Windows NTFS/exFAT, etc.). ZFS support is
  # already pulled in by the fleet boot/zfs module via mkHost.
  boot.supportedFilesystems = [ "ntfs" "exfat" ];

  # SSH: key-only. Root login is allowed by key (no password) because
  # nixos-anywhere internally pivots to `root@target` to run disko/install
  # phases — see the kexec/installer branch in nixos-anywhere.sh. Without
  # this, every non-root install fails partway through.
  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = lib.mkForce false;
    PermitRootLogin        = lib.mkForce "prohibit-password";
    KbdInteractiveAuthentication = lib.mkForce false;
  };

  # Installer is ephemeral — no signed host cert is ever staged into /etc/ssh/.
  # Opt out so sshd doesn't try to load a nonexistent HostCertificate file.
  my.services.openssh.useHostCertificate = false;

  # Authorize blushda's ed25519 key for both schwim and root.
  # - schwim:  what install-host.sh uses for its preflight (sudo for the
  #            handful of root operations).
  # - root:    what nixos-anywhere pivots to mid-install. (The installation-cd
  #            module marks the wheel group as passwordless-sudo by default;
  #            we ensure that's on.)
  users.users.schwim.openssh.authorizedKeys.keys = adminKeys;
  users.users.root.openssh.authorizedKeys.keys   = adminKeys;
  security.sudo.wheelNeedsPassword = false;

  # Turn off our fleet baselines that conflict with installer defaults:
  # - home-manager assumes a real /home (live ISO has tmpfs)
  # - networking baseline disables NetworkManager; the installer wants it on
  my.home-manager.enable = false;
  my.networking.enable   = false;

  # Extra live-environment tools beyond what minimal already includes. This ISO
  # doubles as a CLI recovery/diagnostic system, so the list is intentionally
  # broad (disk repair, network/wifi diag, filesystem + boot inspection,
  # hardware probing). All additive — none of it changes the install workflow.
  environment.systemPackages = with pkgs; [
    # live-environment basics
    git
    vim
    htop
    nix-output-monitor
    cryptsetup
    tmux
    installerDashboard
    installerConsole

    # hardware / PCI / USB inspection (also for GPU-passthrough work)
    pciutils          # lspci
    usbutils          # lsusb, lsusb -t
    lshw
    dmidecode
    hwinfo
    lsof

    # disk partition / repair / rescue
    parted
    gptfdisk          # gdisk / sgdisk
    lvm2
    mdadm
    ddrescue
    testdisk          # testdisk + photorec
    smartmontools
    nvme-cli
    hdparm

    # filesystem tooling for inspecting installed OSes
    ntfs3g
    exfatprogs
    dosfstools        # mkfs/fsck.vfat (EFI System Partitions)
    e2fsprogs
    btrfs-progs
    xfsprogs
    f2fs-tools

    # boot / installed-system inspection & repair
    efibootmgr
    os-prober

    # network + wifi diagnostics
    iw
    wirelesstools
    wpa_supplicant
    ethtool
    tcpdump
    nmap
    mtr
    traceroute
    dnsutils          # dig / nslookup
    iperf3
    socat
    curl
    wget

    # general CLI
    file
    tree
    ripgrep
    fd
    rsync
    pv
    jq
  ];

  # On the physical (tty1) and serial (ttyS0) consoles, drop the autologin
  # session straight into a tmux split: interactive shell on the left, the
  # live installer-dashboard on the right. The `$TMUX` guard stops the left
  # pane's own login shell from relaunching the console; the tty guard leaves
  # interactive `ssh schwim@…` sessions (on /dev/pts/N) at a plain prompt.
  environment.loginShellInit = ''
    if [ -z "''${TMUX:-}" ]; then
      case "$(tty)" in
        /dev/tty1|/dev/ttyS[0-9]*) installer-console ;;
      esac
    fi
  '';

  # No-op the fleet-wide initial-password-expiry activation script. On a
  # normal host that forces the admin to set a password on first login
  # (good practice); on the live installer it breaks install-host.sh,
  # because PAM treats sudo on an expired-password account as auth-failed
  # even when wheelNeedsPassword = false. The installer is ephemeral and
  # SSH-key-protected anyway — no value in expiring the throwaway initial
  # password here.
  system.activationScripts.expireSchwimInitialPassword.text = lib.mkForce "";

  # The installation-cd module sets stateVersion via the installer base; do
  # not override.
}
