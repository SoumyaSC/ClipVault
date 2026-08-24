#!/bin/bash
# make_screenshots.sh — regenerate the README screenshots in docs/screenshots/.
#
#   ./Scripts/make_screenshots.sh
#
# Two phases, both against a scratch history (CV_DATA_DIR) and a scratch
# preferences suite (CV_DEFAULTS_SUITE) so no real clipboard item can ever
# reach a public README:
#
#   1. seed — copies demo content to the pasteboard and lets a throwaway
#      instance capture it through the real pipeline, so the panel shows what
#      the app genuinely stores
#   2. render — a second throwaway instance draws the shipping views straight
#      into PNGs (CV_RENDER_DIR) and quits
#
# Rendering from the view hierarchy rather than screen-capturing means this
# works with the screen locked, needs no Screen Recording permission, and gives
# byte-identical output run to run.
#
# Side effects, all restored or announced:
#   • a running ClipVault is quit first (it would capture the demo content into
#     your real history); the script relaunches it from /Applications at the end
#   • the pasteboard is saved as text and restored afterwards
#
# Requires a build: ./Scripts/build_app.sh

set -euo pipefail

# pbcopy reads the pasteboard text in the locale's encoding; without this the
# em dashes and ⌘⇧V in the demo content arrive as MacRoman mojibake.
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG="${LANG:-en_US.UTF-8}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/stage/ClipVault.app"
BIN="$APP/Contents/MacOS/ClipVault"
OUT="$ROOT/docs/screenshots"
SCRATCH="$(mktemp -d /tmp/clipvault-shots.XXXXXX)"
SUITE="cv.screenshots.$$"
CLIPBOARD_BACKUP="$SCRATCH/pasteboard.txt"

[ -x "$BIN" ] || { echo "No build at $APP — run ./Scripts/build_app.sh first" >&2; exit 1; }
mkdir -p "$OUT"

was_running=false
pgrep -f "/Applications/ClipVault.app/Contents/MacOS/ClipVault" >/dev/null 2>&1 && was_running=true

cleanup() {
    /usr/bin/pkill -f "$BIN" 2>/dev/null || true
    [ -f "$CLIPBOARD_BACKUP" ] && /usr/bin/pbcopy < "$CLIPBOARD_BACKUP" 2>/dev/null || true
    defaults delete "$SUITE" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$SUITE.plist" 2>/dev/null || true
    rm -rf "$SCRATCH"
    if $was_running; then
        open -a /Applications/ClipVault.app 2>/dev/null || true
    fi
}
trap cleanup EXIT

/usr/bin/pbpaste > "$CLIPBOARD_BACKUP" 2>/dev/null || true

echo "▶︎ Quitting any running ClipVault (it must not capture the demo content)"
osascript -e 'quit app "ClipVault"' >/dev/null 2>&1 || true
sleep 1.5

# The state the screenshots should show: welcome banner dismissed, update
# checks quiet, everything else at its default.
defaults write "$SUITE" cv.welcomeShown -bool true
defaults write "$SUITE" cv.checkForUpdates -bool false

echo "▶︎ Seeding demo history through the real capture path"
CV_DATA_DIR="$SCRATCH" CV_DEFAULTS_SUITE="$SUITE" "$BIN" >/dev/null 2>&1 &
sleep 2

# Oldest first — the panel lists newest at the top.
DEMO=(
    "Everything you copy lands here — text, images, the lot — and ⌘⇧V brings it back without breaking your flow."
    "git rebase -i HEAD~3"
    "#6B5CF2"
    "SELECT id, kind, created_at FROM clips ORDER BY created_at DESC LIMIT 20;"
)
for item in "${DEMO[@]}"; do
    printf '%s' "$item" | /usr/bin/pbcopy
    sleep 0.8
done

# One real image, so the thumbnail row is genuine rather than described.
osascript -e "set the clipboard to (read (POSIX file \"$ROOT/Resources/brand/icon_256x256.png\") as «class PNGf»)" >/dev/null
sleep 1.2

printf '%s' "brew install --cask soumyasc/tap/clipvault" | /usr/bin/pbcopy
sleep 1.5

/usr/bin/pkill -f "$BIN" 2>/dev/null || true
sleep 1

echo "▶︎ Rendering the panel"
CV_DATA_DIR="$SCRATCH" CV_DEFAULTS_SUITE="$SUITE" CV_RENDER_DIR="$OUT" "$BIN" >/dev/null 2>&1 || true
sleep 1

# The Settings window can't be rendered offscreen: on macOS 26 its tab bar and
# switch fills are compositor materials, and an offscreen bitmap gets a blank
# pill and grey switches. It has to be captured through the window server,
# which needs an unlocked screen and Screen Recording permission.
locked() {
    # The key is present either way — it is the value that matters.
    ioreg -n Root -d1 -a 2>/dev/null | grep -A1 "CGSSessionScreenIsLocked" | grep -q "<true/>"
}

if locked; then
    echo "▶︎ Skipping Settings capture — the screen is locked."
    echo "  Unlock and re-run to refresh docs/screenshots/settings-*.png."
else
    echo "▶︎ Capturing the Settings window"
    CV_DATA_DIR="$SCRATCH" CV_DEFAULTS_SUITE="$SUITE" CV_OPEN_AT_LAUNCH=settings "$BIN" >/dev/null 2>&1 &
    sleep 3
    if id="$("$ROOT/Scripts/window_id.swift" ClipVault 0 2>/dev/null)"; then
        if /usr/sbin/screencapture -x -o -l"$id" "$OUT/settings-general-dark.png" 2>/dev/null; then
            echo "  ✓ settings-general-dark.png"
        else
            echo "  ✗ screencapture failed — is Screen Recording allowed for this terminal?"
        fi
    else
        echo "  ✗ no Settings window appeared"
    fi
    /usr/bin/pkill -f "$BIN" 2>/dev/null || true
fi

echo ""
echo "✔ Screenshots in docs/screenshots/"
ls -1 "$OUT" | sed 's/^/    /'
