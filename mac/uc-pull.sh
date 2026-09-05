#!/bin/bash
# uc-pull — keep Universal Clipboard (iPhone) resolving on the Mac, in the GUI
# session. Installed by mac/install-mac.sh as a LaunchAgent (com.clipsync.ucpull).
#
# iOS forbids background clipboard reads, and a pasteboard read over SSH does
# NOT wake Apple's lazy Universal Clipboard fetch — only a read from the
# logged-in GUI (Aqua) session does. This agent runs in that session and reads
# the pasteboard on a short interval, materializing any pending iPhone copy
# onto the Mac; clipsync (over SSH) then ferries it to Linux. Reads BOTH text
# and «class PNGf» so iPhone PHOTOS resolve too.
#
# STRICTLY READ-ONLY: never pbcopy / "set the clipboard", so it can never
# clobber what you copy on the Mac.
#
# UC_PULL_INTERVAL  seconds between reads (default 1.5)
# UC_PULL_DEBUG=1   log each tick's pasteboard summary to /tmp/ucpull.log
INTERVAL="${UC_PULL_INTERVAL:-1.5}"
DEBUG="${UC_PULL_DEBUG:-0}"
LOG=/tmp/ucpull.log

while :; do
    txt=$(osascript -e 'the clipboard' 2>/dev/null)
    osascript -e 'the clipboard as «class PNGf»' >/dev/null 2>&1
    if [ "$DEBUG" = 1 ]; then
        info=$(osascript -e 'clipboard info' 2>/dev/null)
        printf '%s info=[%s] txt=[%s]\n' "$(date +%H:%M:%S)" \
            "$(printf %s "$info" | head -c 100)" \
            "$(printf %s "$txt" | tr '\n' ' ' | head -c 60)" >> "$LOG"
        if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
            tail -250 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        fi
    fi
    sleep "$INTERVAL"
done
