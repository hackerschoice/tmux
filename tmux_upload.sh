#!/bin/sh
p="$1"
f="$2"
[ -n "$f" ] || exit 0
case "$f" in
  "~"|"~/"*) f="$HOME${f#\~}" ;;
  /*) ;;
  *) f="$(tmux display-message -p -t "$p" '#{pane_current_path}')/$f" ;;
esac
[ -r "$f" ] || { tmux display-message "Local file not readable: $f"; exit 1; }
b="$(basename "$f")"
[ -n "$b" ] || b=upload
n="__UL_READY_$(date +%s)$$__"
fsize="$(wc -c <"$f" 2>/dev/null || echo 0)"
tmux send-keys -t "$p" " stty -echo" C-m
sleep 0.1

# Receiver runs on the remote: decodes stdin to $b, and in the background
# prints its own human-readable "pct rate ETA" line via \r (so it lives
# in-place in the pane, overwritten each second, no scrollback clutter).
# It knows the total size ($fsize) up front, so it can compute everything
# itself - the client never needs to know the true transfer rate.
rcv=$(cat <<'REMOTE_EOF'
__ul_old_traps="$(trap)";
trap "stty echo" EXIT INT TERM;
exec 9>&2 2>/dev/null;
_s=$(date +%s);
( while :; do
    sleep 1;
    _b=$(wc -c <"__B__" 2>/dev/null || echo 0);
    _e=$(( $(date +%s) - _s ));
    [ "$_e" -le 0 ] && _e=1;
    _st=$(awk -v sent="$_b" -v secs="$_e" -v total="__FSIZE__" 'BEGIN{
      pct = total>0 ? int(100*sent/total) : 100;
      if (pct>100) pct=100;
      remain = total-sent; if (remain<0) remain=0;
      rate = sent/secs;
      u="B/s"; v=rate;
      if (v>=1048576){v/=1048576; u="MiB/s"} else if (v>=1024){v/=1024; u="KiB/s"};
      eta = rate>0 ? remain/rate : 0;
      es=int(eta); h=int(es/3600); m=int((es%3600)/60); s=es%60;
      printf "%3d%% %6.1f%s ETA %d:%02d:%02d", pct, v, u, h, m, s
    }');
    printf "\rUpload: %s   " "$_st";
  done
) &
_ulwatcher=$!;
printf "\n__N__ READY\n";
sed 's/^#//' | { base64 -d 2>/dev/null || openssl enc -base64 -d 2>/dev/null; } >"__B__";
kill "$_ulwatcher" 2>/dev/null;
wait "$_ulwatcher" 2>/dev/null;
exec 2>&9 9>&-;
_fe=$(( $(date +%s) - _s )); [ "$_fe" -le 0 ] && _fe=1;
_fst=$(awk -v sent="__FSIZE__" -v secs="$_fe" -v total="__FSIZE__" 'BEGIN{
  pct = 100;
  rate = sent/secs;
  u="B/s"; v=rate;
  if (v>=1048576){v/=1048576; u="MiB/s"} else if (v>=1024){v/=1024; u="KiB/s"};
  printf "%3d%% %6.1f%s ETA 0:00:00", pct, v, u
}');
printf "\rUpload: %s   \n" "$_fst";
stty echo;
printf "%s DONE\n" "__N__";
eval "$__ul_old_traps"; unset __ul_old_traps
REMOTE_EOF
)
rcv=$(printf '%s' "$rcv" | tr '\n' ' ' | sed "s/__N__/$n/g; s|__B__|$b|g; s/__FSIZE__/$fsize/g")
tmux send-keys -t "$p" -l " $rcv"
tmux send-keys -t "$p" C-m

i=0
while [ "$i" -lt 200 ]; do
  tmux capture-pane -p -t "$p" -S -30 | grep -Fq "$n READY" && break
  i=$((i+1))
  sleep 0.05
done
[ "$i" -ge 200 ] && { tmux send-keys -t "$p" C-c; tmux display-message "U handshake timeout"; exit 1; }

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

cmd="UL_FILE=$(shq "$f") UL_PANE=$(shq "$p") UL_MARKER=$(shq "$n"); "
cmd="$cmd"'
_tmp="${TMPDIR:-/tmp}/.tmux-ul-$$"
mkdir -p "$_tmp"
{ openssl enc -base64 -A <"$UL_FILE"; printf "\n"; } | fold -w 800 | sed "s/^/#/" >"$_tmp/payload"
UL_TOTAL=$(wc -c <"$_tmp/payload")
_offset=0
while [ "$_offset" -lt "$UL_TOTAL" ]; do
  _remain_total=$((UL_TOTAL - _offset))
  _chunk=131072
  [ "$_chunk" -gt "$_remain_total" ] && _chunk="$_remain_total"
  tail -c +$((_offset + 1)) "$_tmp/payload" | head -c "$_chunk" >"$_tmp/chunk"
  tmux load-buffer -b ulxfer "$_tmp/chunk"
  tmux paste-buffer -b ulxfer -d -t "$UL_PANE"
  _offset=$((_offset + _chunk))
done
rm -f "$_tmp/chunk" "$_tmp/payload"
rmdir "$_tmp" 2>/dev/null
tmux send-keys -t "$UL_PANE" C-d

while ! tmux capture-pane -p -t "$UL_PANE" -S -30 | grep -Fq "$UL_MARKER DONE"; do
  sleep 0.5
done
'
tmux run-shell -b "$cmd"
