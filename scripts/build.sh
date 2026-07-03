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
# Marketing version is a single source of truth in the repo-root VERSION file, bumped
# per release; the build SHA stays the CFBundleVersion so the user can confirm they
# relaunched the exact binary. Fall back to 1.0.0 if VERSION is missing/empty.
MARKETING_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null)"
[[ -n "$MARKETING_VERSION" ]] || MARKETING_VERSION="1.0.0"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $MARKETING_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_SHA" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_SHA" "$PLIST"
echo "injected version: v$MARKETING_VERSION ($BUILD_SHA)"

codesign --force --deep --sign - "$APP_DIR"

if [[ "${1:-}" == "--zip" ]]; then
    ditto -c -k --keepParent "$APP_DIR" "$DIST_DIR/MarkdownViewer.zip"
fi

echo "$APP_DIR"
