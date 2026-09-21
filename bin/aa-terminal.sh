#!/usr/bin/env bash
# The command ttyd runs for the web UI's terminal pane: one tmux session per topic.
#
# ttyd is started with `--url-arg`, so the browser's `?arg=<topic id>` arrives here as $1.
# The daemon has already checked it against its topic store before proxying — this is the
# second check, on the side where the string actually reaches an exec.
#
# Why tmux at all: ttyd forks a fresh process per WebSocket connection and SIGHUPs it on
# disconnect. Without a session holding the terminal, switching apps on a phone would kill
# whatever was running in it. With one, a drop is a redraw — and the same topic opened from a
# laptop and a phone is the same screen.
#
# You do not run this by hand; entrypoint.sh points ttyd at it.

set -uo pipefail

TOPIC="${1:-}"

# Exactly what TopicStore mints: eight lowercase hex characters. Anything else is not a topic
# id, and the only ways to produce one are a bug in the page or a hand-made request.
if ! [[ "$TOPIC" =~ ^[0-9a-f]{8}$ ]]; then
    echo "aa-terminal: refusing to start — '$TOPIC' is not a topic id" >&2
    exit 64
fi

# A tmux server of its own (-L), NOT the default one. The agent-anywhere daemon is supervised
# in a session on the default server, and a `set -g` in the config below would otherwise reach
# it. Separate server, separate blast radius.
exec tmux -L aa-web -f /usr/local/etc/aa-terminal.tmux.conf new -A -s "aa-${TOPIC}"
