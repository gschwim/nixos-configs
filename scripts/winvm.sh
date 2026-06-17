# winvm — single-GPU host<->VM switch for a GNOME desktop host.
#
# Flips one physical GPU between the host desktop and an Incus passthrough VM:
#   start: stop the display-manager (a clean GNOME logout) to free the GPU, then
#          start the VM -- Incus binds the GPU/USB to vfio-pci itself.
#   stop:  stop the VM (Incus rebinds the host driver; vendor-reset resets the
#          GPU) and bring the display-manager back for a fresh login.
#
# Drive this over SSH or a keybind -- NOT from a terminal inside the GNOME session
# it tears down. The default VM name is injected by the module
# (my.virtualization.passthrough.gpu.instance); override via arg or $WINVM_INSTANCE.
#
# Usage: winvm {start|stop|status} [instance]

INSTANCE="${WINVM_INSTANCE:-win}"
DM="display-manager.service"

[ -n "${2:-}" ] && INSTANCE="$2"

case "${1:-}" in
  start)
    echo "winvm: stopping ${DM} (GNOME session will end)..."
    systemctl stop "$DM"
    echo "winvm: starting Incus VM '${INSTANCE}' (GPU -> vfio-pci)..."
    incus start "$INSTANCE"
    echo "winvm: '${INSTANCE}' up -- display is on the GPU's HDMI now."
    ;;
  stop)
    echo "winvm: stopping Incus VM '${INSTANCE}'..."
    incus stop "$INSTANCE" || true
    echo "winvm: restarting ${DM} (host desktop returns)..."
    systemctl start "$DM"
    ;;
  status)
    incus list "$INSTANCE" || true
    if systemctl is-active --quiet "$DM"; then
      echo "display-manager: active (host owns the GPU)"
    else
      echo "display-manager: inactive (a VM may own the GPU)"
    fi
    ;;
  *)
    echo "usage: winvm {start|stop|status} [instance]" >&2
    exit 2
    ;;
esac
