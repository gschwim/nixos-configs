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

# new-session's initial pane is a login shell — that's the left/CLI pane.
tmux new-session -d -s "$SESSION"
# Split side-by-side (-h); the new (right) pane runs the dashboard.
tmux split-window -h -l 50% -t "$SESSION" 'installer-dashboard'
# Land the operator on the left/CLI pane.
tmux select-pane -L -t "$SESSION"
exec tmux attach -t "$SESSION"
