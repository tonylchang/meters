#!/bin/bash
# Render the approved website SVG with macOS tools; no runtime dependency or image service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/App/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d -t meters-app-icon)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTPUT"
qlmanage -t -s 1024 -o "$WORK" "$ROOT/Tools/AppIcon/meters.svg" >/dev/null

for size in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        [ "$scale" = 1 ] || suffix="@2x"
        pixels=$((size * scale))
        sips -z "$pixels" "$pixels" "$WORK/meters.svg.png" \
            --out "$OUTPUT/icon_${size}x${size}${suffix}.png" >/dev/null
    done
done
python3 - "$OUTPUT" <<'PY'
import json, pathlib, sys
output = pathlib.Path(sys.argv[1])
images = [
    {"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x",
     "filename": f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'}
    for size in (16, 32, 128, 256, 512) for scale in (1, 2)
]
info = {"author": "xcode", "version": 1}
(output / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")
(output.parent / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")
PY
echo "Generated all 10 macOS icon representations in $OUTPUT"
