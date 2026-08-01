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
rtag="$$"
fsize="$(wc -c <"$f" 2>/dev/null || echo 0)"
# Clear any cancel flag here, before the handshake/hint even happen - not
# inside cmd's own startup, which runs later as a separate backgrounded job
# and would otherwise have a real window to silently wipe out a cancel
# pressed right after the hint appears, before cmd gets around to running.
rm -f "${TMPDIR:-/tmp}/.tmux-xfer-${p}.cancel"
tmux send-keys -t "$p" " stty -echo; set +H 2>/dev/null" C-m
sleep 0.1

# Receiver runs on the remote: decodes stdin to $b, and in the background
# prints its own human-readable "pct rate ETA" line via \r (so it lives
# in-place in the pane, overwritten each second, no scrollback clutter).
# It knows the total size ($fsize) up front, so it can compute everything
# itself - the client never needs to know the true transfer rate.
rcv=$(cat <<'REMOTE_EOF'
__ul_old_traps="$(trap)";
trap "stty echo; set -H 2>/dev/null; printf '\033[?25h'" EXIT INT TERM;
exec 9>&2 2>/dev/null;
_s=$(date +%s);
( while :; do
    sleep 1;
    _b=$(wc -c <"__B__" 2>/dev/null || echo 0);
    _e=$(( $(date +%s) - _s ));
    [ "$_e" -le 0 ] && _e=1;
    _st=$(awk -v sent="$_b" -v secs="$_e" -v total="__FSIZE__" -v tag="__T__" 'BEGIN{
      pct = total>0 ? int(100*sent/total) : 100;
      if (pct>100) pct=100;
      remain = total-sent; if (remain<0) remain=0;
      rate = sent/secs;
      u="B/s"; v=rate;
      if (v>=1048576){v/=1048576; u="MiB/s"} else if (v>=1024){v/=1024; u="KiB/s"};
      eta = rate>0 ? remain/rate : 0;
      es=int(eta); h=int(es/3600); m=int((es%3600)/60); s=es%60;
      printf "%3d%% %6.1f%s ETA %d:%02d:%02d \033[2mrecv_%s:%d\033[0m", pct, v, u, h, m, s, tag, sent
    }');
    printf "\rUpload: %s   " "$_st";
  done
) &
_ulwatcher=$!;
printf "\033[?25l\033[33mUploading __B__ - press C-b X to cancel\033[0m\n__N__ READY\n";
sed 's/^#//' | { base64 -d 2>/dev/null || openssl enc -base64 -d 2>/dev/null; } >"__B__";
kill "$_ulwatcher" 2>/dev/null;
wait "$_ulwatcher" 2>/dev/null;
exec 2>&9 9>&-;
_fe=$(( $(date +%s) - _s )); [ "$_fe" -le 0 ] && _fe=1;
_factual=$(wc -c <"__B__" 2>/dev/null || echo 0);
if [ "$_factual" -ge __FSIZE__ ]; then
  _fst=$(awk -v sent="__FSIZE__" -v secs="$_fe" -v total="__FSIZE__" -v tag="__T__" 'BEGIN{
    pct = 100;
    rate = sent/secs;
    u="B/s"; v=rate;
    if (v>=1048576){v/=1048576; u="MiB/s"} else if (v>=1024){v/=1024; u="KiB/s"};
    h=int(secs/3600); m=int((secs%3600)/60); s=secs%60;
    printf "%3d%% %6.1f%s in %d:%02d:%02d \033[2mrecv_%s:%d\033[0m", pct, v, u, h, m, s, tag, sent
  }');
  printf "\rUpload: %s   \n" "$_fst";
  stty echo; set -H 2>/dev/null; printf '\033[?25h';
  printf "%s DONE\n" "__N__";
else
  printf "\rUpload: CANCELLED (%d/%d bytes received)   \n" "$_factual" __FSIZE__;
  stty echo; set -H 2>/dev/null; printf '\033[?25h';
  printf "%s CANCELLED\n" "__N__";
fi;
eval "$__ul_old_traps"; unset __ul_old_traps
REMOTE_EOF
)
rcv=$(printf '%s' "$rcv" | tr '\n' ' ' | sed "s/__N__/$n/g; s|__B__|$b|g; s/__FSIZE__/$fsize/g; s/__T__/$rtag/g")
tmux send-keys -t "$p" -l " $rcv"
tmux send-keys -t "$p" C-m

i=0
while [ "$i" -lt 200 ]; do
  tmux capture-pane -p -t "$p" -S -30 | grep -Fq "$n READY" && break
  i=$((i+1))
  sleep 0.05
done
[ "$i" -ge 200 ] && { tmux send-keys -t "$p" C-c; tmux send-keys -t "$p" " stty echo; set -H 2>/dev/null; printf '\\033[?25h'" C-m; tmux display-message "U handshake timeout"; exit 1; }

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

cmd="UL_FILE=$(shq "$f") UL_PANE=$(shq "$p") UL_MARKER=$(shq "$n") UL_FSIZE=$(shq "$fsize") UL_TAG=$(shq "$rtag"); "
cmd="$cmd"'
_tmp="${TMPDIR:-/tmp}/.tmux-ul-$$"
mkdir -p "$_tmp"
_cf="${TMPDIR:-/tmp}/.tmux-xfer-${UL_PANE}.cancel"
trap "rm -f \"\$_cf\"" EXIT
_ul_cancelled() {
  rm -f "$_tmp/chunk" "$_tmp/payload"
  rmdir "$_tmp" 2>/dev/null
  tmux send-keys -t "$UL_PANE" C-c
  tmux send-keys -t "$UL_PANE" " stty echo; set -H 2>/dev/null; printf \"\\033[?25h\"" C-m
  tmux display-message "Upload cancelled"
  exit 0
}
{ openssl enc -base64 -A <"$UL_FILE"; printf "\n"; } | fold -w 800 | sed "s/^/#/" >"$_tmp/payload"
UL_TOTAL=$(wc -c <"$_tmp/payload")
_offset=0
# Cap how far ahead of remote-confirmed bytes we let ourselves queue. tmux
# buffers paste-buffer writes internally with no size limit if the link is
# too slow to keep up - without this, the whole file can end up queued
# locally before a slow/high-latency link has delivered any of it, leaving
# nothing for a cancel to actually interrupt. 2MiB comfortably covers the
# bandwidth-delay product of most real links without throttling throughput;
# bump it for a known-bad (high-latency) link.
_ul_maxinflight=2097152
_ul_confirmed=0
while [ "$_offset" -lt "$UL_TOTAL" ]; do
  [ -f "$_cf" ] && _ul_cancelled
  _remain_total=$((UL_TOTAL - _offset))
  _chunk=131072
  [ "$_chunk" -gt "$_remain_total" ] && _chunk="$_remain_total"
  _ul_est_sent=$(( (_offset + _chunk) * UL_FSIZE / UL_TOTAL ))
  while [ $((_ul_est_sent - _ul_confirmed)) -gt "$_ul_maxinflight" ]; do
    [ -f "$_cf" ] && _ul_cancelled
    _ul_line=$(tmux capture-pane -p -t "$UL_PANE" -S -5 | grep -o "recv_$UL_TAG:[0-9]*" | tail -1)
    _ul_confirmed=${_ul_line#recv_$UL_TAG:}
    [ -n "$_ul_confirmed" ] || _ul_confirmed=0
    sleep 0.2
  done
  tail -c +$((_offset + 1)) "$_tmp/payload" | head -c "$_chunk" >"$_tmp/chunk"
  tmux load-buffer -b ulxfer "$_tmp/chunk"
  tmux paste-buffer -b ulxfer -d -t "$UL_PANE"
  _offset=$((_offset + _chunk))
done
rm -f "$_tmp/chunk" "$_tmp/payload"
rmdir "$_tmp" 2>/dev/null
tmux send-keys -t "$UL_PANE" C-d

while ! tmux capture-pane -p -t "$UL_PANE" -S -30 | grep -Fq "$UL_MARKER DONE"; do
  [ -f "$_cf" ] && _ul_cancelled
  sleep 0.5
done
'
tmux run-shell -b "$cmd" || true
