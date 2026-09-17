#!/bin/bash
# launch.sh -- what the LaunchAgent runs: put the display right, then the piece.
#
# Display rotation is a per-user preference that macOS re-applies unreliably
# on fast user switching and at login, so rather than trust it the piece sets
# the arrangement itself, every launch, from the command `racine display save`
# captured in the session where it looked right. No saved arrangement, or a
# displayplacer that fails (a monitor that is not plugged in today), and the
# piece still starts -- on whatever rotation the login left.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ARRANGEMENT=/Users/Shared/racine/display.sh
DISPLAYPLACER=/opt/homebrew/bin/displayplacer

if [ -r "$ARRANGEMENT" ] && [ -x "$DISPLAYPLACER" ]; then
    echo "display: applying $ARRANGEMENT"
    PATH="/opt/homebrew/bin:$PATH" bash "$ARRANGEMENT" || echo "display: displayplacer failed, launching anyway"
    sleep 1   # let the WindowServer settle before the window is sized to it
fi
exec "$ROOT/build/mirror_app/mirror_app" --fullscreen --no-panel
