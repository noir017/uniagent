#!/usr/bin/env bash
# talkcode keep-alive daemon (container edition).
#
# This host is a Docker container whose PID 1 is Teleport, so there is no
# systemd and no per-user service manager. This script is the stand-in: it
# runs the talkcode daemon in a dedicated tmux session and restarts it
# if it dies, with backoff so a hard-failing daemon cannot hammer the
# Telegram API.
#
# Start:   bash /usr/local/bin/talkcode-daemon.sh start
# Stop:    bash /usr/local/bin/talkcode-daemon.sh stop
# Status:  bash /usr/local/bin/talkcode-daemon.sh status
# Logs:    tail -f ~/.config/talkcode/daemon.log
#
# You normally do not run `start` by hand: entrypoint.sh calls it on container
# startup whenever ~/.config/talkcode/config.yaml exists, so a rebuild
# comes back up on its own. Use `stop`/`start` here for a manual restart after
# editing the config.

set -uo pipefail

DAEMON_SESSION="talkcode-daemon"
APP_DIR="$HOME/.config/talkcode"
LOG="$APP_DIR/daemon.log"

# The binary baked into the image. Overridable so a private build can be tried
# without rebuilding the image:  TALKCODE_BIN=~/.local/bin/talkcode ...
# Note that $HOME/.local/bin comes FIRST in PATH, so a leftover install there
# would win for anything resolving by name — this script deliberately does not,
# which is why the override has to be explicit.
BIN="${TALKCODE_BIN:-/usr/bin/talkcode}"

# Absolute path to this script: _supervise re-invokes it inside tmux, where the
# caller's cwd no longer applies.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Match the supervised process by its FULL path. A bare "talkcode start"
# pattern also matches the ssh/bash command line that invokes this script, so
# pgrep/pkill would find itself and (worse) kill the calling shell.
PATTERN="$BIN start"

# The claude harness runs the Claude Code CLI through the Agent SDK, and the SDK
# ships its own ~222 MB copy of that CLI as optional deps. agents/talkcode.sh
# installs without them (the global `claude` is the same binary — verified with
# cmp at 2.1.280), so the SDK has to be told where the one that is left lives;
# without this every cc turn fails with "Claude native binary not found".
# Only set when the file is really there: pointing the SDK at a missing path
# would turn a clear error into a confusing ENOENT. An explicit value wins.
CLAUDE_GLOBAL_EXE="/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
if [ -z "${CLAUDE_CODE_EXECUTABLE:-}" ] && [ -x "$CLAUDE_GLOBAL_EXE" ]; then
    export CLAUDE_CODE_EXECUTABLE="$CLAUDE_GLOBAL_EXE"
fi

MIN_BACKOFF=5
MAX_BACKOFF=300

# One-time move from the project's old name (agent-anywhere, renamed to talkcode
# in 2.0.0, 2026-10-10). talkcode deliberately reads nothing under the old
# names, so the state this deployment has built up — config.yaml, .env,
# conversations, web UI topics, scheduled tasks — has to be carried across once,
# before the daemon first looks for it. entrypoint.sh calls this ahead of its
# "is there a config?" check, as the user: run as root, the sed below would
# leave a root-owned 0600 config.yaml the daemon cannot read.
#
# COPY, not move: the old directory stays exactly as it was, so pinning the
# previous image (which knows only the old path) still finds everything. It
# runs only while the new directory does not exist, so it happens once; state
# written under the old name after that (a rollback period) is not merged back.
#
# Safe to delete, with the entrypoint call, once no image older than 2.0.0
# could be started on this home again.
_migrate_from_agent_anywhere() {
    local old="$HOME/.config/agent-anywhere" new="$APP_DIR"
    if [ -f "$old/config.yaml" ] && [ ! -e "$new" ]; then
        rm -rf "$new.migrating"
        if ! cp -a "$old" "$new.migrating"; then
            rm -rf "$new.migrating"
            echo "migrate: could not copy $old to $new — talkcode will not find its config" >&2
            return 1
        fi
        # Sockets are recreated by whoever listens on them; the old reverse-CLI
        # shim execs /usr/bin/agent-anywhere, which this image does not have, and
        # this directory's bin/ leads every agent's PATH.
        rm -f "$new.migrating"/*.sock "$new.migrating/bin/agent-anywhere"
        # Absolute paths into the config dir (the web terminal's socket is the
        # one in use). Only the path form: a workdir under some
        # ~/workspace/agent-anywhere checkout must keep pointing there.
        sed -i 's#/\.config/agent-anywhere/#/.config/talkcode/#g' "$new.migrating/config.yaml"
        mv "$new.migrating" "$new"
        echo "migrate: copied $old to $new (the old directory is left in place)"
    fi
    if [ -d "$HOME/.agent-anywhere" ] && [ ! -e "$HOME/.talkcode" ]; then
        cp -a "$HOME/.agent-anywhere" "$HOME/.talkcode" \
            && echo "migrate: copied ~/.agent-anywhere to ~/.talkcode"
    fi
    # The skill links the old daemon made point into the old install path,
    # which no longer exists in this image. Only a DANGLING link is removed:
    # anything else by that name is not ours to touch.
    local link
    for link in "$HOME/.claude/skills/agent-anywhere" "$HOME/.agents/skills/agent-anywhere"; do
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            rm -f "$link" && echo "migrate: removed the stale skill link $link"
        fi
    done
    return 0
}

_supervise() {
    mkdir -p "$APP_DIR"
    local backoff=$MIN_BACKOFF
    while true; do
        echo "[$(date -Is)] starting talkcode" >> "$LOG"
        local start_ts=$SECONDS
        "$BIN" start >> "$LOG" 2>&1
        local rc=$?
        local ran=$(( SECONDS - start_ts ))
        echo "[$(date -Is)] talkcode exited rc=$rc after ${ran}s" >> "$LOG"

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
            echo "error: a talkcode daemon is already polling this token" >&2
            echo "       stop it first:  $SELF stop" >&2
            exit 1
        fi
        mkdir -p "$APP_DIR"
        # Unix sockets bind by pathname: an existing FILE makes bind() fail with
        # EADDRINUSE even when nobody is listening. The socket lives in the bind
        # mount, so a container rebuild always leaves the previous one behind and
        # every boot logged `[ipc] server error: listen EADDRINUSE`. The daemon
        # recovers on its own, but a "server error" on every single startup is
        # exactly the kind of noise that sends someone debugging a healthy IPC.
        # Safe here: both checks above already established no daemon is running.
        rm -f "$APP_DIR/daemon.sock"
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
        pkill -f "talkcode/node_modules/@anthropic-ai/claude-agent-sdk" 2>/dev/null \
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
    migrate-from-agent-anywhere)
        _migrate_from_agent_anywhere
        ;;
    *)
        echo "usage: $0 {start|stop|status|migrate-from-agent-anywhere}" >&2
        exit 2
        ;;
esac
