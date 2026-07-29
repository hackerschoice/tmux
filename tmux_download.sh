#!/bin/sh
p="$1"
r="$2"
[ -n "$r" ] || exit 0
b="$(basename -- "$r")"
[ -n "$b" ] || exit 0
t="${TMPDIR:-/tmp}/.tmux-dl-${UID:-$(id -u)}-$$.log"
x="${TMPDIR:-/tmp}/.tmux-dl-b64-${UID:-$(id -u)}-$$.txt"
o="${TMPDIR:-/tmp}/.tmux-dl-out-${UID:-$(id -u)}-$$.bin"
v="${TMPDIR:-/tmp}/.tmux-dl-pv-${UID:-$(id -u)}-$$.log"
rm -f "$t" "$x" "$o" "$v"
m="#__DL_$(date +%s)$$__"

ow="$(tmux display-message -p -t "$p" '#{window_name}')"
oar="$(tmux display-message -p -t "$p" '#{automatic-rename}')"
restore_win() {
  tmux rename-window -t "$p" "$ow"
  [ "$oar" = "1" ] && tmux set-window-option -t "$p" automatic-rename on
}

# Pre-query remote file size (bytes) for pv -s
sz_m="__DLSZ_$(date +%s)$$__"
tmux send-keys -t "$p" " stty -echo" C-m
sleep 0.1
# _dlfile resolves ~/~-prefix on the REMOTE (using the remote's own $HOME,
# evaluated when the remote shell runs this), then persists in the remote
# shell's environment for the main transfer command below to reuse.
tmux send-keys -t "$p" " _dlfile=\"$r\"; case \"\$_dlfile\" in \"~\"|\"~/\"*) _dlfile=\"\$HOME\${_dlfile#\~}\";; esac; echo; printf '%s ' \"$sz_m\"; if [ -r \"\$_dlfile\" ]; then wc -c < \"\$_dlfile\"; else stty echo; printf 'ERR\ndownload: file not readable: %s\n' \"\$_dlfile\"; fi" C-m
fsize=0; i=0
while [ $i -lt 50 ]; do
  l=$(tmux capture-pane -p -t "$p" -S -5 | grep "$sz_m " | head -1)
  [ -n "$l" ] && fsize=$(printf '%s' "$l" | awk '{print $NF}' | tr -d '\r') && break
  i=$((i+1)); sleep 0.1
done
[ "$fsize" = "ERR" ] && { restore_win; tmux display-message "Download ERR(2): file not readable: $r"; rm -f "$t" "$x" "$o" "$v"; exit 2; }
# Compute expected bytes pv will see: b64 chars + one \r per 76-char line + overhead
expected=$(( (fsize + 2) / 3 * 4 + fsize / 57 + 200 ))

tmux pipe-pane -t "$p" "stdbuf -o0 -e0 pv -f -r -e -s $expected 2>&1 >>\"$t\" | stdbuf -o0 tr -s '\\r' '\\n' | stdbuf -o0 grep -v '^$' >>\"$v\""
tmux send-keys -t "$p" " _M=\"$m\"; printf \"\\n%s BEGIN\\n\" \"\$_M\"; if [ -r \"\$_dlfile\" ]; then base64 <\"\$_dlfile\" | tr '\\n' '\\r'; printf \"\n\"; printf \"%s END\n\" \"\$_M\"; else printf \"%s ERR\ndownload: file not readable: %s\n\" \"\$_M\" \"\$_dlfile\"; fi; unset _M; stty echo" C-m
sz=-1
idle=0
while :; do
  grep -Fq "$m END" "$t" 2>/dev/null && break
  grep -Fq "$m ERR" "$t" 2>/dev/null && { restore_win; tmux display-message "Download ERR(2): file not readable: $r"; tmux pipe-pane -t "$p"; rm -f "$t" "$x" "$o" "$v"; exit 2; }
  s=$(wc -c <"$t" 2>/dev/null || echo 0)
  _stats=$(tail -1 "$v" 2>/dev/null | tr -d '\r')
  pct=$(( 100 * s / expected )); [ "$pct" -gt 100 ] && pct=100
  [ -n "$_stats" ] && tmux rename-window -t "$p" "dl ${pct}% ${_stats}"
  [ "$s" != "$sz" ] && { sz="$s"; idle=0; } || idle=$((idle+1))
  [ "$idle" -ge 15 ] && { restore_win; tmux display-message "Download ERR(3): stalled (no growth 15s)"; tmux pipe-pane -t "$p"; tmux send-keys -t "$p" C-c; tmux send-keys -t "$p" " stty echo" C-m; rm -f "$t" "$x" "$o" "$v"; exit 3; }
  sleep 1
done
tmux pipe-pane -t "$p"
restore_win
awk 'BEGIN{RS="\r"; ORS="\n"} {print}' "$t" | awk -v n="$m" 'index($0, n " BEGIN"){s=1;next} index($0, n " END"){exit} s{print}' >"$x"
[ -s "$x" ] || { tmux display-message "Download ERR(4): payload empty: $r"; rm -f "$t" "$x" "$o" "$v"; exit 4; }
(base64 -d <"$x" 2>/dev/null || openssl enc -base64 -d <"$x" 2>/dev/null) >"$o" && [ -s "$o" ] && mv -f "$o" "$b" && tmux display-message "Downloaded to $PWD/$b" || tmux display-message "Download decode failed: $r"
rm -f "$t" "$x" "$o" "$v"
