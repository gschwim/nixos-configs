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

# Create the session ATTACHED in a single invocation (no `-d`), then split.
#
# Why not new-session -d + attach: a detached session has no client to size
# against, so tmux lays it out at the default 80x24; the later `attach` only
# adopts the real console size on the first SIGWINCH (your first keystroke) —
# hence the small, wrapping window until you type. Attaching directly makes
# tmux read the true terminal size up front, exactly like a normal `tmux`
# launch, which is why an interactive tmux never shows this glitch.
#
# The initial pane is a login shell = the LEFT/CLI pane. `split-window -h -d`
# adds the dashboard to the RIGHT without stealing focus (`-d`), so the
# operator lands on the left pane.
exec tmux new-session -s "$SESSION" \; \
  split-window -h -d -l 50% installer-dashboard
