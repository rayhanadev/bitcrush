#!/usr/bin/env bash
# Build a release Bitcrush<3.app bundle, ready to run / drop into /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/Bitcrush<3.app"
CONTENTS="$APP/Contents"

echo "▸ icon"
bash scripts/make-icon.sh

echo "▸ release build"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Plunk"

echo "▸ assemble bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Plunk"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp build/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

echo "▸ ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "✓ built $APP"
echo "  run it:      open '$APP'"
echo "  install it:  cp -R '$APP' /Applications/"
