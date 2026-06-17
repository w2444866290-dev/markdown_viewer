#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/MarkdownViewer.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/MarkdownViewer"

mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/Sources/MarkdownViewer/main.swift" \
  -o "$BUILD_DIR/MarkdownViewer-arm64"

swiftc -O \
  -target x86_64-apple-macos13.0 \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/Sources/MarkdownViewer/main.swift" \
  -o "$BUILD_DIR/MarkdownViewer-x86_64"

lipo -create \
  "$BUILD_DIR/MarkdownViewer-arm64" \
  "$BUILD_DIR/MarkdownViewer-x86_64" \
  -output "$EXECUTABLE"

codesign --force --deep --sign - "$APP_DIR"

if [[ "${1:-}" == "--zip" ]]; then
  ditto -c -k --keepParent "$APP_DIR" "$DIST_DIR/MarkdownViewer.zip"
fi

echo "$APP_DIR"

