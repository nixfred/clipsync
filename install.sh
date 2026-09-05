#!/usr/bin/env bash
# install.sh — Linux side of clipsync.
#
#   ./install.sh <mac-ssh-host>            install / upgrade, then start
#   ./install.sh <mac-ssh-host> --mirror   also install the optional primary-selection mirror
#   ./install.sh --uninstall
#
# Installs to ~/.local/bin and ~/.config/systemd/user (no root). Then run
# mac/install-mac.sh <mac-ssh-host> once to put the pull agent on the Mac.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$HOME/.local/bin"
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/clipsync"
cfg="$cfg_dir/config"

if [[ "${1:-}" == "--uninstall" ]]; then
    systemctl --user disable --now clipsync primary-mirror 2>/dev/null || true
    rm -f "$units/clipsync.service" "$units/primary-mirror.service" \
          "$bin/clipsync" "$bin/clipsync-status" "$bin/clipsync-restore-image" "$bin/primary-mirror"
    systemctl --user daemon-reload
    echo "removed (config kept at $cfg; Mac agent: mac/install-mac.sh <host> --uninstall)"
    exit 0
fi

host="${1:-}"; want_mirror=0
[[ "${2:-}" == "--mirror" ]] && want_mirror=1
if [[ -z "$host" && ! -r "$cfg" ]]; then
    echo "usage: $0 <mac-ssh-host> [--mirror]   (the ssh alias of your Mac, e.g. 'mac')"; exit 64
fi

echo "→ checking dependencies"
missing=()
for d in wl-copy wl-paste ssh sha256sum basenc systemctl; do command -v "$d" >/dev/null || missing+=("$d"); done
if (( ${#missing[@]} )); then
    echo "✗ missing: ${missing[*]}   (wl-clipboard, openssh, coreutils, systemd)"; exit 69
fi
command -v notify-send >/dev/null || echo "  note: notify-send not found — arrival toasts disabled (install libnotify to get them)"
[[ -n "${WAYLAND_DISPLAY:-}" ]] || echo "  note: WAYLAND_DISPLAY is not set in this shell — clipsync needs a Wayland session"

echo "→ installing to $bin"
mkdir -p "$bin" "$units" "$cfg_dir"
install -m 755 "$here/clipsync.sh" "$bin/clipsync"
install -m 755 "$here/bin/clipsync-status" "$here/bin/clipsync-restore-image" "$here/bin/primary-mirror" "$bin/"
install -m 644 "$here/clipsync.service" "$units/clipsync.service"
install -m 644 "$here/primary-mirror.service" "$units/primary-mirror.service"

if [[ -n "$host" ]]; then
    if [[ -r "$cfg" ]] && grep -q '^MAC_HOST=' "$cfg"; then
        sed -i "s|^MAC_HOST=.*|MAC_HOST=$host|" "$cfg"
    else
        cat >> "$cfg" <<EOF
# clipsync configuration (shell syntax). Environment variables override these.
MAC_HOST=$host          # ssh alias of your Mac (see README for the ControlMaster block)
#POLL_SECS=1            # seconds between ticks
#MAX_EDGE=2560          # downscale phone photos to this long edge; 0 = full resolution
#MAX_BYTES=67108864     # hard cap on a single clip (64MB)
#TOAST=1                # notify-send when an image arrives
EOF
    fi
fi
echo "  config: $cfg"

if ! ssh -n -o ConnectTimeout=6 -o BatchMode=yes "$(sed -n 's/^MAC_HOST=\([^ #]*\).*/\1/p' "$cfg")" true 2>/dev/null; then
    echo "  warn: cannot ssh to the Mac non-interactively yet. Set up key auth + Remote Login, then: systemctl --user restart clipsync"
fi
if ! grep -q 'ControlMaster' "$HOME/.ssh/config" 2>/dev/null; then
    cat <<'EOF'
  tip: add connection multiplexing for your Mac to ~/.ssh/config — clipsync polls
       every second, and this turns ~200ms connects into ~50ms:
         Host mac
           HostName <ip or name>
           User <you>
           ControlMaster auto
           ControlPath ~/.ssh/cm/%r@%h:%p
           ControlPersist 10m
           ServerAliveInterval 30
       (and: mkdir -p ~/.ssh/cm)
EOF
fi

echo "→ enabling service"
systemctl --user daemon-reload
systemctl --user enable clipsync >/dev/null 2>&1
systemctl --user restart clipsync      # restart, not --now: upgrades must replace a running daemon
if (( want_mirror )); then
    systemctl --user enable primary-mirror >/dev/null 2>&1
    systemctl --user restart primary-mirror
    echo "  primary-mirror enabled (if you already run 'wl-paste --primary --watch wl-copy' in your compositor autostart, remove that line)"
fi
sleep 2
"$bin/clipsync-status" || true
echo
echo "Next: mac/install-mac.sh <mac-ssh-host>   # puts the Universal Clipboard pull agent on the Mac"
echo "Logs: journalctl --user -u clipsync -f"
