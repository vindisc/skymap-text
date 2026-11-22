#!/bin/zsh
set -euo pipefail

# Zips the packaged app into dist/ for sharing: dist/SkyBook-<version>-macOS.zip

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$("$ROOT_DIR/scripts/make_app.sh" release | tail -n 1)"
VERSION="$(head -n 1 "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/SkyBook-$VERSION-macOS.zip"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/SkyBook.app" "$DIST_DIR/SkymapText.app"
cp -R "$APP_PATH" "$DIST_DIR/SkyBook.app"
cd "$DIST_DIR"
/usr/bin/ditto -c -k --keepParent "SkyBook.app" "$ZIP_PATH"
echo "$ZIP_PATH"
