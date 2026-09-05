#!/usr/bin/env bash
# install-mac.sh — install the read-only Universal Clipboard pull agent on the
# Mac, FROM the Linux box, over SSH. Nothing to click on the Mac.
#
#   mac/install-mac.sh <ssh-host>        install / upgrade
#   mac/install-mac.sh <ssh-host> --uninstall
#
# Requires: Remote Login enabled on the Mac (System Settings > General >
# Sharing) and key-based SSH to it. Installs ~/bin/uc-pull.sh and
# ~/Library/LaunchAgents/com.clipsync.ucpull.plist, bootstrapped into the
# user's GUI launchd domain (gui/<uid>) so it runs in the Aqua session — the
# only context in which a pasteboard read wakes Universal Clipboard.
set -euo pipefail

host="${1:-}"; mode="${2:-install}"
[[ -n "$host" ]] || { echo "usage: $0 <ssh-host> [--uninstall]"; exit 64; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label=com.clipsync.ucpull

echo "→ probing $host over ssh"
remote_home=$(ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$host" 'printf %s "$HOME"')
uid=$(ssh -n -o BatchMode=yes "$host" 'id -u')
console=$(ssh -n -o BatchMode=yes "$host" 'stat -f %Su /dev/console')
echo "  home=$remote_home uid=$uid console-user=$console"

if [[ "$mode" == "--uninstall" ]]; then
    ssh -n "$host" "launchctl bootout gui/$uid/$label 2>/dev/null; rm -f ~/Library/LaunchAgents/$label.plist ~/bin/uc-pull.sh; echo removed"
    exit 0
fi

# Render the plist locally and scp it. (Never pipe a heredoc through `ssh -n`:
# -n starves stdin and you get a 0-byte plist.)
tmp=$(mktemp)
sed "s|__PROGRAM__|$remote_home/bin/uc-pull.sh|" "$here/com.clipsync.ucpull.plist.template" > "$tmp"

echo "→ copying agent"
ssh -n "$host" 'mkdir -p ~/bin ~/Library/LaunchAgents'
scp -q "$here/uc-pull.sh" "$host:$remote_home/bin/uc-pull.sh"
scp -q "$tmp" "$host:$remote_home/Library/LaunchAgents/$label.plist"
rm -f "$tmp"
ssh -n "$host" "chmod +x ~/bin/uc-pull.sh && plutil -lint ~/Library/LaunchAgents/$label.plist >/dev/null"

echo "→ (re)loading LaunchAgent in gui/$uid"
ssh -n "$host" "launchctl bootout gui/$uid/$label 2>/dev/null; launchctl enable gui/$uid/$label 2>/dev/null; launchctl bootstrap gui/$uid ~/Library/LaunchAgents/$label.plist && launchctl kickstart -k gui/$uid/$label"
sleep 2
state=$(ssh -n "$host" "launchctl print gui/$uid/$label 2>/dev/null | awk '/state =/ {print \$3; exit}'")
if [[ "$state" == "running" ]]; then
    echo "✓ $label running on $host (reads the pasteboard every 1.5s, read-only)"
else
    echo "✗ agent not running (state='$state'). Check: ssh $host 'launchctl print gui/$uid/$label'"
    exit 1
fi
