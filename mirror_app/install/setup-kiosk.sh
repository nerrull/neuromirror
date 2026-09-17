#!/bin/bash
# setup-kiosk.sh -- the scriptable half of the installation setup.
#
# Dry-run by default: it prints what it would do and changes nothing. Pass
# --apply to actually do it. Everything here is idempotent.
#
#   ./setup-kiosk.sh [--apply] [--user expo] [--from 09:30] [--to 18:30]
#   ./setup-kiosk.sh [--apply] [--user expo] --launch-only
#
# --launch-only is the half of this that makes the piece come up at login and
# stay up: readable tree, LaunchAgent, no idle sleep, and Start/Stop shortcuts
# on the kiosk user's desktop. No show-day gate, no autorestart, no schedule.
#
# What it does NOT do, because it cannot or should not be scripted:
#   * create the kiosk account, or set automatic login
#   * grant camera / microphone permission (a human clicks Allow, once)
#   * install Jump Desktop Connect
#   * schedule the expo days' power-on (--from/--to only print the pmset line)
# README.md walks those through in order.
set -euo pipefail

APPLY=0
KIOSK_USER=expo
FROM=09:30
TO=22:00
LAUNCH_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift;;
        --user)  KIOSK_USER="$2"; shift 2;;
        --from)  FROM="$2"; shift 2;;
        --to)    TO="$2"; shift 2;;
        --launch-only) LAUNCH_ONLY=1; shift;;
        *) echo "unknown argument: $1" >&2; exit 1;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="$ROOT/build/mirror_app/mirror_app"
LOG_DIR=/Users/Shared/racine/logs
LABEL=net.jardinsracine.mirror

run() {
    if [ "$APPLY" = 1 ]; then echo "+ $*"; "$@"
    else echo "  would: $*"; fi
}

fail() { echo "error: $*" >&2; exit 1; }

echo "== checks"
# The binary bakes its asset, shader, show and sound-bank paths in at compile
# time, and links MLX, MediaPipe and libfreenect2 by absolute rpath. If the
# tree still sits under a home directory, the kiosk user cannot read any of
# it -- home directories are 0700 -- and no amount of launchd fixes that.
case "$ROOT" in
    /Users/Shared/*) ;;
    *) fail "the checkout is at $ROOT; move it under /Users/Shared and rebuild
       there, or the kiosk account cannot read its assets (see README.md)";;
esac
[ -x "$BIN" ] || fail "$BIN is not built yet -- cmake --build build --target mirror_app"
id -u "$KIOSK_USER" >/dev/null 2>&1 || fail "no such user: $KIOSK_USER (create it first)"
dsmemberutil checkmembership -U "$KIOSK_USER" -G admin 2>/dev/null | grep -q "is not a member" \
    || echo "  WARNING: $KIOSK_USER is an admin account -- it should be Standard"
codesign -dv "$BIN" 2>&1 | grep -q "Signature=adhoc" \
    && echo "  WARNING: $BIN is ad-hoc signed; its camera grant will not survive a rebuild"
echo "  ok: $ROOT"

HOME_DIR="$(dscl . -read "/Users/$KIOSK_USER" NFSHomeDirectory | awk '{print $2}')"
AGENT_DIR="$HOME_DIR/Library/LaunchAgents"

echo
echo "== readable tree, writable state"
run chmod -R a+rX "$ROOT"
# The app writes these three back: panel layout, panel placement, and any
# preset saved from the panel during the run.
for f in "$ROOT/imgui.ini" "$ROOT/mirror_panel.ini"; do
    [ -e "$f" ] && run chmod a+w "$f"
done
run chmod -R a+w "$ROOT/mirror_app/presets"
run mkdir -p "$LOG_DIR"
run chmod 1777 "$LOG_DIR"

echo
echo "== launch agent"
run mkdir -p "$AGENT_DIR"
tmp="$(mktemp)"
sed -e "s|@MIRROR_BIN@|$BIN|g" \
    -e "s|@RACINE_ROOT@|$ROOT|g" \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    "$HERE/$LABEL.plist.in" > "$tmp"
if [ "$APPLY" = 1 ]; then
    install -m 644 "$tmp" "$AGENT_DIR/$LABEL.plist"
    chown "$KIOSK_USER" "$AGENT_DIR/$LABEL.plist"
    echo "+ wrote $AGENT_DIR/$LABEL.plist"
else
    echo "  would write $AGENT_DIR/$LABEL.plist:"
    sed 's/^/    | /' "$tmp"
fi
rm -f "$tmp"

echo
echo "== desktop shortcuts"
# Double-clickable from the kiosk desktop: Cmd-Tab out of the piece (it is a
# borderless window, not a video mode, so the desktop is still there), open
# the shortcut, done. Stop unloads the agent for this login session, so
# KeepAlive does not bring the piece back and the user can log out; the
# agent is still in LaunchAgents, so the next login starts it again.
DESKTOP="$HOME_DIR/Desktop"
for action in start stop; do
    f="$DESKTOP/$(tr a-z A-Z <<<"${action:0:1}")${action:1} Racine.command"
    if [ "$APPLY" = 1 ]; then
        printf '#!/bin/bash\n"%s/racine" %s\n' "$HERE" "$action" > "$f"
        chmod 755 "$f"; chown "$KIOSK_USER" "$f"
        echo "+ wrote $f"
    else
        echo "  would write $f -> racine $action"
    fi
done

if [ "$LAUNCH_ONLY" = 1 ]; then
    echo
    echo "== power behaviour (launch-only: no idle sleep, nothing else)"
    run pmset -a displaysleep 0 sleep 0
    echo
    echo "== not done here -- see README.md"
    cat <<NOTE
  1. Automatic login for $KIOSK_USER (System Settings > Users & Groups),
     which requires FileVault to be OFF.
  2. Camera + microphone permission: log in as $KIOSK_USER, run
     $BIN once from Terminal, click Allow.
  Skipped (--launch-only): the show-day gate, autorestart, wake-for-network,
  and the daily wake/sleep schedule. Run again without --launch-only for those.
NOTE
    exit 0
fi

echo
echo "== show-day gate"
# The pmset schedule below wakes the machine every morning; this daemon is
# what makes most of those mornings end immediately. Which days are which
# lives in show-days.txt, so changing the calendar never touches pmset.
GATE_H="${FROM%%:*}"
GATE_M="$(( 10#${FROM##*:} + 1 ))"
if [ "$GATE_M" -ge 60 ]; then GATE_M=$(( GATE_M - 60 )); GATE_H=$(( 10#$GATE_H + 1 )); fi
[ -r "$HERE/show-days.txt" ] || echo "  WARNING: no show-days.txt -- the gate will fail awake, every day"
tmp2="$(mktemp)"
sed -e "s|@GATE_SH@|$HERE/show-gate.sh|g" \
    -e "s|@GATE_HOUR@|$(( 10#$GATE_H ))|g" \
    -e "s|@GATE_MINUTE@|$GATE_M|g" \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    "$HERE/net.jardinsracine.gate.plist.in" > "$tmp2"
if [ "$APPLY" = 1 ]; then
    install -m 644 -o root -g wheel "$tmp2" "/Library/LaunchDaemons/net.jardinsracine.gate.plist"
    launchctl bootout system/net.jardinsracine.gate 2>/dev/null || true
    launchctl bootstrap system "/Library/LaunchDaemons/net.jardinsracine.gate.plist"
    echo "+ installed the gate daemon (checks at boot and $GATE_H:$(printf %02d "$GATE_M"))"
else
    echo "  would install /Library/LaunchDaemons/net.jardinsracine.gate.plist,"
    echo "  checking at boot and at $GATE_H:$(printf %02d "$GATE_M") daily"
fi
rm -f "$tmp2"

echo
echo "== power behaviour"
# Never sleep or blank on idle -- but NOT `disablesleep 1`, which is the
# bigger hammer: it would also block the scheduled nightly sleep that ends
# each show day. See README.md, "Ending the day".
run pmset -a displaysleep 0 sleep 0
run pmset -a disablesleep 0
# Come back on after a power cut, and after power is reconnected -- the
# second is what makes a wall timer on the socket a working day scheduler.
run pmset -a autorestart 1
run pmset -a autorestartatconnect 1
run pmset -a womp 1                 # wake for network, so Jump Desktop can reach it
run systemsetup -setrestartfreeze on 2>/dev/null || true

echo
echo "== not done here -- see README.md"
cat <<NOTE
  1. Automatic login for $KIOSK_USER (System Settings > Users & Groups),
     which requires FileVault to be OFF.
  2. Camera + microphone permission: log in as $KIOSK_USER, run
     $BIN once from Terminal, click Allow.
  3. Jump Desktop Connect, installed for all users, with Screen Recording
     and Accessibility granted in the $KIOSK_USER session.
  4. The daily schedule. Every day, deliberately -- the gate decides which
     mornings survive. On Apple silicon use sleep, not shutdown: scheduled
     power-on from a full shutdown is not supported there, so a shutdown is a
     day that never starts again.
       sudo pmset repeat wakeorpoweron MTWRFSU $FROM:00 sleep MTWRFSU $TO:00
     and afterwards:  sudo pmset repeat cancel
  5. The dates themselves, in install/show-days.txt.
NOTE
[ "$APPLY" = 1 ] || echo "
(dry run -- nothing changed. Re-run with --apply, as root, to do it.)"
