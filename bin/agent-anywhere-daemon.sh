#!/usr/bin/env bash
# agent-anywhere keep-alive daemon (container edition).
#
# This host is a Docker container whose PID 1 is Teleport, so there is no
# systemd and no per-user service manager. This script is the stand-in: it
# runs the agent-anywhere daemon in a dedicated tmux session and restarts it
# if it dies, with backoff so a hard-failing daemon cannot hammer the
# Telegram API.
#
# Start:   bash /usr/local/bin/agent-anywhere-daemon.sh start
# Stop:    bash /usr/local/bin/agent-anywhere-daemon.sh stop
# Status:  bash /usr/local/bin/agent-anywhere-daemon.sh status
# Logs:    tail -f ~/.config/agent-anywhere/daemon.log
#
# You normally do not run `start` by hand: entrypoint.sh calls it on container
# startup whenever ~/.config/agent-anywhere/config.yaml exists, so a rebuild
# comes back up on its own. Use `stop`/`start` here for a manual restart after
# editing the config.

set -uo pipefail

DAEMON_SESSION="agent-anywhere-daemon"
APP_DIR="$HOME/.config/agent-anywhere"
LOG="$APP_DIR/daemon.log"

# The binary baked into the image. Overridable so a private build can be tried
# without rebuilding the image:  AGENT_ANYWHERE_BIN=~/.local/bin/agent-anywhere ...
# Note that $HOME/.local/bin comes FIRST in PATH, so a leftover install there
# would win for anything resolving by name — this script deliberately does not,
# which is why the override has to be explicit.
BIN="${AGENT_ANYWHERE_BIN:-/usr/bin/agent-anywhere}"

# Absolute path to this script: _supervise re-invokes it inside tmux, where the
# caller's cwd no longer applies.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Match the supervised process by its FULL path. A bare "agent-anywhere start"
# pattern also matches the ssh/bash command line that invokes this script, so
# pgrep/pkill would find itself and (worse) kill the calling shell.
PATTERN="$BIN start"

MIN_BACKOFF=5
MAX_BACKOFF=300

_supervise() {
    mkdir -p "$APP_DIR"
    local backoff=$MIN_BACKOFF
    while true; do
        echo "[$(date -Is)] starting agent-anywhere" >> "$LOG"
        local start_ts=$SECONDS
        "$BIN" start >> "$LOG" 2>&1
        local rc=$?
        local ran=$(( SECONDS - start_ts ))
        echo "[$(date -Is)] agent-anywhere exited rc=$rc after ${ran}s" >> "$LOG"

        # A run that lasted a while is a healthy process that happened to die —
        # reset the backoff. A run that died immediately is a config or auth
        # failure; escalate the wait so we do not spin.
        if (( ran >= 60 )); then
            backoff=$MIN_BACKOFF
        else
            backoff=$(( backoff * 2 ))
            (( backoff > MAX_BACKOFF )) && backoff=$MAX_BACKOFF
        fi
        echo "[$(date -Is)] restarting in ${backoff}s" >> "$LOG"
        sleep "$backoff"
    done
}

case "${1:-}" in
    start)
        if tmux has-session -t "$DAEMON_SESSION" 2>/dev/null; then
            echo "already running (tmux session $DAEMON_SESSION)"
            exit 0
        fi
        [ -x "$BIN" ] || { echo "error: $BIN not found or not executable" >&2; exit 1; }
        [ -f "$APP_DIR/config.yaml" ] || { echo "error: $APP_DIR/config.yaml missing" >&2; exit 1; }
        # config.yaml references ${TELEGRAM_BOT_TOKEN} from the .env sidecar.
        # An absent or empty value only fails at connect time, so check here.
        if ! grep -qE "^[[:space:]]*TELEGRAM_BOT_TOKEN=[^[:space:]]" "$APP_DIR/.env" 2>/dev/null; then
            echo "error: TELEGRAM_BOT_TOKEN is missing or empty in $APP_DIR/.env" >&2
            exit 1
        fi
        # The bot token is single-consumer: two pollers on one token race for
        # every message and each sees a random half. The tmux-session check above
        # covers the daemon started this way; this catches one started by hand.
        if pgrep -f "$PATTERN" >/dev/null 2>&1; then
            echo "error: an agent-anywhere daemon is already polling this token" >&2
            echo "       stop it first:  $SELF stop" >&2
            exit 1
        fi
        mkdir -p "$APP_DIR"
        tmux new-session -d -s "$DAEMON_SESSION" "bash $SELF _supervise"
        echo "started (tmux session $DAEMON_SESSION); logs: $LOG"
        ;;
    stop)
        tmux kill-session -t "$DAEMON_SESSION" 2>/dev/null \
            && echo "stopped" || echo "not running"
        # The supervised child dies with the session, but make sure no orphan
        # survives — it would keep polling the same bot token.
        pkill -f "$PATTERN" 2>/dev/null && echo "killed leftover daemon process" || true
        # Agent subprocesses are children of the daemon; a SIGKILLed daemon can
        # orphan them. They hold no token, but they do hold API sessions.
        pkill -f "claude-agent-acp" 2>/dev/null && echo "killed orphan claude agent" || true
        pkill -f "opencode acp" 2>/dev/null && echo "killed orphan opencode agent" || true
        # Killing the ACP wrapper does NOT take its own child with it: the
        # claude-agent-sdk binary keeps running (observed surviving a clean stop,
        # ~170MB and a live API session each). Matched by its path INSIDE the
        # gateway's dependency tree, so this can never hit the interactive
        # `claude` CLI — that one is /usr/lib/node_modules/@anthropic-ai/claude-code.
        pkill -f "agent-anywhere-cli/node_modules/@anthropic-ai/claude-agent-sdk" 2>/dev/null \
            && echo "killed orphan claude-agent-sdk process" || true
        ;;
    status)
        if tmux has-session -t "$DAEMON_SESSION" 2>/dev/null; then
            echo "daemon: RUNNING (tmux $DAEMON_SESSION)"
        else
            echo "daemon: STOPPED"
        fi
        pgrep -f "$PATTERN" >/dev/null && echo "daemon process: UP" || echo "daemon process: DOWN"
        echo "binary: $BIN"
        ;;
    _supervise)
        _supervise
        ;;
    *)
        echo "usage: $0 {start|stop|status}" >&2
        exit 2
        ;;
esac
