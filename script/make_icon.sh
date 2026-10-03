#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICON_DIR" Resources
swift script/make_icon.swift "$ICON_DIR/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_DIR/icon_512x512@2x.png" --out "$ICON_DIR/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  if [ "$size" != 512 ]; then sips -z "$twice" "$twice" "$ICON_DIR/icon_512x512@2x.png" --out "$ICON_DIR/icon_${size}x${size}@2x.png" >/dev/null; fi
done
iconutil -c icns "$ICON_DIR" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICON_DIR")"
