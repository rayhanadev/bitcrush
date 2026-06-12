#!/usr/bin/env bash
# Render the app icon → build/AppIcon.icns
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p build
swift scripts/make-icon.swift build/icon_1024.png

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

gen() { sips -z "$2" "$2" build/icon_1024.png --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
gen icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET" -o build/AppIcon.icns
echo "built build/AppIcon.icns"
