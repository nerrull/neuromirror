#!/bin/bash
# show-gate.sh -- decide whether today is a day the piece runs.
#
# Runs as root from net.jardinsracine.gate.plist: at boot, and every morning a
# minute after the scheduled wake. If today is not in show-days.txt it puts the
# machine straight back to sleep, so the pmset schedule can stay a simple
# every-day one and the actual calendar lives in a file anyone can edit.
#
#   show-gate.sh [--check]     --check reports and never sleeps
#
# Exit status: 0 today is a show day (or --check), 0 after sleeping otherwise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAYS_FILE="${RACINE_SHOW_DAYS:-$HERE/show-days.txt}"
MARKER=/Users/Shared/racine/keep-awake
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

TODAY="$(date '+%Y-%m-%d')"
log() { printf '%s show-gate: %s\n' "$(date '+%F %T')" "$*"; }

# Noon on both sides, so a comparison is never decided by the time of day the
# gate happens to run.
as_epoch() { date -j -f '%Y-%m-%d %H:%M:%S' "$1 12:00:00" '+%s' 2>/dev/null; }

is_show_day() {
    local today_s from to a b line
    today_s="$(as_epoch "$TODAY")"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [ -z "$line" ] && continue
        case "$line" in
            *..*) a="${line%%..*}"; b="${line##*..}";;
            *)    a="$line";        b="$line";;
        esac
        from="$(as_epoch "$a")" || { log "unreadable date '$a', skipped"; continue; }
        to="$(as_epoch "$b")"   || { log "unreadable date '$b', skipped"; continue; }
        [ "$today_s" -ge "$from" ] && [ "$today_s" -le "$to" ] && return 0
    done < "$DAYS_FILE"
    return 1
}

# Fail awake. A missing or unreadable list is a mistake in the setup, and the
# expensive way to be wrong about it is to sleep through an open day.
if [ ! -r "$DAYS_FILE" ]; then
    log "no readable $DAYS_FILE -- staying awake"
    exit 0
fi

if [ -e "$MARKER" ]; then
    log "$MARKER present -- staying awake regardless of the calendar"
    exit 0
fi

if is_show_day; then
    log "$TODAY is a show day"
    exit 0
fi

log "$TODAY is not a show day"
if [ "$CHECK" = 1 ]; then exit 0; fi

# Let the login session finish coming up first: sleeping into the middle of it
# is how you get a machine that wakes up confused about which display it has.
sleep 45
log "back to sleep"
pmset sleepnow
