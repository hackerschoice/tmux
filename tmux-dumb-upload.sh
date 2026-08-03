#!/usr/bin/env bash
#
# This only works when the remote shell is a "dumb" shell (not a tty).
#
# Upload a local file into a remote shell reachable through a tmux pane, by
# injecting it as raw pty input (tmux load-buffer/paste-buffer) rather than
# any network transfer. This automates the procedure worked out by hand:
#
#   1. Queue `dd of=<remote-path> bs=1 count=<exact-size>` in the pane while
#      it is still in normal cooked mode (so the command line itself, sent
#      via a plain Enter, is typed/executed normally).
#   2. Only once dd is blocked reading, switch the pane's pty to raw mode
#      (stty raw -echo) -- this must happen AFTER the dd command is queued,
#      and only once, since re-launching a job under a job-control shell
#      (zsh/bash) can silently force isig back on.
#   3. Inject the file's raw bytes with `tmux load-buffer` + `paste-buffer`,
#      which writes them to the pane's pty with no key/text interpretation.
#   4. Poll for completion using a marked query sent with literal keys and a
#      literal C-j (raw mode does not translate \r to \n, so a normal Enter
#      would not submit a command line to a non-tty reader on the far end).
#   5. Only restore the pty's original settings once `ls -la` on the far end
#      confirms the file landed at exactly the expected byte count --
#      restoring too early can let a stray control byte still sitting in the
#      kernel's pty queue be reinterpreted as a signal once isig comes back
#      on.
#
# Must be run on the host where the target tmux server lives (tmux commands
# operate against panes of the local tmux server only).
#
# Usage:
#   tmux-upload.sh [options] <tmux-target> <local-file> [remote-path]
#
# Options:
#   -x, --chmod-exec       chmod +x the remote file after a verified upload
#   -t, --timeout SECONDS  max time to wait for the transfer to complete
#                          (default: 120)
#   -i, --poll-interval S  seconds between completion polls (default: 2)
#   -q, --quiet            suppress progress output on stderr
#
# Example:
#   tmux-upload.sh exp55 ~/warez/proxy/socks5 /tmp/socks5
#   tmux-upload.sh -x exp55 ~/warez/proxy/socks5

set -euo pipefail

TIMEOUT=120
POLL_INTERVAL=2
CHMOD_EXEC=0
QUIET=0

log() {
    if [ "$QUIET" -eq 0 ]; then
        printf '%s\n' "$*" >&2
    fi
}

die() {
    printf 'tmux-upload: %s\n' "$*" >&2
    exit 1
}

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -x|--chmod-exec) CHMOD_EXEC=1; shift ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        -i|--poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done

[ $# -ge 2 ] || usage 1
TARGET=$1
LOCAL_FILE=$2
REMOTE_PATH=${3:-"$(basename "$LOCAL_FILE")"}

command -v tmux >/dev/null 2>&1 || die "tmux not found"
command -v stty >/dev/null 2>&1 || die "stty not found"
[ -f "$LOCAL_FILE" ] || die "local file not found: $LOCAL_FILE"

tmux has-session -t "$TARGET" 2>/dev/null || die "no such tmux target: $TARGET"
PTY=$(tmux display-message -p -t "$TARGET" '#{pane_tty}') \
    || die "could not resolve pane tty for target: $TARGET"
[ -c "$PTY" ] || die "resolved pty is not a character device: $PTY"

SIZE=$(wc -c < "$LOCAL_FILE" | tr -d ' ')
[ "$SIZE" -gt 0 ] || die "local file is empty: $LOCAL_FILE"

MARKER="TMUXUP_$$_$RANDOM"
BUFNAME="tmuxup_$$"

SAVED_STTY=$(stty -F "$PTY" -g)
RESTORED=0
restore_stty() {
    if [ "$RESTORED" -eq 0 ]; then
        stty -F "$PTY" "$SAVED_STTY" 2>/dev/null || true
        RESTORED=1
    fi
}
trap restore_stty EXIT INT TERM

log "==> target=$TARGET pty=$PTY file=$LOCAL_FILE ($SIZE bytes) -> $REMOTE_PATH"

log "-- queuing receiver (cooked mode)"
# The trailing echo only runs if dd's command *exits* -- and since we
# haven't sent it any data yet, dd cannot have legitimately finished; the
# only way it exits at this point is a failure to open $REMOTE_PATH (bad
# parent dir, permission, etc.), meaning it was never actually blocked
# reading at all. Without this check, proceeding straight to raw-mode+
# paste would deliver the entire binary payload as literal shell command
# input instead of dd's stdin -- confirmed this is not theoretical: it
# crashed a whole tmux server in testing.
#
# A bare presence check of the marker text is not enough to tell "typed"
# from "ran": confirmed directly against the real target that its shell
# (interactive but with no controlling tty, reached through poc.py's
# relay) self-echoes whatever it reads as part of staying interactive
# without a tty, and the relay forwards that to local stdout regardless
# of any local pty echo setting -- so the marker text as written in the
# command source appears immediately either way. The fix: append \$\$
# (literal, unexpanded when WE send it) so the shell only produces a
# numeric-suffixed marker when it actually *executes* the echo -- shell
# parameter expansion happens at execution time, never as part of just
# echoing back raw input text. Search for the numeric form specifically;
# it cannot come from anything but real execution, regardless of whether
# the target shell echoes input, doesn't, or does something else.
tmux send-keys -t "$TARGET" \
    "dd of=$REMOTE_PATH bs=1 count=$SIZE 2>/dev/null; echo \"${MARKER}_RECEIVER_EXITED_\$\$\"" Enter

PREFLIGHT_FAILED=0
for _ in 1 2 3 4 5 6; do
    sleep 0.5
    if tmux capture-pane -t "$TARGET" -p -S -20 | tr -d '\n' \
            | grep -Eq "${MARKER}_RECEIVER_EXITED_[0-9]+"; then
        PREFLIGHT_FAILED=1
        break
    fi
done
if [ "$PREFLIGHT_FAILED" -eq 1 ]; then
    die "receiver command exited before any data was sent -- check that $(dirname "$REMOTE_PATH") exists and is writable on the target"
fi

log "-- switching pty to raw mode"
# -iexten matters beyond cosmetics: GNU stty's "raw" macro does not clear it,
# and on a BSD/XNU pty (macOS) the kernel still honors iexten-gated extended
# processing (e.g. lnext/^V "quote next character") even with -icanon set,
# silently eating a byte out of the stream. Linux does not do this (verified
# clean transfers on the real target with iexten left on), but there's no
# reason not to disable it everywhere for safety.
stty -F "$PTY" raw -echo -iexten

log "-- injecting $SIZE bytes"
tmux load-buffer -b "$BUFNAME" "$LOCAL_FILE"
# -r is required: without it tmux silently rewrites every LF (0x0a) byte in
# the buffer to CR (0x0d) before pasting (its default "paste text" newline
# handling, documented under paste-buffer(1)). It's a 1-for-1 substitution,
# so the byte count -- and thus the dd record-count check below -- would
# not catch it; only the actual content would be wrong. Confirmed via a
# direct A/B transfer: identical setup, only -r differs, SHA256 only
# matches with it.
tmux paste-buffer -r -b "$BUFNAME" -t "$TARGET"
tmux delete-buffer -b "$BUFNAME" 2>/dev/null || true

log "-- polling for completion (timeout ${TIMEOUT}s)"
# Same \$\$ technique as the pre-flight check, and for the same reason: the
# target shell may self-echo the command text (containing the literal
# marker) before it ever executes anything, regardless of pty echo state.
tmux send-keys -t "$TARGET" -l \
    "echo ${MARKER}_START; ls -la $REMOTE_PATH; echo \"${MARKER}_END_\$\$\""
tmux send-keys -t "$TARGET" C-j

ELAPSED=0
FOUND=0
OUTPUT=""
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    OUTPUT=$(tmux capture-pane -t "$TARGET" -p -S -50)
    # tmux hard-wraps rendered lines at the pane width; depending on what
    # precedes it, our marker can land split across a wrap boundary. Strip
    # newlines before searching so a wrap can never hide a real match.
    if printf '%s' "$OUTPUT" | tr -d '\n' | grep -Eq "${MARKER}_END_[0-9]+"; then
        FOUND=1
        break
    fi
done

# Restore cooked mode now -- only after the marker confirms dd is no longer
# reading, so no in-flight payload bytes can be reinterpreted by isig/icanon.
restore_stty

[ "$FOUND" -eq 1 ] || die "timed out waiting for transfer confirmation after ${TIMEOUT}s"

# Match the ls -la size field specifically (size, then "Mon DD HH:MM", then
# the exact remote path) rather than a bare grep for $SIZE -- the pane's
# scrollback still has the echoed `dd ... count=$SIZE` command line sitting
# above, which contains the same digits and would otherwise false-match
# even if the file never landed.
if ! printf '%s' "$OUTPUT" | tr -d '\n' | tr -s ' \t' ' ' \
        | grep -Eq "${SIZE} [A-Za-z]{3} +[0-9]+ +[0-9]+:[0-9]+ ${REMOTE_PATH}"; then
    printf '%s\n' "$OUTPUT" >&2
    die "ls -la did not report ${REMOTE_PATH} at exactly ${SIZE} bytes -- see output above"
fi
log "-- verified: $REMOTE_PATH is exactly $SIZE bytes"

if [ "$CHMOD_EXEC" -eq 1 ]; then
    log "-- chmod +x $REMOTE_PATH"
    tmux send-keys -t "$TARGET" "chmod +x $REMOTE_PATH" Enter
    sleep 1
fi

log "==> done: $REMOTE_PATH ($SIZE bytes, byte-exact)"
