#!/bin/bash
# make smoke: launch the built app in isolated settings and confirm
#   - the HUD window appears within 1 s at the floating layer, sized to its default modules
#   - no other window opens at launch
#   - the menu bar item exists within 1 s with a template icon, and the app is an agent app
#   - a second launch hands off to the running instance, which shows its hidden HUD, and exits; opening
#     the running app does the same without starting another instance
#   - the app stays up for 10 s and leaves no crash report
# The user's own settings domain is never touched.
#
# Existence and layer come from the window server. Size and the menu bar item come from the app's own
# markers, because the window server scales window bounds while the screen is locked and does not
# reliably list menu bar items.
#
# usage: scripts/smoke.sh <path/to/meters.app> <path/to/meters-probe>

set -euo pipefail

APP="$1"
PROBE="$2"
BIN="$APP/Contents/MacOS/meters"
SUITE="net.1x0.meters.checks"
# Padding plus the default modules, 4 pt apart: CPU, MEM, and one-row NET. The one-row NET row, with room
# for one device name, is the widest.
EXPECTED_WIDTH=188
EXPECTED_HEIGHT=78
FLOATING_LAYER=3
REPORTS="$HOME/Library/Logs/DiagnosticReports"

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }

elapsed_since() { echo "$("$PROBE" now) - $1" | bc; }

# Prints the HUD window's line for a process, if it has one at the floating layer.
hud_window() { "$PROBE" windows "$1" | awk -v layer="$FLOATING_LAYER" '$1 == "layer=" layer' | head -1; }

# Waits up to $2 seconds for the HUD of process $1 to be on screen (want=1) or off screen (want=0).
wait_for_hud() {
    local pid="$1" timeout="$2" want="$3" start
    start="$("$PROBE" now)"
    while :; do
        local onscreen=0
        hud_window "$pid" | grep -q 'onscreen=1' && onscreen=1
        [ "$onscreen" = "$want" ] && return 0
        (( $(echo "$(elapsed_since "$start") > $timeout" | bc) )) && return 1
        sleep 0.05
    done
}

defaults delete "$SUITE" >/dev/null 2>&1 || true
START_STAMP="$(mktemp)"
MARKERS="$(mktemp)"

echo "smoke: session $("$PROBE" session)"
started="$("$PROBE" now)"
METERS_SETTINGS_SUITE="$SUITE" METERS_MARKER_FILE="$MARKERS" "$BIN" >/dev/null 2>&1 &
PID=$!
SECOND=""
cleanup() {
    kill "$PID" 2>/dev/null || true
    [ -n "$SECOND" ] && kill "$SECOND" 2>/dev/null || true
    # Let the app finish exiting first, so it cannot write its settings back after they are deleted.
    wait 2>/dev/null || true
    defaults delete "$SUITE" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$SUITE.plist" "${TMPDIR:-/tmp}/$SUITE.instance.lock"
    rm -f "$START_STAMP" "$MARKERS"
}
trap cleanup EXIT

# 1. The HUD window appears within 1 s of launch, above the normal window layer.
wait_for_hud "$PID" 1.0 1 || fail "no HUD window at layer $FLOATING_LAYER within 1 s"
echo "smoke: HUD window at layer $FLOATING_LAYER after $(elapsed_since "$started")s"

# 2. The HUD opens as wide and as tall as its modules need.
frame="$(awk '$1 == "hud-frame" { print $3, $4, $5, $6; exit }' "$MARKERS")"
[ -n "$frame" ] || fail "no hud-frame marker"
echo "smoke: HUD frame (x y width height) $frame"
[ "$(echo "$frame" | awk '{ print $3 }')" = "$EXPECTED_WIDTH" ] || fail "HUD width is not $EXPECTED_WIDTH pt"
[ "$(echo "$frame" | awk '{ print $4 }')" = "$EXPECTED_HEIGHT" ] || fail "HUD height is not $EXPECTED_HEIGHT pt"

# 3. The menu bar item exists within 1 s of launch, visible, with a template icon.
item="$(awk '$1 == "status-item" { print $2, $3, $4; exit }' "$MARKERS")"
[ -n "$item" ] || fail "no status-item marker"
item_delay="$(echo "$(echo "$item" | awk '{ print $1 }') - $started" | bc)"
(( $(echo "$item_delay <= 1.0" | bc) )) || fail "menu bar item appeared after ${item_delay}s"
[ "$(echo "$item" | awk '{ print $2, $3 }')" = "1 1" ] || fail "menu bar item not visible with a template icon"
echo "smoke: menu bar item after ${item_delay}s, visible, template icon"

# 3b. A launch, including one at login, opens no window but the HUD: Settings stays closed.
normal="$("$PROBE" windows "$PID" | awk '$1 == "layer=0" && /onscreen=1/' | wc -l | tr -d ' ')"
[ "$normal" = "0" ] || fail "launch opened $normal window(s) besides the HUD"
echo "smoke: no window but the HUD on screen"

# 4. The app is an agent app: no Dock icon, no app switcher entry.
app_type="$(lsappinfo info "$(lsappinfo find pid="$PID")" | grep -oE 'type="[A-Za-z]+"' | head -1)"
[ "$app_type" = 'type="UIElement"' ] || fail "app type is $app_type, expected UIElement"
echo "smoke: app type $app_type"

# 5. A second launch shows the hidden HUD of the running instance and exits.
defaults write "$SUITE" hudVisible -bool false
wait_for_hud "$PID" 2 0 || fail "HUD did not hide after hudVisible was set to false"
METERS_SETTINGS_SUITE="$SUITE" "$BIN" >/dev/null 2>&1 &
SECOND=$!
wait_for_hud "$PID" 2 1 || fail "second launch did not bring back the HUD"
for _ in $(seq 1 60); do kill -0 "$SECOND" 2>/dev/null || break; sleep 0.05; done
kill -0 "$SECOND" 2>/dev/null && fail "second instance did not exit"
SECOND=""
echo "smoke: second launch handed off and exited"

# 6. Opening the running app brings back a hidden HUD without a new instance. Skipped when another
#    meters instance (such as the user's own) is running, so the check never touches it.
if [ "$(pgrep -x meters | wc -l | tr -d ' ')" = "1" ]; then
    defaults write "$SUITE" hudVisible -bool false
    wait_for_hud "$PID" 2 0 || fail "HUD did not hide before the reopen check"
    open "$APP"
    wait_for_hud "$PID" 2 1 || fail "opening the running app did not bring back the HUD"
    sleep 0.5
    [ "$(pgrep -x meters | wc -l | tr -d ' ')" = "1" ] || fail "opening the running app started another instance"
    echo "smoke: opening the running app brought back the HUD"
else
    echo "smoke: SKIPPED reopen via open: another meters instance is running"
fi

# 7. Still running after 10 s.
sleep 10
kill -0 "$PID" 2>/dev/null || fail "app exited within 10 s"

# 8. No new crash report.
if [ -d "$REPORTS" ] && find "$REPORTS" -name 'meters*' -newer "$START_STAMP" | grep -q .; then
    fail "new crash report in $REPORTS"
fi

echo "smoke: PASS"
