#!/bin/bash
# make perf: measure the performance targets on the Release app, in isolated settings:
#   - time to first data: within 1 s of launch
#   - self CPU: under 1% of one core, averaged over a 5-minute window after a 10 s warm-up
#   - resident memory: physical footprint under 50 MB at the end of the window (the figure Activity
#     Monitor shows as Memory; RSS is reported too but overstates it by counting shared framework pages)
#
# The run shows every module in its largest form (13 rows); PERF_MODULES=default
# measures the first-launch HUD (CPU, MEM, and one-row NET) instead. PERF_GRAPHS=gauges shows gauges in place of
# sparklines.
# PERF_RATE_FORM=oneRow exercises Network and Disk's device labels with every module still enabled.
#
# usage: scripts/perf.sh <path/to/meters.app> <path/to/meters-probe>
# PERF_SECONDS overrides the 300 s window for quick local runs; the check requires the full window.

set -euo pipefail

APP="$1"
PROBE="$2"
BIN="$APP/Contents/MacOS/meters"
SUITE="net.1x0.meters.checks"
WINDOW="${PERF_SECONDS:-300}"
WARMUP=10
RATE_FORM="${PERF_RATE_FORM:-twoRows}"

fail() { echo "perf: FAIL: $*" >&2; exit 1; }

[[ "$RATE_FORM" = oneRow || "$RATE_FORM" = twoRows ]] || fail "unknown rate form: $RATE_FORM"

# Physical footprint of a process in MB, from vmmap (for example "Physical footprint: 16.3M").
footprint_mb() {
    vmmap --summary "$1" 2>/dev/null | awk -F: '/^Physical footprint:/ {
        gsub(/ /, "", $2); value = $2 + 0; unit = substr($2, length($2))
        if (unit == "K") value /= 1024; else if (unit == "G") value *= 1024
        printf "%.1f\n", value; exit
    }'
}

# Cumulative CPU seconds for a process, from ps's [[dd-]hh:]mm:ss.ss format.
cpu_seconds() {
    ps -o time= -p "$1" | awk '{
        n = split($1, parts, ":"); total = 0
        for (i = 1; i <= n; i++) total = total * 60 + parts[i]
        print total
    }'
}

defaults delete "$SUITE" >/dev/null 2>&1 || true
MARKERS="$(mktemp)"

if [ "${PERF_MODULES:-all}" = all ]; then
    SEED="$(mktemp)"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<plist version="1.0"><dict><key>hudModules</key><array>'
        for id in cpu memory gpu network disk battery thermal swap freeSpace; do
            echo "<dict><key>id</key><string>$id</string><key>on</key><true/></dict>"
        done
        echo '</array>'
        echo '<key>cpuForm</key><string>clusters</string>'
        echo "<key>networkForm</key><string>$RATE_FORM</string>"
        echo "<key>diskForm</key><string>$RATE_FORM</string>"
        [ "${PERF_GRAPHS:-sparklines}" = gauges ] && echo '<key>hudGraphs</key><string>gauges</string>'
        echo '</dict></plist>'
    } > "$SEED"
    defaults import "$SUITE" "$SEED"
    rm -f "$SEED"
    echo "perf: every module, largest CPU form, $RATE_FORM rates, ${PERF_GRAPHS:-sparklines}"
else
    echo "perf: first-launch modules"
fi

# Modules pause rendering while the HUD is not visible, so a locked screen or sleeping display would
# understate the cost of rendering. Require an unlocked, awake display for the whole window.
require_awake_session() {
    local session
    session="$("$PROBE" session)"
    [ "$session" = "locked=0 asleep=0" ] \
        || fail "$1: $session; rendering pauses while the HUD is not visible, so the measurement would not be representative"
}

require_awake_session "at start"
started="$("$PROBE" now)"
METERS_SETTINGS_SUITE="$SUITE" METERS_MARKER_FILE="$MARKERS" "$BIN" >/dev/null 2>&1 &
PID=$!
cleanup() {
    kill "$PID" 2>/dev/null || true
    # Let the app finish exiting first, so it cannot write its settings back after they are deleted.
    wait "$PID" 2>/dev/null || true
    defaults delete "$SUITE" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$SUITE.plist" "${TMPDIR:-/tmp}/$SUITE.instance.lock"
    rm -f "$MARKERS"
}
trap cleanup EXIT

for _ in $(seq 1 50); do
    grep -q '^first-data ' "$MARKERS" && break
    sleep 0.1
done
first="$(awk '$1 == "first-data" { print $2; exit }' "$MARKERS")"
[ -n "$first" ] || fail "no first-data marker within 5 s"
ttfd="$(echo "$first - $started" | bc)"

sleep "$WARMUP"
kill -0 "$PID" 2>/dev/null || fail "app exited during warm-up"
cpu_start="$(cpu_seconds "$PID")"
sleep "$WINDOW"
kill -0 "$PID" 2>/dev/null || fail "app exited during the measurement window"
cpu_end="$(cpu_seconds "$PID")"
require_awake_session "at end"
rss_kb="$(ps -o rss= -p "$PID" | tr -d ' ')"
footprint="$(footprint_mb "$PID")"
[ -n "$footprint" ] || fail "could not read the physical footprint"

cpu_percent="$(echo "scale=3; ($cpu_end - $cpu_start) * 100 / $WINDOW" | bc)"
rss_mb="$(echo "scale=1; $rss_kb / 1024" | bc)"

echo "perf: time to first data  ${ttfd} s   (target: 1.0 s or less)"
echo "perf: average self CPU    ${cpu_percent}% of one core over ${WINDOW} s   (target: under 1%)"
echo "perf: resident memory     ${footprint} MB physical footprint   (target: under 50 MB; RSS ${rss_mb} MB)"

status=0
(( $(echo "$ttfd <= 1.0" | bc) )) || { echo "perf: FAIL: time to first data" >&2; status=1; }
(( $(echo "$cpu_percent < 1.0" | bc) )) || { echo "perf: FAIL: self CPU" >&2; status=1; }
(( $(echo "$footprint < 50" | bc) )) || { echo "perf: FAIL: resident memory" >&2; status=1; }
[ "$WINDOW" -ge 300 ] || { echo "perf: FAIL: window shorter than the required 300 s" >&2; status=1; }
[ "$status" -eq 0 ] && echo "perf: PASS"
exit "$status"
