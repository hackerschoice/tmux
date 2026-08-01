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

# Cancel support (bound to prefix X, tmux_cancel.sh): .cancel is a local-only
# request flag, checked each loop tick below so an END arriving right after
# a user-triggered C-c is reported as cancelled instead of decoded/saved as
# a successful (but truncated) file. There is no remote pidfile - cancelling
# is just tmux_cancel.sh sending C-c into the pane, same as the user hitting
# Ctrl-C themselves; SSH forwards it to the remote exactly the same way.
_cf="${TMPDIR:-/tmp}/.tmux-xfer-${p}.cancel"
rm -f "$_cf"
trap 'rm -f "$_cf"' EXIT

ow="$(tmux display-message -p -t "$p" '#{window_name}')"
oar="$(tmux display-message -p -t "$p" '#{automatic-rename}')"
restore_win() {
  tmux rename-window -t "$p" "$ow"
  [ "$oar" = "1" ] && tmux set-window-option -t "$p" automatic-rename on
}

# Pre-query remote file size (bytes) for pv -s
sz_m="__DLSZ_$(date +%s)$$__"
tmux send-keys -t "$p" " stty -echo; set +H 2>/dev/null" C-m
sleep 0.1
# _dlfile resolves ~/~-prefix on the REMOTE (using the remote's own $HOME,
# evaluated when the remote shell runs this), then persists in the remote
# shell's environment for the main transfer command below to reuse.
tmux send-keys -t "$p" " printf \"\033[?25l\033[33mDownloading $r - press C-b X to cancel\033[0m\n\"; _dlfile=\"$r\"; case \"\$_dlfile\" in \"~\"|\"~/\"*) _dlfile=\"\$HOME\${_dlfile#\~}\";; esac; printf '%s ' \"$sz_m\"; if [ -r \"\$_dlfile\" ]; then wc -c < \"\$_dlfile\"; else stty echo; set -H 2>/dev/null; printf '\033[?25h'; printf 'ERR\ndownload: file not readable: %s\n' \"\$_dlfile\"; fi" C-m
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
# Speed summary is printed AFTER the END marker, not before - the local
# script extracts everything between BEGIN/END as the payload to decode, so
# anything printed before END would corrupt it. Same reasoning for the ANSI
# codes: \033[2m rides on the SAME line as BEGIN (before its own \n) so it's
# swept into the same skipped/matched record as the marker, never touching
# real payload bytes; \033[0m is glued directly onto the END marker (no \n
# in between) for the same reason on the way out.
dlrcv=$(cat <<'REMOTE_EOF'
_M="__M__";
printf "%s BEGIN\033[2m\n" "$_M";
if [ -r "$_dlfile" ]; then
  _dls=$(date +%s);
  base64 <"$_dlfile" | tr '\n' '\r';
  printf "\n\033[0m";
  printf "%s END\n" "$_M";
  _dlfsize=$(wc -c <"$_dlfile" 2>/dev/null || echo 0);
  _dle=$(( $(date +%s) - _dls )); [ "$_dle" -le 0 ] && _dle=1;
  _dlst=$(awk -v sent="$_dlfsize" -v secs="$_dle" 'BEGIN{
    rate = sent/secs;
    u="B/s"; v=rate;
    if (v>=1048576){v/=1048576; u="MiB/s"} else if (v>=1024){v/=1024; u="KiB/s"};
    h=int(secs/3600); mi=int((secs%3600)/60); ss=secs%60;
    printf "100%% %6.1f%s in %d:%02d:%02d", v, u, h, mi, ss
  }');
  printf "Download: %s\n" "$_dlst";
else
  printf "\033[0m%s ERR\ndownload: file not readable: %s\n" "$_M" "$_dlfile";
fi;
unset _M;
stty echo; set -H 2>/dev/null; printf "\033[?25h";
REMOTE_EOF
)
dlrcv=$(printf '%s' "$dlrcv" | tr '\n' ' ' | sed "s/__M__/$m/g")
tmux send-keys -t "$p" -l " $dlrcv"
tmux send-keys -t "$p" C-m
sz=-1
idle=0
while :; do
  [ -f "$_cf" ] && { restore_win; tmux display-message "Download cancelled: $r"; tmux pipe-pane -t "$p"; tmux send-keys -t "$p" C-c; tmux send-keys -t "$p" " stty echo; set -H 2>/dev/null; printf '\033[0m\033[?25h'" C-m; rm -f "$t" "$x" "$o" "$v"; exit 5; }
  grep -Fq "$m END" "$t" 2>/dev/null && break
  grep -Fq "$m ERR" "$t" 2>/dev/null && { restore_win; tmux display-message "Download ERR(2): file not readable: $r"; tmux pipe-pane -t "$p"; rm -f "$t" "$x" "$o" "$v"; exit 2; }
  s=$(wc -c <"$t" 2>/dev/null || echo 0)
  _stats=$(tail -1 "$v" 2>/dev/null | tr -d '\r')
  pct=$(( 100 * s / expected )); [ "$pct" -gt 100 ] && pct=100
  [ -n "$_stats" ] && tmux rename-window -t "$p" "dl ${pct}% ${_stats}"
  [ "$s" != "$sz" ] && { sz="$s"; idle=0; } || idle=$((idle+1))
  [ "$idle" -ge 15 ] && { restore_win; tmux display-message "Download ERR(3): stalled (no growth 15s)"; tmux pipe-pane -t "$p"; tmux send-keys -t "$p" C-c; tmux send-keys -t "$p" " stty echo; set -H 2>/dev/null; printf '\033[0m\033[?25h'" C-m; rm -f "$t" "$x" "$o" "$v"; exit 3; }
  sleep 1
done
tmux pipe-pane -t "$p"
restore_win
awk 'BEGIN{RS="\r"; ORS="\n"} {print}' "$t" | awk -v n="$m" 'index($0, n " BEGIN"){s=1;next} index($0, n " END"){exit} s{print}' >"$x"
[ -s "$x" ] || { tmux display-message "Download ERR(4): payload empty: $r"; rm -f "$t" "$x" "$o" "$v"; exit 4; }
(base64 -d <"$x" 2>/dev/null || openssl enc -base64 -d <"$x" 2>/dev/null) >"$o" && [ -s "$o" ] && mv -f "$o" "$b" && tmux display-message "Downloaded to $PWD/$b" || tmux display-message "Download decode failed: $r"
rm -f "$t" "$x" "$o" "$v"
