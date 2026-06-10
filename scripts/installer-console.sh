#!/usr/bin/env bash
# installer-console — console UX for the install ISO.
#
# Launches a tmux session split vertically: an interactive shell (the CLI) on
# the LEFT, the live installer-dashboard on the RIGHT. Auto-started on the
# physical/serial console by environment.loginShellInit (see hosts/installer);
# also runnable by hand to rebuild the layout after closing it.
#
# errexit stays off (nounset + pipefail on) so a failed `has-session` probe
# doesn't abort the launcher.

SESSION=installer

# Already inside tmux? Do nothing — avoids the left pane's own login shell
# recursively relaunching the console.
if [ -n "${TMUX:-}" ]; then
  exit 0
fi

# Session already running (e.g. detached): just reattach.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  exec tmux attach -t "$SESSION"
fi

# Work around the Linux VGA/framebuffer console handing tmux a stale 80x24 size
# at attach: tmux only adopts the real size when it gets a SIGWINCH, which on
# this console doesn't arrive until the first keystroke — so the window stays
# small and wrapping until you type. `tput` already reports the correct size,
# so the dimensions ARE known to the kernel; tmux just needs a nudge to re-read
# them.
#
# We `exec` into tmux below, so the tmux CLIENT inherits this process's PID
# ($$). Fork a watcher first that sends that client a few SIGWINCHes once the
# console has settled; tmux re-reads the (correct) size and resizes itself, no
# keypress needed. A SIGWINCH when the size is already right is a harmless
# redraw, and the watcher exits early once tmux is gone.
self=$$
(
  for delay in 0.2 0.5 1 2; do
    sleep "$delay"
    kill -WINCH "$self" 2>/dev/null || exit 0
  done
) &

# Attached new-session (no `-d`): the initial pane is a login shell = the
# LEFT/CLI pane. `split-window -h -d` adds the dashboard on the RIGHT without
# stealing focus, so the operator lands on the left pane.
exec tmux new-session -s "$SESSION" \; \
  split-window -h -d -l 50% installer-dashboard
