#!/bin/sh
p="$1"
n="__HS_READY_$(date +%s)$$__"
tmux send-keys -t "$p" " stty -echo; printf \"$n\n\"; IFS= read -r _A; _H=\"\$({ base64 -d 2>/dev/null || openssl base64 -A -d 2>/dev/null || cat >/dev/null; }|gunzip)\"; stty echo; [ -n \"\$_H\" ] && eval \"\$_H\"; unset _H _A" C-m
i=0
while [ "$i" -lt 200 ]; do
  tmux capture-pane -p -t "$p" -S -30 | grep -Fq "$n" && break
  i=$((i+1))
  sleep 0.05
done
[ "$i" -ge 200 ] && { tmux display-message "H handshake timeout"; exit 1; }
tmux send-keys -t "$p" C-m
grep -v ^# "$HOME/.config/tmux/hackshell" | gzip | base64 | while IFS= read -r x; do
  tmux send-keys -t "$p" -l "$x"
  tmux send-keys -t "$p" C-m
done
tmux send-keys -t "$p" C-d
