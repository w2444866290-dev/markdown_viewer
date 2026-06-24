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

codesign --force --deep --sign - "$APP_DIR"

if [[ "${1:-}" == "--zip" ]]; then
    ditto -c -k --keepParent "$APP_DIR" "$DIST_DIR/MarkdownViewer.zip"
fi

echo "$APP_DIR"
