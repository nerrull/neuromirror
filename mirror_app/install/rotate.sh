#!/bin/bash
# rotate.sh -- apply the saved display arrangement (`racine display save`).
#
# Display rotation is a per-user preference that macOS re-applies unreliably
# on fast user switching and at login, so it is set explicitly instead: by
# launch.sh before the piece starts, and by a per-account LaunchAgent at
# login for anyone else who works on this machine. One displayplacer call
# per screen, not one for the arrangement: a screen that is not there today
# (a virtual display, an unplugged monitor) fails on its own and the others
# still apply. No saved arrangement or no displayplacer: does nothing.
set -u
ARRANGEMENT=/Users/Shared/racine/display.sh
DISPLAYPLACER=/opt/homebrew/bin/displayplacer
[ -r "$ARRANGEMENT" ] && [ -x "$DISPLAYPLACER" ] || exit 0
eval "set -- $(sed 's/^displayplacer //' "$ARRANGEMENT")"
for screen in "$@"; do
    echo "display: $screen"
    "$DISPLAYPLACER" "$screen" || echo "display: not applied (screen absent?)"
done
