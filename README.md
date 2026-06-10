## TMUX UPLOAD / DOWNLOAD

Allows a user to upload / download files to / from a remote Linux target without needing to install ANY tools on the remote target.


## Install
On your workstation:
```shell
curl -SsfL https://github.com/hackerschoice/tmux/releases/latest/download/tmux-thc.tar.gz | tar xfz - -C ~/.config
grep -qFm1 tmux_thc ~/.config/tmux/tmux.conf 2>/dev/null || \
  echo 'if-shell "test -f ~/.config/tmux/tmux_thc.conf" "source-file ~/.config/tmux/tmux_thc.conf' >>~/.config/tmux/tmux.conf"'
```

## Use
Start `tmux` on your workstation and use `ssh` or similiar RAT to connect to your remote target. Thereafter use these keys to do the magic:

|  |  |
|--|--|
| Ctrl-b U | Upload a file |
| Ctrl-b D | Download a file |
| Ctrl-b H | Load hackshell |
| Ctrl-b R | Start / Stop recording current session |
| Ctrl-b S | Take screenshot of current session |


## How it works
- It binds U/D/H/R/S keys in tmux.conf to specific functions.
- The functions use `tmux send-key` to inject a bash script into the remote system (memory only)
- The bash-script then communicates via the existing PTY connection to the TMUX on your workstation
- No new connection is established. The upload/download is binary save.
- It requires 'pv' on your local workstation (for the progress bar).

