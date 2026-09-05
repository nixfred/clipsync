# clipsync

**One clipboard across Linux, macOS, and iPhone.** Copy on any of them, paste on Linux. Copy on Linux, paste on the Mac. Text and photos, no keystroke, no app on the phone.

```
 iPhone ──(Universal Clipboard)──▶ Mac ◀──(SSH, both ways)──▶ Linux (Wayland)
```

The Mac is the gateway. Linux is the client. The iPhone needs nothing installed: Apple's own Universal Clipboard delivers to the Mac, and clipsync carries it the rest of the way. Works with any clipboard manager, or none.

## What you get

- **Linux ⇄ Mac**, text and PNG images, both directions, ~1s.
- **iPhone → Linux**, text and photos, automatic. Copy on the phone, a toast pops on Linux a few seconds later, paste.
- Photos are downscaled on the Mac to a 2560px long edge before crossing (a 12-megapixel JPEG becomes ~4MB instead of a 34MB PNG). Set `MAX_EDGE=0` for full resolution.
- Every transfer, error, and offline/online transition is logged. `clipsync-status` shows health at a glance.
- `clipsync-restore-image` puts the last incoming photo back if something on your desktop replaced it before you pasted.

Linux → iPhone is not a thing. iOS does not let a background process set the clipboard, and Universal Clipboard only flows Mac → iPhone when *you* paste on the phone. That direction is out of scope.

## Requirements

**Linux**: a Wayland session, `wl-clipboard` (`wl-copy`/`wl-paste`), OpenSSH, coreutils, systemd user services. Optional: `libnotify` for toasts, ImageMagick for dimensions in the log.

**Mac**: stock macOS. Remote Login enabled (System Settings → General → Sharing) with key-based SSH from the Linux box. The Mac must be awake with the user logged in — Universal Clipboard only resolves in the GUI session.

**iPhone**: signed into the same Apple ID as the Mac, with Handoff on (Settings → General → AirPlay & Handoff), Bluetooth and Wi-Fi on, within range of the Mac.

## Install

Set up an SSH alias for the Mac with connection multiplexing — clipsync polls every second, and this makes each poll ~50ms instead of ~200ms:

```
# ~/.ssh/config
Host mac
  HostName 192.168.1.20        # or a Tailscale name/IP
  User you
  ControlMaster auto
  ControlPath ~/.ssh/cm/%r@%h:%p
  ControlPersist 10m
  ServerAliveInterval 30
```
```
mkdir -p ~/.ssh/cm
ssh mac true      # confirm key auth works non-interactively
```

Then:

```
git clone https://github.com/nixfred/clipsync
cd clipsync
./install.sh mac              # Linux side: ~/.local/bin + systemd --user, starts the daemon
mac/install-mac.sh mac        # Mac side: the pull agent, installed over SSH — nothing to click
```

That's it. Copy something on the Mac and `wl-paste` on Linux.

### Optional: the primary-selection mirror

Many Wayland setups run `wl-paste --primary --watch wl-copy` so mouse-highlighted text is available to Ctrl+V. That one-liner has a side effect: the moment you click into an app to paste a photo, the click touches the primary selection and the mirror replaces the photo with whatever was highlighted — the photo "pastes once, then it's gone."

`primary-mirror` is a drop-in with two guards: it never mirrors an empty selection, and it never overwrites an image. Install it with `./install.sh mac --mirror` (a systemd user unit) and remove the old one-liner from your compositor's autostart. Trade-off: while an image is on the clipboard, highlighting text won't replace it — Ctrl+C will.

## Configuration

`~/.config/clipsync/config` (shell syntax; environment variables override):

| key | default | meaning |
|---|---|---|
| `MAC_HOST` | — | ssh alias of the Mac (required) |
| `POLL_SECS` | `1` | seconds between ticks |
| `MAX_EDGE` | `2560` | downscale phone photos to this long edge; `0` = full resolution |
| `MAX_BYTES` | `67108864` | hard cap on one clip (64MB); anything larger toasts and is skipped |
| `TOAST` | `1` | desktop notification when an image arrives |

Restart after changes: `systemctl --user restart clipsync`.

## Troubleshooting

Start here — the log names the cause:

```
journalctl --user -u clipsync -n 30 -o cat
clipsync-status
```

Lines look like `mac->linux furl-image 4769259B 0520b2b75d1f 1440x2560` and `phone furl: IMG_1234.jpeg`. `SKIP`, `ERROR`, and `UNREACHABLE` mean what they say.

**Phone copies never reach the Mac.** On the iPhone: toggle Handoff off and on, and Bluetooth off and on. This is the single most common fix; the Mac's `sharingd` can start rejecting the phone's advertisements as replays until the phone re-announces. Confirm the Mac is awake and unlocked. You can watch the Mac's side with `UC_PULL_DEBUG=1` in the agent's plist (`/tmp/ucpull.log` on the Mac).

**Photo arrives but is gone after one paste.** Something on your desktop is retaking the clipboard — usually a primary-selection mirror (see above) or a clipboard manager that re-copies. `clipsync-restore-image` brings it back; the mirror replacement fixes it for good.

**Pasted early and got the old clip.** A full-resolution photo takes a few seconds (Universal Clipboard handoff, then the transfer). Wait for the toast.

**Mac asleep.** clipsync backs off 15s and resumes on its own; nothing to do.

## How it works

Each tick:

1. Fetch the Mac's clipboard fingerprint (`osascript -e 'clipboard info'`).
2. **Phone first.** An iPhone photo lands on the Mac as a *file URL* (`«class furl»`) into Universal Clipboard's ephemeral shared-pasteboard folder, which macOS purges the instant the Mac clipboard changes. If a fresh one is present, resolve the path on the Mac, `sips` it to PNG at `MAX_EDGE`, and ferry it to Linux — *before* looking at the Linux side, so a busy Linux clipboard can't stomp it. Freshness is keyed on the file *path* (every copy gets a new UUID folder), because the fingerprint alone is just the URL's byte length and consecutive photos (`IMG_6829`, `IMG_6830`) collide.
3. Linux side: if the clipboard holds something with a hash we haven't ferried, push it to the Mac (`pbcopy` for text, `osascript` `«class PNGf»` for images).
4. Mac side: same in reverse for direct images and text.

A single last-synced hash prevents ping-pong. Nothing on the Mac writes the clipboard except when Linux pushes.

The Mac agent (`mac/uc-pull.sh`) exists because a pasteboard read over SSH does **not** trigger Apple's lazy Universal Clipboard fetch — only a read from the logged-in GUI session does. It runs as a LaunchAgent in `gui/<uid>`, reads the pasteboard every 1.5s (text and PNG, so photos resolve too), and never writes it.

## Limitations

- Wayland only on Linux (`wl-clipboard`). X11 would need `xclip`/`xsel` in three places — PRs welcome.
- One Mac, one Linux box. Not a mesh.
- The Mac has to be awake and logged in; Universal Clipboard does not work from a locked or sleeping Mac.
- No Linux → iPhone (see above).

## License

MIT
