#!/bin/bash
# launch.sh -- what the LaunchAgent runs: put the display right, then the piece.
#
# rotate.sh applies the arrangement saved by `racine display save`; see it
# for why. Whatever it manages, the piece still starts.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
"$HERE/rotate.sh"
sleep 1   # let the WindowServer settle before the window is sized to it
# --no-mic: any open audio input puts macOS's orange recording dot on the
# piece, and the mic only scales the root scene's key light.
exec "$ROOT/build/mirror_app/mirror_app" --fullscreen --no-panel --no-mic
