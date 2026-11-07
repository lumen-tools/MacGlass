#!/bin/bash
# Builds MacGlass.app (universal) into build/:
#   scripts/make-app.sh [librashader-dir] [shaders-dir]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIBRA=${1:-$ROOT/build/librashader}
SHADERS=${2:-$ROOT/build/Shaders}
LIBRA=$(cd "$LIBRA" && pwd)
SHADERS=$(cd "$SHADERS" && pwd)
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
APP=$ROOT/build/MacGlass.app
cd "$ROOT"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$BIN/MacGlass" "$APP/Contents/MacOS/MacGlass"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/${GITHUB_RUN_NUMBER:-1}/g" Resources/Info.plist > "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$ROOT/build/AppIcon.iconset" && iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" \
  || echo "warning: app icon could not be created"
cp "$LIBRA/librashader.dylib" "$APP/Contents/Frameworks/"
cp -R "$SHADERS" "$APP/Contents/Resources/Shaders"
cp LICENSE "$APP/Contents/Resources/Licenses/LICENSE-MacGlass.txt"
cp "$LIBRA"/LICENSE-librashader*.md "$APP/Contents/Resources/Licenses/"
[ -f "$SHADERS/rc/LICENSE" ] && cp "$SHADERS/rc/LICENSE" "$APP/Contents/Resources/Licenses/LICENSE-RetroCrisis.txt"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature (no hardened runtime, so the bundled librashader.dylib can be loaded).
codesign --force --sign - "$APP/Contents/Frameworks/librashader.dylib"
codesign --force --sign - "$APP"
codesign --verify --deep "$APP"
lipo -info "$APP/Contents/MacOS/MacGlass"
du -sh "$APP"
