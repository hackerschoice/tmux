#!/bin/sh
# Cancel an in-flight upload/download on the target pane. There is no remote
# pidfile - this just sends C-c into the pane (same as the user hitting
# Ctrl-C themselves; SSH forwards it to the remote and its own tty raises
# SIGINT there) and drops a local flag file that the running transfer
# script's own polling loop checks each tick.
p="$1"
tmux send-keys -t "$p" C-c
: >"${TMPDIR:-/tmp}/.tmux-xfer-${p}.cancel"
tmux display-message "Transfer cancel requested"
