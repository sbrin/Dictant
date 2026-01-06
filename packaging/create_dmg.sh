#!/usr/bin/env bash

# Build a polished distribution DMG using the create-dmg utility.
# Usage: ./packaging/create_dmg.sh [/path/to/Dictant.app] [Dictant.dmg]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-"$ROOT/build/DerivedData/Build/Products/Release/Dictant.app"}"
DMG_NAME="${2:-Dictant.dmg}"

DMG_PATH="$ROOT/build/$DMG_NAME"

# Use a temp workspace without spaces because create-dmg/hdiutil can be brittle with them.
TMP_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/Dictant-dmg.XXXXXX")"
cleanup() { rm -rf "$TMP_WORKDIR"; }
trap cleanup EXIT

STAGE_DIR="$TMP_WORKDIR/dmg-stage"
ASSETS_DIR="$TMP_WORKDIR/dmg-assets"
BACKGROUND="$ASSETS_DIR/dmg-background.png"

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at: $APP_PATH" >&2
  exit 1
fi

APP_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
if [[ ! -f "$APP_ICON" ]]; then
  echo "Warning: App icon not found at $APP_ICON. The DMG will use the default volume icon." >&2
fi

mkdir -p "$ASSETS_DIR"

# Generate a simple gradient background without external dependencies.
python3 - "$BACKGROUND" <<'PY'
import pathlib
import struct
import sys
import zlib

dest = pathlib.Path(sys.argv[1]).expanduser()
dest.parent.mkdir(parents=True, exist_ok=True)

width, height = 960, 640
top = (24, 38, 68)
bottom = (58, 120, 210)

def lerp(a, b, t):
    return int(a + (b - a) * t)

rows = []
for y in range(height):
    ty = y / (height - 1)
    row = bytearray()
    row.append(0)  # PNG filter type 0 for this scanline.
    for x in range(width):
        # Soft horizontal vignette plus vertical gradient.
        vignette = 0.85 + 0.15 * (1 - abs((x - width / 2) / (width / 2)))
        color = [min(255, int(lerp(a, b, ty) * vignette)) for a, b in zip(top, bottom)]
        row.extend(color)
    rows.append(bytes(row))

raw = b"".join(rows)

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b"")
)

dest.write_bytes(png)
print(f"Wrote background to {dest}")
PY

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/Dictant.app"

rm -f "$DMG_PATH"

CREATE_DMG_ARGS=(
  --volname "Dictant"
  --window-size 720 520
  --window-pos 200 120
  --text-size 12
  --icon-size 120
  --icon "Dictant.app" 170 230
  --app-drop-link 520 230
  --background "$BACKGROUND"
  --no-internet-enable
  --skip-jenkins
  --sandbox-safe
  --hdiutil-quiet
)

if [[ -f "$APP_ICON" ]]; then
  CREATE_DMG_ARGS+=(--volicon "$APP_ICON")
fi

set +e
create-dmg "${CREATE_DMG_ARGS[@]}" "$TMP_WORKDIR/Dictant.dmg" "$STAGE_DIR"
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  echo "create-dmg failed (exit $STATUS). Leaving temp folder at $TMP_WORKDIR for inspection."
  exit $STATUS
fi

mkdir -p "$ROOT/build"
mv "$TMP_WORKDIR/Dictant.dmg" "$DMG_PATH"
echo "DMG created at: $DMG_PATH"
