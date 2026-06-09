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

# Code signing.
#
# SIGN_IDENTITY selects the signing identity:
#   - unset / "-"  -> ad-hoc signing (local dev only; the privileged Helper will
#                     NOT be accepted by launchd, so keep-awake cannot work).
#   - a Developer ID Application identity -> proper distribution signing with a
#                     hardened runtime, required for notarization and for the
#                     SMAppService Helper daemon to register.
#
# Sign from the inside out: embedded executables first, then the app bundle.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# sign_one <path>: code-signs a single target, choosing flags based on whether
# we have a real Developer ID identity. The identity is passed as its own quoted
# argument because it contains spaces.
sign_one() {
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - "$1"
    else
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
    fi
}

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "WARNING: ad-hoc signing (SIGN_IDENTITY unset). The privileged Helper will not register; distribute only after signing with a Developer ID identity." >&2
fi

sign_one "$APP_MACOS_DIR/com.stmtc.ccAwake.Helper"
sign_one "$APP_MACOS_DIR/ccawake-hook"
sign_one "$APP_MACOS_DIR/ccAwake"
sign_one "$APP_DIR"

# Verify the resulting signature so CI fails loudly on a broken bundle.
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign -dv --verbose=2 "$APP_DIR" 2>&1 | grep -E "TeamIdentifier|Authority=Developer" || true

echo "Built $APP_DIR"
echo "Open it with: open '$APP_DIR'"
