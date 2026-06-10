#!/usr/bin/env bash
# installer-dashboard — live console overview for the install ISO.
#
# Two modes (single self-invoking binary):
#   (no args)   exec `watch`, which re-runs this script in --render mode every
#               few seconds. This is the entry point used by the tmux console.
#   --render    print one snapshot. Called by `watch`.
#
# Shows, top to bottom:
#   - host / time / uptime header
#   - IP summary of every interface
#   - block devices (lsblk)
#   - connected SSH sessions and what each is doing
#   - nixos-anywhere install status (derived from observable signals)
#
# Packaged via writeShellApplication with errexit OFF (it's a display loop — a
# no-match grep must not abort a frame); nounset + pipefail stay on.

INTERVAL="${INSTALLER_DASHBOARD_INTERVAL:-2}"

# ANSI: bold/cyan section headers, dim for empty states. `watch --color` passes
# these through.
B=$'\033[1m'; C=$'\033[36m'; D=$'\033[2m'; Y=$'\033[33m'; G=$'\033[32m'; R=$'\033[0m'

hdr() { printf '%s== %s ==%s\n' "$C$B" "$1" "$R"; }
none() { printf '  %s(none)%s\n' "$D" "$R"; }

section_network() {
  hdr "NETWORK"
  ip -brief addr show 2>/dev/null | awk '{print "  " $0}'
}

section_blockdev() {
  hdr "BLOCK DEVICES"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null | awk '{print "  " $0}'
}

section_ssh() {
  hdr "SSH SESSIONS"
  local conns
  conns=$(ss -tnH state established '( sport = :22 )' 2>/dev/null || true)
  if [ -n "$conns" ]; then
    printf '%s\n' "$conns" | awk '{print "  conn " $0}'
  else
    none
  fi
  printf '  %sactivity:%s\n' "$D" "$R"
  # sshd labels each session process `sshd: <user>@<pty|notty>`. nixos-anywhere
  # connects as root non-interactively, so it shows as `sshd: root@notty` here
  # even though `who`/`w` (utmp) never see it.
  local procs
  procs=$(ps -eo user=,pid=,etime=,args= 2>/dev/null \
            | grep -E 'sshd: |nixos-install|nixos-anywhere|disko|nixos-rebuild' \
            | grep -v 'grep' || true)
  if [ -n "$procs" ]; then
    printf '%s\n' "$procs" | awk '{print "    " $0}'
  else
    none
  fi
}

section_install() {
  hdr "INSTALL STATUS (nixos-anywhere)"
  local phase color
  if pgrep -f 'nixos-install' >/dev/null 2>&1; then
    phase="in progress (nixos-install)"; color=$Y
  elif pgrep -f 'disko' >/dev/null 2>&1; then
    phase="in progress (disko partitioning)"; color=$Y
  elif pgrep -f 'kexec' >/dev/null 2>&1; then
    phase="in progress (kexec pivot)"; color=$Y
  elif mount 2>/dev/null | grep -qE ' on /mnt'; then
    phase="target mounted at /mnt (install staged)"; color=$Y
  else
    phase="idle — no nixos-anywhere activity detected"; color=$D
  fi
  printf '  %s%s%s\n' "$color" "$phase" "$R"

  # /mnt mounts, if any (disko mounts the target system here).
  local mnt
  mnt=$(mount 2>/dev/null | grep -E ' on /mnt' || true)
  if [ -n "$mnt" ]; then
    printf '  %smounts:%s\n' "$D" "$R"
    printf '%s\n' "$mnt" | awk '{print "    " $1 " -> " $3}'
  fi

  # ZFS pools, only if the tooling is present on the live system.
  if command -v zpool >/dev/null 2>&1; then
    local pools
    pools=$(zpool list -H -o name,size,health 2>/dev/null || true)
    if [ -n "$pools" ]; then
      printf '  %spools:%s\n' "$D" "$R"
      printf '%s\n' "$pools" | awk '{print "    " $0}'
    fi
  fi
}

render() {
  local up
  up=$(uptime -p 2>/dev/null || echo '?'); up=${up#up }
  printf '%s%s%s   %s   up %s\n' \
    "$G$B" "$(hostname 2>/dev/null || echo installer)" "$R" \
    "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
    "$up"
  echo
  section_network; echo
  section_blockdev; echo
  section_ssh; echo
  section_install
}

case "${1:-}" in
  --render) render ;;
  *)        exec watch --color --no-title --interval "$INTERVAL" -- "$0" --render ;;
esac
