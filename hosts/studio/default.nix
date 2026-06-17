{ config, inputs, ... }:
{
  imports = [
    # Hardware module from nixos-hardware, if applicable. Examples:
    #   inputs.nixos-hardware.nixosModules.common-cpu-amd
    #   inputs.nixos-hardware.nixosModules.common-gpu-amd
    ./hardware-configuration.nix
  ];

  networking.hostName = "studio";
  networking.hostId   = "964bcb98";          # 8-hex, unique per host (ZFS)
  time.timeZone       = "America/Phoenix";

  # A normal GNOME desktop that also runs Incus + GPU/USB passthrough for a
  # switchable Windows VM. See the passthrough block + winvm below.
  my.host.role = "desktop";

  # Desktop role leaves sleep ON by default, but studio is an always-on VM host
  # we drive remotely — keep it awake (masks systemd sleep targets, logind idle
  # actions, AND GNOME's idle-suspend; see modules/power/prevent-sleep.nix).
  my.power.preventSleep.enable = true;

  my.disko = {
    enable   = true;
    # CONFIRM at install with `lsblk`. The box's lone NVMe in Phase 0 was the
    # WD Black SN720 (01:00.0) → /dev/nvme0n1; verify it's the intended target
    # (and not the installer USB) before running disko — it gets wiped.
    disk     = "/dev/nvme0n1";
    swapSize = "8G";
  };

  # ── Networking: WiFi via NetworkManager ──────────────────────────────────
  # studio's uplink is a USB WiFi adapter (wlp4s0f1u1). A WiFi STA can't be
  # bridged or VLAN-trunked, so this host can't carry the fleet L2 bridges
  # (users1/infra100/cloud104) — instances use incusbr0 (NAT) for now. GNOME
  # uses NetworkManager; the shared "Canis Major" profile
  # (modules/networking/wifi-profiles.nix) is auto-installed from wifi-secrets.age
  # — we only override it here to pin a static IP.
  my.networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles."canis-major".ipv4 = {
    method   = "manual";
    address1 = "172.16.1.247/24,172.16.1.254";
    dns      = "172.16.1.253;";
  };

  # Host WiFi dongle driver. wlp4s0f1u1 sits on USB controller 04:00.1 (NOT the
  # passed-through 0b:00.3), so the host keeps WiFi while the VM owns its USB
  # controller. Assuming the TP-Link Realtek (rtl8821au, as on the recovery
  # ISO) — confirm with `lsusb` on the box and adjust if it's a different chip.
  boot.extraModulePackages = [ config.boot.kernelPackages.rtl8821au ];

  # ── Incus host (NAT only for now; no L2 bridges over WiFi) ────────────────
  my.services.incus.enable         = true;
  my.services.incus.cluster.enable = false;
  # No infra100Trunk/cloud104Trunk and no users1 bridge: impossible over WiFi.
  # The Windows VM attaches to incusbr0 (NAT) — see the VM recipe (Phase 3).

  # ── GPU + USB passthrough for the switchable Windows VM ───────────────────
  my.virtualization.passthrough = {
    enable    = true;
    cpuVendor = "amd";
    gpu = {
      resetBug = true;   # Navi 10 reset bug → vendor-reset (validated 10/10 cycles)
      switch   = true;   # install `winvm` (stops GNOME → starts VM, and reverse)
    };
    # hugepages left off: don't permanently reserve RAM on a desktop. Enable
    # later (e.g. "16G") if DAW latency needs it — the VM also needs
    # limits.memory.hugepages set on its profile.
  };
  # Passthrough device addresses for the Windows VM (attach at VM-create, Phase 3):
  #   GPU VGA    0000:09:00.0
  #   GPU audio  0000:09:00.1
  #   USB ctrl   0000:0b:00.3   (isolated group; DAW interface / MIDI / keyboard / mouse)

  my.desktop.gnome.enable = true;
  my.services.xrdp.enable = true;

  # ── STAGED: switch to wired + L2 bridging once studio is on ethernet ──────
  # When wired, comment out the NetworkManager static override above and enable
  # the wired-NIC bridge + VLAN trunks (mirrors iris/pleiades), then attach the
  # Windows VM to `net-users1` instead of incusbr0 for true L2 on users1:
  #
  #   my.network.static = {
  #     enable = true; interface = "<wired-nic>"; bridge = "users1";
  #     address = "172.16.1.247"; prefixLength = 24;
  #     gateway = "172.16.1.254"; nameservers = [ "172.16.1.253" ];
  #   };
  #   networking.vlans."<wired-nic>.100" = { id = 100; interface = "<wired-nic>"; };
  #   networking.vlans."<wired-nic>.104" = { id = 104; interface = "<wired-nic>"; };
  #   my.services.incus.infra100Trunk = "<wired-nic>.100";
  #   my.services.incus.cloud104Trunk = "<wired-nic>.104";
  #   my.networking.networkmanager.unmanaged = [
  #     "interface-name:<wired-nic>" "interface-name:<wired-nic>.100" "interface-name:<wired-nic>.104"
  #   ];

  system.stateVersion = "25.11";
}
