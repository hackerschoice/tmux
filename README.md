## TMUX UPLOAD / DOWNLOAD

Allows a user to upload / download files to / from a remote Linux target without needing to install ANY tools on the remote target.

## Install
On your workstation:
```shell

curl -SsfL https://github.com/hackerschoice/tmux/releases/latest/download/tmux-thc.tar.gz | tar xfz - -C ~/.config
curl -fsSL https://raw.githubusercontent.com/hackerschoice/hackshell/main/hackshell.sh -o ~/.config/tmux/hackshell
grep -qFm1 tmux_thc ~/.config/tmux/tmux.conf 2>/dev/null || \
  echo 'if-shell "test -f ~/.config/tmux/tmux_thc.conf" "source-file ~/.config/tmux/tmux_thc.conf"' >>~/.config/tmux/tmux.conf
tmux info 2>/dev/null && tmux source ~/.config/tmux/tmux.conf
command -v pv >/dev/null || sudo apt install pv
```

<img width="1081" height="476" alt="tmux-thc-upload" src="https://github.com/user-attachments/assets/5224828c-ff02-4976-90ce-3d64556ca4be" />

## Use
Start `tmux` on your workstation and use `ssh` or similiar RAT to connect to your remote target. Thereafter use these keys to do the magic:

|  |  |
|--|--|
| Ctrl-b U | Upload a file |
| Ctrl-b D | Download a file |
| Ctrl-b H | Load hackshell |
| Ctrl-b R | Start / Stop recording current session to ~/tmux-rec-*.txt |
| Ctrl-b S | Take screenshot of current session |


## How it works
- It binds U/D/H/R/S keys in tmux.conf to specific functions.
- The functions use `tmux send-key` to inject a bash script into the remote system (memory only)
- The bash-script then communicates via the existing PTY connection to the TMUX on your workstation
- No new connection is established. The upload/download is binary save.
- It requires 'pv' on your local workstation (for the progress bar).

