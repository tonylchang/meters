#!/bin/bash
# Local compatibility proof only: no account/provisioning changes or uploads.
# Usage: scripts/app-store-check.sh <build-products-directory> <meters-probe>
set -euo pipefail

PRODUCTS="$1"
PROBE="$2"
APP="$PRODUCTS/AppStore/meters.app"
CHECK="$PRODUCTS/AppStore/meters-sandbox-check.app"
BASELINE="$PRODUCTS/Release/meters-sandbox-check.app"
REPORTS=build/app-store-check
SUITE="net.1x0.meters.checks.sandbox.$(uuidgen)"
PID=""
LOCK_FILE=""
MARKERS="$HOME/Library/Containers/net.1x0.meters/Data/tmp/$SUITE.markers"
STAMP="$(mktemp)"
mkdir -p "$REPORTS"
rm -f "$REPORTS/app.markers"

cleanup() {
    if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
    [ -z "$LOCK_FILE" ] || rm -f "$LOCK_FILE"
    # Only this run's unique suite, inside the app's sandbox container.
    local preferences="$HOME/Library/Containers/net.1x0.meters/Data/Library/Preferences/$SUITE"
    defaults delete "$preferences" >/dev/null 2>&1 || true
    rm -f "$preferences.plist" "$STAMP" "$MARKERS"
}
trap cleanup EXIT

scripts/audit.sh "$APP" --app-store
scripts/audit.sh "$CHECK" --app-store
scripts/audit.sh "$BASELINE"
for bundle in "$APP" "$CHECK"; do
    signature="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
    grep -q '^TeamIdentifier=6S59K4Y6Z7$' <<< "$signature"
    grep -q '^Authority=Apple Development:' <<< "$signature"
    grep -q 'flags=.*(runtime)' <<< "$signature"
done

status=0
"$BASELINE/Contents/MacOS/meters-sandbox-check" > "$REPORTS/baseline.json" 2> "$REPORTS/baseline.stderr" || status=1
"$CHECK/Contents/MacOS/meters-sandbox-check" --sandbox > "$REPORTS/sandbox.json" 2> "$REPORTS/sandbox.stderr" || status=1
python3 - "$REPORTS" <<'PY' || status=1
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for mode in ("baseline", "sandbox"):
    report = json.loads((root / (mode + ".json")).read_text())
    for check in report["checks"]:
        print(f'{mode}: {"PASS" if check["passed"] else "FAIL"}: {check["name"]}: {check["detail"]}')
baseline = json.loads((root / "baseline.json").read_text())
sandbox = json.loads((root / "sandbox.json").read_text())
for field in ("hasBattery", "networkDeviceNames"):
    if baseline[field] != sandbox[field]:
        sys.exit(f"app-store-check: FAIL: {field} differs across sandbox boundary")
PY

# Observe the real app externally, without changing its code or the user's settings.
if [ "$("$PROBE" session)" != 'locked=0 asleep=0' ]; then
    echo 'app-store-check: FAIL: needs an awake, unlocked display' >&2
    exit 1
fi
started="$("$PROBE" now)"
METERS_SETTINGS_SUITE="$SUITE" METERS_MARKER_FILE="$MARKERS" "$APP/Contents/MacOS/meters" > "$REPORTS/app.stdout" 2> "$REPORTS/app.stderr" &
PID=$!
found=0
for _ in $(seq 1 50); do
    "$PROBE" windows "$PID" > "$REPORTS/windows.txt"
    if grep -q '^layer=3 .*onscreen=1' "$REPORTS/windows.txt"; then found=1; break; fi
    sleep 0.05
done
if [ "$found" = 1 ]; then
    echo "app-store-check: HUD visible after $(echo "$("$PROBE" now) - $started" | bc)s"
else
    echo 'app-store-check: FAIL: no HUD during launch observation' >&2
    status=1
fi
for _ in $(seq 1 50); do
    if [ -f "$MARKERS" ] && grep -q '^first-data ' "$MARKERS"; then break; fi
    sleep 0.05
done
if [ -f "$MARKERS" ]; then cp "$MARKERS" "$REPORTS/app.markers"; fi
first="$(awk '$1 == "first-data" { print $2; exit }' "$REPORTS/app.markers" 2>/dev/null || true)"
if [ -n "$first" ]; then
    delay="$(echo "$first - $started" | bc)"
    echo "app-store-check: first data after ${delay}s"
    if (( $(echo "$delay > 1.0" | bc) )); then
        echo 'app-store-check: FAIL: first data exceeded 1 s' >&2
        status=1
    fi
else
    echo 'app-store-check: FAIL: no first-data marker' >&2
    status=1
fi
if grep -q '^layer=0 .*onscreen=1' "$REPORTS/windows.txt"; then
    echo 'app-store-check: FAIL: unexpected window at launch' >&2
    status=1
fi
app_type="$(lsappinfo info "$(lsappinfo find pid="$PID")" | grep -oE 'type="[A-Za-z]+"' | head -1)"
if [ "$app_type" != 'type="UIElement"' ]; then
    echo "app-store-check: FAIL: unexpected app type: $app_type" >&2
    status=1
fi
LOCK_FILE="$(lsof -a -p "$PID" -Fn 2>/dev/null | sed -n "s|^n\(.*$SUITE.instance.lock\)$|\1|p" | head -1)"
sleep 10
if ! kill -0 "$PID" 2>/dev/null; then
    echo 'app-store-check: FAIL: app exited within 10 s' >&2
    status=1
fi
if [ -d "$HOME/Library/Logs/DiagnosticReports" ] && find "$HOME/Library/Logs/DiagnosticReports" -name 'meters*' -newer "$STAMP" | grep -q .; then
    echo 'app-store-check: FAIL: new meters crash report' >&2
    status=1
fi
if [ "$status" = 0 ]; then
    echo 'app-store-check: PASS (local compatibility only; no archive uploaded)'
else
    echo "app-store-check: FAIL: see $REPORTS" >&2
fi
exit "$status"
