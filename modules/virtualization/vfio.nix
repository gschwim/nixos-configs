# VFIO / IOMMU passthrough — reusable fleet module.
#
# Imported fleet-wide (modules/default.nix) but INERT by default: a host opts in
# with `my.virtualization.passthrough.enable = true`. Two layers:
#
#   * Base (any host): IOMMU + vfio modules. That alone makes the host capable of
#     handing a PCI device — e.g. a whole USB controller — to an Incus VM. The
#     specific device is attached at VM-create time (imperative incus), not here.
#
#   * GPU layer (only where opted in): `gpu.resetBug` wires the AMD `vendor-reset`
#     module + a udev rule so a reset-buggy GPU (Navi etc.) resets cleanly across
#     host↔VM handoffs; `gpu.switch` installs the `winvm` helper that flips a
#     single GPU between the host desktop and a passthrough VM. Both default off,
#     so GPU support is "stubbed" on every host and active only where declared.
#
# We deliberately do NOT bind anything to vfio-pci at boot: the host keeps its
# native GPU/USB drivers (so the desktop owns the GPU when no VM is running), and
# Incus binds/unbinds vfio-pci itself when the VM starts/stops.

{ config, lib, pkgs, ... }:
let
  cfg = config.my.virtualization.passthrough;
in {
  options.my.virtualization.passthrough = {
    enable = lib.mkEnableOption "IOMMU + VFIO passthrough base (USB/PCI/GPU to Incus VMs)";

    cpuVendor = lib.mkOption {
      type        = lib.types.enum [ "amd" "intel" ];
      example     = "amd";
      description = "Host CPU vendor — selects the `amd_iommu=on` / `intel_iommu=on` kernel param.";
    };

    hugepages = lib.mkOption {
      type        = lib.types.nullOr lib.types.str;
      default     = null;
      example     = "16G";
      description = ''
        If set (whole gigabytes, e.g. "16G"), reserve that many 1 GiB hugepages at
        boot for low-jitter VM memory. The pages are then unavailable to the host,
        so size this below installed RAM. Use them by setting
        `limits.memory.hugepages=true` on the Incus VM (or its profile).
      '';
    };

    gpu = {
      resetBug = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = ''
          Enable AMD `vendor-reset` + a udev rule that sets
          `reset_method=device_specific` on AMD display controllers (PCI class
          0x030000, vendor 0x1002). Required for reset-buggy cards (Polaris/Vega/
          Navi) to reset cleanly when handed back and forth between host and guest.
          Inert on NVIDIA/Intel hosts.
        '';
      };

      switch = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = ''
          Install the `winvm` helper for single-GPU host↔VM switching on a desktop
          host: it stops the display-manager (clean GNOME logout) to free the GPU,
          starts the passthrough VM, and reverses on stop. Drive it over SSH or a
          keybind — never from a terminal inside the session it tears down.
        '';
      };

      instance = lib.mkOption {
        type        = lib.types.str;
        default     = "win";
        description = "Name of the Incus VM `winvm` drives by default.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ── Base: IOMMU + vfio (enables any USB/PCI/GPU passthrough on this host) ──
    {
      boot.kernelParams  = [ "${cfg.cpuVendor}_iommu=on" "iommu=pt" ];
      boot.kernelModules = [ "vfio_pci" "vfio_iommu_type1" "vfio" ];
    }

    # ── Hugepages (optional) — reserve N × 1 GiB pages ──
    (lib.mkIf (cfg.hugepages != null) {
      boot.kernelParams = [
        "default_hugepagesz=1G" "hugepagesz=1G"
        "hugepages=${lib.removeSuffix "G" cfg.hugepages}"
      ];
    })

    # ── GPU reset bug (AMD) — vendor-reset + device_specific reset method ──
    (lib.mkIf cfg.gpu.resetBug {
      boot.extraModulePackages = [ config.boot.kernelPackages.vendor-reset ];
      boot.kernelModules       = [ "vendor-reset" ];
      # Match only AMD VGA controllers (not the HDMI-audio function) so the
      # device-specific reset is applied exactly where vendor-reset can service it.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x030000", ATTR{vendor}=="0x1002", ATTR{reset_method}="device_specific"
      '';
    })

    # ── Single-GPU switch helper ──
    (lib.mkIf cfg.gpu.switch {
      environment.systemPackages = [
        (pkgs.writeShellApplication {
          name = "winvm";
          runtimeInputs = with pkgs; [ incus systemd coreutils ];
          # Inject the configured default instance name ahead of the script body.
          text = ''
            WINVM_INSTANCE="''${WINVM_INSTANCE:-${cfg.gpu.instance}}"
          '' + builtins.readFile ../../scripts/winvm.sh;
        })
      ];
    })
  ]);
}
