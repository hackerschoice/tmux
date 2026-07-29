#!/bin/sh
p="$1"
n="__HS_READY_$(date +%s)$$__"

tmux send-keys -t "$p" " stty -echo" C-m
sleep 0.1

# Receiver: decodes/gunzips stdin into a temp file, sources it (so functions/
# aliases/exports land in the CURRENT shell, matching the original eval-based
# intent), then reports DONE/ERR. Marker is kept in a variable ($_M) and only
# ever printed via "$_M" - never embedded literally in echoable command text -
# so the echo of this command being typed can never false-match the marker
# the way a literal marker value could.
rcv=$(cat <<'REMOTE_EOF'
__hs_old_traps="$(trap)";
trap "stty echo" EXIT INT TERM;
_M="__N__";
_hstmp="${TMPDIR:-/tmp}/.hs-recv-$$";
printf "\n%s READY\n" "$_M";
sed 's/^#//' | { base64 -d 2>/dev/null || openssl enc -base64 -d 2>/dev/null; } | gunzip >"$_hstmp" 2>/dev/null;
stty echo;
if [ -s "$_hstmp" ]; then . "$_hstmp"; printf "%s DONE\n" "$_M"; else printf "%s ERR\n" "$_M"; fi;
rm -f "$_hstmp"; unset _hstmp _M;
eval "$__hs_old_traps"; unset __hs_old_traps
REMOTE_EOF
)
rcv=$(printf '%s' "$rcv" | tr '\n' ' ' | sed "s/__N__/$n/g")
tmux send-keys -t "$p" -l " $rcv"
tmux send-keys -t "$p" C-m

i=0
while [ "$i" -lt 200 ]; do
  tmux capture-pane -p -t "$p" -S -30 | grep -Fq "$n READY" && break
  i=$((i+1))
  sleep 0.05
done
[ "$i" -ge 200 ] && { tmux send-keys -t "$p" C-c; tmux send-keys -t "$p" " stty echo" C-m; tmux display-message "H handshake timeout"; exit 1; }

# Prepare payload: strip comments, gzip, base64 (unchanged from before), then
# fold to a safe line width and '#'-prefix each line so stray data landing on
# a live prompt (e.g. after a stall) is a harmless comment, not a command -
# same safety trick already used for uploads.
_tmp="${TMPDIR:-/tmp}/.tmux-hs-$$"
mkdir -p "$_tmp"
grep -v '^#' "$HOME/.config/tmux/hackshell" | gzip | base64 | fold -w 800 | sed 's/^/#/' >"$_tmp/payload"
total=$(wc -c <"$_tmp/payload")
offset=0
while [ "$offset" -lt "$total" ]; do
  remain=$((total - offset))
  chunk=131072
  [ "$chunk" -gt "$remain" ] && chunk="$remain"
  tail -c +$((offset + 1)) "$_tmp/payload" | head -c "$chunk" >"$_tmp/chunk"
  tmux load-buffer -b hsxfer "$_tmp/chunk"
  tmux paste-buffer -b hsxfer -d -t "$p"
  offset=$((offset + chunk))
done
rm -f "$_tmp/chunk" "$_tmp/payload"
rmdir "$_tmp" 2>/dev/null
tmux send-keys -t "$p" C-d

j=0
while [ "$j" -lt 200 ]; do
  l=$(tmux capture-pane -p -t "$p" -S -30 | grep -F "$n" | tail -1)
  case "$l" in
    *"$n DONE"*) tmux display-message "Hackshell loaded"; exit 0 ;;
    *"$n ERR"*) tmux display-message "Hackshell load failed (decode error)"; exit 2 ;;
  esac
  j=$((j+1))
  sleep 0.1
done
tmux send-keys -t "$p" C-c
tmux send-keys -t "$p" " stty echo" C-m
tmux display-message "Hackshell load timed out (stalled)"
exit 3
