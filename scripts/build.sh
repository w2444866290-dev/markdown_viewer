#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/MarkdownViewer.app"

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/arm64-apple-macosx/release/MarkdownViewer" "$APP_DIR/Contents/MacOS/" 2>/dev/null || \
cp "$ROOT_DIR/.build/release/MarkdownViewer" "$APP_DIR/Contents/MacOS/"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Inject version into the bundled plist (NOT the source repo plist) so the UI can
# show which commit this binary was built from. The build SHA changes every build,
# letting the user verify they relaunched the latest binary.
PLIST="$APP_DIR/Contents/Info.plist"
BUILD_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.0" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_SHA" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_SHA" "$PLIST"
echo "injected version: v1.0.0 ($BUILD_SHA)"

codesign --force --deep --sign - "$APP_DIR"

if [[ "${1:-}" == "--zip" ]]; then
    ditto -c -k --keepParent "$APP_DIR" "$DIST_DIR/MarkdownViewer.zip"
fi

echo "$APP_DIR"
