#!/usr/bin/env bash
# clipsync — bidirectional clipboard bridge: Linux (Wayland) <-> macOS, with
# iPhone photos and text riding in over Apple's Universal Clipboard.
#
# One poll loop, both directions, over a multiplexed SSH connection to the Mac
# (set ControlMaster/ControlPersist in ~/.ssh/config — see README). If the Mac
# is unreachable, backs off and retries. The only thing that runs on the Mac
# is the read-only uc-pull LaunchAgent (mac/) that keeps Universal Clipboard
# resolving in the GUI session.
#
# Loop-guard: a single last-synced content hash. Whichever side shows a hash
# we have not seen wins the tick and is copied to the other side. Content we
# just ferried matches the stored hash and is ignored, so it never ping-pongs.
#
# PHONE-FIRST ORDERING: an iPhone photo arrives on the Mac as a FILE URL
# («class furl») into an ephemeral shared-pasteboard container — macOS purges
# it the instant the Mac clipboard changes. If we checked the Linux side first
# while it was busy (typing, selecting, clipboard managers), our push would
# stomp the furl before it was ever ferried. So each tick fetches the Mac
# fingerprint FIRST and ferries a fresh furl BEFORE any local push.
#
# Images: pbcopy/pbpaste are text-only, so direct images go through osascript
# («class PNGf»); furl photos are resolved on the Mac (sips converts + scales).
#
# OBSERVABILITY: every ferry / error / offline transition is logged to the
# journal (`journalctl --user -u clipsync -f`); a health snapshot lives in
# $STATE_DIR/status (`clipsync-status`); incoming images toast; the last
# incoming image is kept at $STATE_DIR/remote.png (`clipsync-restore-image`).
#
# Works with any clipboard manager, or none. Nothing here depends on one.

set -u

# ---------- configuration ----------
# ~/.config/clipsync/config is a shell fragment. Environment variables win.
CONFIG="${CLIPSYNC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/clipsync/config}"
if [[ -r "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi
MAC_HOST="${MAC_HOST:-}"                  # ssh host alias of the Mac (required)
POLL_SECS="${POLL_SECS:-1}"               # seconds between ticks
OFFLINE_BACKOFF_SECS="${OFFLINE_BACKOFF_SECS:-15}"
MAX_BYTES="${MAX_BYTES:-67108864}"        # 64MB — never silently drop a photo
MAX_EDGE="${MAX_EDGE:-2560}"              # downscale phone photos to this long edge (0 = off)
TOAST="${TOAST:-1}"                       # notify-send when an image arrives

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/clipsync"
mkdir -p "$STATE_DIR"
LAST_HASH_FILE="$STATE_DIR/last.sha"
STATUS_FILE="$STATE_DIR/status"
IMG_TMP="$STATE_DIR/remote.png"
LOCAL_IMG_TMP="$STATE_DIR/local.png"
REMOTE_INFO_CACHE=""
FURL_PATH_CACHE=""   # furl fingerprint = the file PATH (unique per UC copy), NOT the info length
ONLINE=1
TICKS=0

ts()         { date '+%Y-%m-%dT%H:%M:%S%z'; }
log()        { printf '%s %s\n' "$(ts)" "$*" >&2; }
hash_stdin() { sha256sum | cut -d' ' -f1; }
last_hash()  { cat "$LAST_HASH_FILE" 2>/dev/null || echo "none"; }

if [[ -z "$MAC_HOST" ]]; then
    log "MAC_HOST is not set. Put  MAC_HOST=<ssh alias of your Mac>  in $CONFIG"
    exit 78
fi
for dep in wl-copy wl-paste ssh sha256sum basenc; do
    command -v "$dep" >/dev/null 2>&1 || { log "missing dependency: $dep"; exit 69; }
done

SSH=(ssh -o ConnectTimeout=5 -o BatchMode=yes "$MAC_HOST")
MAC_TMP="/tmp/.clipsync.png"
OSA_INFO="osascript -e 'clipboard info'"
OSA_GET_PNG="osascript -e 'the clipboard as «class PNGf»'"
OSA_FURL_PATH="osascript -e 'POSIX path of (the clipboard as «class furl»)'"
OSA_SET_PNG="cat > $MAC_TMP && osascript -e \"set the clipboard to (read (POSIX file \\\"$MAC_TMP\\\") as «class PNGf»)\""

# Resolve the furl on the Mac clipboard and emit PNG bytes to stdout. Phone
# photos are 12-48 megapixels; as PNG that is 30-60MB — slow to move, too big
# for most history managers' thumbnails, a brick to paste. A clipboard photo
# does not need that, so the long edge is capped at MAX_EDGE (sips -Z keeps
# aspect and never upscales). Full resolution stays on the phone.
fetch_remote_furl_png() {
    "${SSH[@]}" "MAX_EDGE=$MAX_EDGE bash -s" 2>/dev/null <<'RSCRIPT'
p=$(osascript -e 'POSIX path of (the clipboard as «class furl»)' 2>/dev/null)
[ -n "$p" ] && [ -f "$p" ] || exit 1
case "$(file -b "$p" 2>/dev/null)" in
    PNG*|JPEG*|TIFF*|*HEIC*|*HEIF*|*image*) ;;
    *) exit 2 ;;
esac
out=/tmp/.clipsync_conv.png
if [ "${MAX_EDGE:-0}" -gt 0 ]; then
    sips -Z "$MAX_EDGE" -s format png "$p" --out "$out" >/dev/null 2>&1 || exit 3
else
    sips -s format png "$p" --out "$out" >/dev/null 2>&1 || exit 3
fi
cat "$out"
RSCRIPT
}

# Health snapshot: epoch state(online|offline) lastdir lastkind lastbytes ticks
write_status() {
    printf '%s %s %s %s %s %s\n' \
        "$(date +%s)" "$1" "${2:-none}" "${3:-none}" "${4:-0}" "$TICKS" > "$STATUS_FILE"
}

preview() { printf %s "$1" | tr '\n' ' ' | head -c 48; }
dims()    { command -v magick >/dev/null 2>&1 && magick identify -format '%wx%h' "$1" 2>/dev/null || true; }
toast_image() {
    [[ "$TOAST" == 1 ]] && command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a clipsync -t 4000 "📱 Clipboard image arrived" "$(( $1 / 1024 )) KB — paste now" 2>/dev/null || true
}
toast_skip() {
    [[ "$TOAST" == 1 ]] && command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a clipsync -u critical -t 8000 "📱 Photo too large" "$(( $1 / 1048576 )) MB exceeds the $(( MAX_BYTES / 1048576 )) MB cap — not copied" 2>/dev/null || true
}

went_offline() {
    if (( ONLINE )); then log "$MAC_HOST UNREACHABLE — backing off ${OFFLINE_BACKOFF_SECS}s"; fi
    ONLINE=0
    REMOTE_INFO_CACHE=""
    FURL_PATH_CACHE=""
    write_status offline "${LAST_DIR:-none}" "${LAST_KIND:-none}" "${LAST_BYTES:-0}"
    sleep "$OFFLINE_BACKOFF_SECS"
}
mark_online() {
    if (( ! ONLINE )); then log "$MAC_HOST reachable again — sync resumed"; fi
    ONLINE=1
}

LAST_DIR=none; LAST_KIND=none; LAST_BYTES=0
record() { LAST_DIR="$1"; LAST_KIND="$2"; LAST_BYTES="$3"; write_status online "$1" "$2" "$3"; }

# Ferry a fresh furl (phone photo) Mac -> Linux. Uses $last from the caller.
ferry_furl() {
    if fetch_remote_furl_png > "$IMG_TMP"; then
        local size; size=$(stat -c%s "$IMG_TMP" 2>/dev/null || echo 0)
        if (( size > 0 && size <= MAX_BYTES )); then
            local remote_h; remote_h=$(hash_stdin < "$IMG_TMP")
            if [[ "$remote_h" != "$last" ]]; then
                if wl-copy --type image/png < "$IMG_TMP"; then
                    echo "$remote_h" > "$LAST_HASH_FILE"
                    record 'mac->linux' image "$size"
                    log "mac->linux furl-image ${size}B ${remote_h:0:12} $(dims "$IMG_TMP")"
                    toast_image "$size"
                else
                    log "ERROR wl-copy (furl-image) failed"
                fi
            fi
        elif (( size > MAX_BYTES )); then
            log "SKIP furl-image ${size}B exceeds ${MAX_BYTES}B cap"
            toast_skip "$size"
        fi
    fi
}

log "clipsync started (mac=$MAC_HOST poll=${POLL_SECS}s max_edge=${MAX_EDGE} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset})"
write_status online none none 0

while :; do
    TICKS=$((TICKS + 1))
    last=$(last_hash)

    # ---------- 0. Mac fingerprint, once per tick ----------
    remote_ok=0
    if remote_info=$("${SSH[@]}" "$OSA_INFO" 2>/dev/null); then
        mark_online; remote_ok=1
    fi

    # ---------- 1. PHONE-FIRST: a fresh iPhone photo beats any local push ----------
    # `clipboard info` for a furl is only "«class furl», <length>" — consecutive
    # iPhone photos (IMG_6829.png, IMG_6830.png) have IDENTICAL lengths, so the
    # info fingerprint cannot tell them apart. Fingerprint on the resolved PATH:
    # every Universal Clipboard copy lands in a fresh per-item UUID folder.
    if (( remote_ok )) && [[ "$remote_info" == *furl* ]]; then
        furl_path=$("${SSH[@]}" "$OSA_FURL_PATH" 2>/dev/null || true)
        if [[ -n "$furl_path" && "$furl_path" != "$FURL_PATH_CACHE" ]]; then
            log "phone furl: ${furl_path##*/}"
            ferry_furl
            FURL_PATH_CACHE="$furl_path"
            REMOTE_INFO_CACHE="$remote_info"
            sleep "$POLL_SECS"
            continue
        fi
    fi

    # ---------- 2. Local (Linux) side ----------
    # wl-paste exits non-zero for BOTH an empty clipboard (normal, silent) and
    # a dead Wayland connection (real error, loud). Tell them apart by stderr.
    if ! local_types=$(wl-paste --list-types 2>"$STATE_DIR/.wlerr"); then
        local_err=$(cat "$STATE_DIR/.wlerr" 2>/dev/null)
        if [[ "$local_err" == *[Ww]ayland* || "$local_err" == *connect* ]]; then
            log "ERROR wl-paste cannot reach Wayland (WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}): $local_err — restart clipsync after a compositor restart"
        fi
        local_types=""
    fi

    if [[ "${local_types:-}" == *image/png* ]]; then
        wl-paste --type image/png > "$LOCAL_IMG_TMP" 2>/dev/null || : > "$LOCAL_IMG_TMP"
        size=$(stat -c%s "$LOCAL_IMG_TMP" 2>/dev/null || echo 0)
        if (( size > 0 && size <= MAX_BYTES )); then
            local_h=$(hash_stdin < "$LOCAL_IMG_TMP")
            if [[ "$local_h" != "$last" ]]; then
                if "${SSH[@]}" "$OSA_SET_PNG" < "$LOCAL_IMG_TMP"; then
                    echo "$local_h" > "$LAST_HASH_FILE"
                    mark_online
                    record 'linux->mac' image "$size"
                    log "linux->mac image ${size}B ${local_h:0:12}"
                    REMOTE_INFO_CACHE=$("${SSH[@]}" "$OSA_INFO" 2>/dev/null) || REMOTE_INFO_CACHE=""
                else
                    went_offline
                fi
                sleep "$POLL_SECS"
                continue
            fi
        fi
    else
        local_clip=$(wl-paste --no-newline --type text 2>/dev/null || true)
        if [[ -n "$local_clip" && ${#local_clip} -le $MAX_BYTES ]]; then
            local_h=$(printf %s "$local_clip" | hash_stdin)
            if [[ "$local_h" != "$last" ]]; then
                if printf %s "$local_clip" | "${SSH[@]}" pbcopy; then
                    echo "$local_h" > "$LAST_HASH_FILE"
                    mark_online
                    record 'linux->mac' text "${#local_clip}"
                    log "linux->mac text ${#local_clip}B [$(preview "$local_clip")] ${local_h:0:12}"
                    REMOTE_INFO_CACHE=$("${SSH[@]}" "$OSA_INFO" 2>/dev/null) || REMOTE_INFO_CACHE=""
                else
                    went_offline
                fi
                sleep "$POLL_SECS"
                continue
            fi
        fi
    fi

    # ---------- 3. Remote (Mac) side ----------
    if (( remote_ok )); then
        if [[ "$remote_info" == *furl* ]]; then
            # Handled in step 1 when fresh; a cached furl is a no-op. Never fall
            # into the text branch: pbpaste on a furl yields the path string.
            REMOTE_INFO_CACHE="$remote_info"
        elif [[ "$remote_info" == *PNGf* ]]; then
            FURL_PATH_CACHE=""
            # Direct image on the Mac clipboard: only ferry when the fingerprint moved.
            if [[ "$remote_info" != "$REMOTE_INFO_CACHE" ]]; then
                if "${SSH[@]}" "$OSA_GET_PNG" 2>/dev/null \
                        | tr -d '\n' \
                        | sed -e 's/^«data PNGf//' -e 's/»$//' \
                        | basenc --base16 -d > "$IMG_TMP" 2>/dev/null; then
                    size=$(stat -c%s "$IMG_TMP" 2>/dev/null || echo 0)
                    if (( size > 0 && size <= MAX_BYTES )); then
                        remote_h=$(hash_stdin < "$IMG_TMP")
                        if [[ "$remote_h" != "$last" ]]; then
                            if wl-copy --type image/png < "$IMG_TMP"; then
                                echo "$remote_h" > "$LAST_HASH_FILE"
                                record 'mac->linux' image "$size"
                                log "mac->linux image ${size}B ${remote_h:0:12}"
                                toast_image "$size"
                            else
                                log "ERROR wl-copy (image) failed"
                            fi
                        fi
                    fi
                fi
                REMOTE_INFO_CACHE="$remote_info"
            fi
        else
            FURL_PATH_CACHE=""
            # Text: pbpaste is cheap, hash-compare every tick.
            if remote_clip=$("${SSH[@]}" pbpaste 2>/dev/null); then
                if [[ -n "$remote_clip" && ${#remote_clip} -le $MAX_BYTES ]]; then
                    remote_h=$(printf %s "$remote_clip" | hash_stdin)
                    if [[ "$remote_h" != "$last" ]]; then
                        if printf %s "$remote_clip" | wl-copy; then
                            echo "$remote_h" > "$LAST_HASH_FILE"
                            record 'mac->linux' text "${#remote_clip}"
                            log "mac->linux text ${#remote_clip}B [$(preview "$remote_clip")] ${remote_h:0:12}"
                        else
                            log "ERROR wl-copy (text) failed"
                        fi
                    fi
                fi
                REMOTE_INFO_CACHE="$remote_info"
            else
                went_offline
            fi
        fi
    else
        went_offline
    fi

    # Heartbeat: refresh the status mtime every ~60s even when idle, so a
    # health check can tell "alive and quiet" from "daemon is dead".
    if (( TICKS % 60 == 0 )); then write_status "$([[ $ONLINE == 1 ]] && echo online || echo offline)" "$LAST_DIR" "$LAST_KIND" "$LAST_BYTES"; fi

    sleep "$POLL_SECS"
done
