#!/bin/bash
# make audit: enforce constraints on the built Release app.
#   1. No private frameworks linked: they are out of scope for v1.
#   2. No networking APIs referenced: v1 makes no outbound connections.
#   3. No entitlements beyond the approved list, which is empty until the maintainer approves one.
#
# usage: scripts/audit.sh <path/to/meters.app>

set -euo pipefail

APP="$1"
APPROVED_ENTITLEMENTS=()
NETWORK_SYMBOLS='URLSession|NSURLConnection|NSURLDownload|_nw_|CFSocket|CFStreamCreatePairWithSocket|CFHTTP|CFNetService|_getaddrinfo$|_socket$|_connect$'
NETWORK_FRAMEWORKS='/Network\.framework|/CFNetwork\.framework'

status=0
fail() { echo "audit: FAIL: $*" >&2; status=1; }

binaries=()
while IFS= read -r file; do
    file -b "$file" | grep -q 'Mach-O' && binaries+=("$file")
done < <(find "$APP" -type f -perm -u+x)
[ "${#binaries[@]}" -gt 0 ] || { echo "audit: FAIL: no Mach-O binaries in $APP" >&2; exit 1; }

for binary in "${binaries[@]}"; do
    name="${binary#"$APP"/}"
    if otool -L "$binary" | grep -q '/PrivateFrameworks/'; then
        fail "$name links a private framework: $(otool -L "$binary" | grep '/PrivateFrameworks/' | xargs)"
    fi
    if otool -L "$binary" | grep -Eq "$NETWORK_FRAMEWORKS"; then
        fail "$name links a networking framework"
    fi
    symbols="$(nm -u "$binary" 2>/dev/null | grep -E "$NETWORK_SYMBOLS" || true)"
    [ -z "$symbols" ] || fail "$name references networking APIs: $(echo "$symbols" | xargs)"
done

entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert json -o - - 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).keys()))' 2>/dev/null || true)"
for key in $entitlements; do
    approved=0
    for allowed in ${APPROVED_ENTITLEMENTS[@]+"${APPROVED_ENTITLEMENTS[@]}"}; do
        [ "$key" = "$allowed" ] && approved=1
    done
    [ "$approved" -eq 1 ] || fail "unapproved entitlement: $key"
done

[ "$status" -eq 0 ] && echo "audit: PASS (${#binaries[@]} binaries checked, no private frameworks, no networking, no entitlements)"
exit "$status"
