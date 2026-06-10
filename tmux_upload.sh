#!/bin/sh
p="$1"
f="$2"
[ -n "$f" ] || exit 0
case "$f" in /*) ;; *) f="$(tmux display-message -p -t "$p" '#{pane_current_path}')/$f" ;; esac
[ -r "$f" ] || { tmux display-message "Local file not readable: $f"; exit 1; }
b="$(basename "$f")"
[ -n "$b" ] || b=upload
n="__UL_READY_$(date +%s)$$__"
tmux send-keys -t "$p" " stty -echo" C-m
sleep 0.1
tmux send-keys -t "$p" " __ul_old_traps=\"\$(trap)\"; trap \"stty echo\" EXIT INT TERM; printf \"\\n%s READY\n\" \"$n\"; sed 's/^#//'|{ base64 -d 2>/dev/null||openssl enc -base64 -d 2>/dev/null; }>\"$b\"; stty echo; printf \"%s DONE\n\" \"$n\"; eval \"\$__ul_old_traps\"; unset __ul_old_traps" C-m
i=0
while [ "$i" -lt 200 ]; do
  tmux capture-pane -p -t "$p" -S -30 | grep -Fq "$n READY" && break
  i=$((i+1))
  sleep 0.05
done
[ "$i" -ge 200 ] && { tmux send-keys -t "$p" C-c; tmux display-message "U handshake timeout"; exit 1; }
tmux display-popup -E \
  -e "UL_FILE=$f" -e "UL_PANE=$p" -e "UL_BASE=$b" -e "UL_MARKER=$n" \
  -w 80 -h 5 \
  '{ pv -N "$UL_BASE" "$UL_FILE" | openssl enc -base64 -A; printf "\n"; } | fold -w 800 | while IFS= read -r x; do
     tmux send-keys -t "$UL_PANE" -l "#$x"
     tmux send-keys -t "$UL_PANE" C-m
   done
   tmux send-keys -t "$UL_PANE" C-d
   while ! tmux capture-pane -p -t "$UL_PANE" -S -30 | grep -Fq "$UL_MARKER DONE"; do
     sleep 0.1
   done'
