#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/.build/ccAwake.app"
APP_CONTENTS_DIR="$APP_DIR/Contents"
APP_MACOS_DIR="$APP_DIR/Contents/MacOS"
APP_RESOURCES_DIR="$APP_DIR/Contents/Resources"
APP_LAUNCH_DAEMONS_DIR="$APP_DIR/Contents/Library/LaunchDaemons"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"

swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR" "$APP_LAUNCH_DAEMONS_DIR"

cp "$ROOT_DIR/Packaging/Info.plist" "$APP_CONTENTS_DIR/Info.plist"
cp "$BUILD_DIR/ccAwakeApp" "$APP_MACOS_DIR/ccAwake"
cp "$BUILD_DIR/ccawake-hook" "$APP_MACOS_DIR/ccawake-hook"
cp "$BUILD_DIR/ccAwakeHelper" "$APP_MACOS_DIR/com.stmtc.ccAwake.Helper"
cp "$ROOT_DIR/Packaging/com.stmtc.ccAwake.Helper.plist" "$APP_LAUNCH_DAEMONS_DIR/com.stmtc.ccAwake.Helper.plist"
cp -R "$ROOT_DIR/Resources/"*.lproj "$APP_RESOURCES_DIR/"

chmod 755 "$APP_MACOS_DIR/ccAwake" "$APP_MACOS_DIR/ccawake-hook" "$APP_MACOS_DIR/com.stmtc.ccAwake.Helper"

codesign --force --sign - "$APP_MACOS_DIR/com.stmtc.ccAwake.Helper"
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
echo "Open it with: open '$APP_DIR'"
