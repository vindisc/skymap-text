#!/bin/zsh
set -euo pipefail

# Assembles a runnable SkyBook.app from the SwiftPM build, mirroring the
# skymap-mac packaging recipe. The storyboard project on `main` does not use
# this script. MODE=debug|release (default release).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-release}"
APP_NAME="SkyBook"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VERSION_FILE="$ROOT_DIR/VERSION"
DEFAULT_VERSION="0.2.0-skybook.1"

if [[ -f "$VERSION_FILE" ]]; then
  APP_VERSION="$(head -n 1 "$VERSION_FILE" | tr -d '[:space:]')"
  [[ -z "$APP_VERSION" ]] && APP_VERSION="$DEFAULT_VERSION"
else
  APP_VERSION="$DEFAULT_VERSION"
fi

# CFBundleVersion must rise with every release (Sparkle compares it); the
# semantic version pressed together gives 0.2.1 -> 201, 0.10.0 -> 1000.
APP_BUILD="$(printf '%s' "$APP_VERSION" | awk -F'[.]' '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }')"
[[ -z "$APP_BUILD" || "$APP_BUILD" == "0" ]] && APP_BUILD=1

cd "$ROOT_DIR"
swift build -c "$MODE"
BIN_PATH="$(swift build -c "$MODE" --show-bin-path)/$APP_NAME"
[[ -x "$BIN_PATH" ]] || { echo "binary not found: $BIN_PATH" >&2; exit 1; }

# Sign before the binary enters the bundle: codesign refuses to sign a
# bare binary whose parent directory is a bundle with unsealed root
# contents, and the resource bundles must live at the bundle root for
# Bundle.module to find them (see below).
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN_PATH" 2>/dev/null || true
codesign --force --sign - "$BIN_PATH"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

# ---- Frameworks and package resource bundles from the SPM build ----
# Sparkle ships as a prebuilt binary framework; without it the binary cannot
# even load (dyld: Library not loaded). The bundle files are the SPM resource
# packages (Highlightr, Prettier, KeyboardShortcuts). The generated
# Bundle.module accessor of a `swift build` executable looks for them at
# <app>.app/<name>.bundle (Bundle.main.bundleURL) and then at the build
# machine's .build path - NOT at Contents/Resources (v0.2.0 shipped them in
# Resources, so every machine without this repo's .build crashed the first
# time Highlightr initialised: resource_bundle_accessor.swift:12). They go to
# the app root.
BUILD_DIR="$(swift build -c "$MODE" --show-bin-path)"
mkdir -p "$CONTENTS_DIR/Frameworks"
for fw in "$BUILD_DIR"/*.framework(N); do
  [[ -e "$fw" ]] || continue
  cp -R "$fw" "$CONTENTS_DIR/Frameworks/"
done
for b in "$BUILD_DIR"/*.bundle(N); do
  [[ -e "$b" ]] || continue
  cp -R "$b" "$APP_DIR/$(basename "$b")"
done

# ---- Resources the code reads from Bundle.main ----
cp -R "$ROOT_DIR/Resources/DownView.bundle" "$RESOURCES_DIR/DownView.bundle"
mkdir -p "$RESOURCES_DIR/Fonts"
for ttf in "$ROOT_DIR"/Resources/Fonts/*.ttf(N); do
  cp "$ttf" "$RESOURCES_DIR/Fonts/"
done
# The app icon is MiaoYan's own app.icns; Markdown.icns is the
# document-type icon, so a .md file shows its own glyph in Finder instead of
# the blank-page default.
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/$APP_NAME.icns"
cp "$ROOT_DIR/Resources/Markdown.icns" "$RESOURCES_DIR/Markdown.icns"
# The Open Source Licenses window loads this from the bundle.
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$RESOURCES_DIR/THIRD-PARTY-NOTICES.md"

# Localization: every lproj keeps its strings tables (Main.strings included
# so the programmatic menu can localize its titles). InfoPlist.strings is
# dropped: upstream it overrides CFBundleDisplayName back to 妙言, which the
# SkyBook brand must not inherit.
for lproj in "$ROOT_DIR"/Resources/Localization/*.lproj(N); do
  [[ -e "$lproj" ]] || continue
  cp -R "$lproj" "$RESOURCES_DIR/$(basename "$lproj")"
  rm -f "$RESOURCES_DIR/$(basename "$lproj")/InfoPlist.strings"
done

# First-run guide notes are copied from this folder on first launch.
[[ -d "$ROOT_DIR/Resources/Initial" ]] && cp -R "$ROOT_DIR/Resources/Initial" "$RESOURCES_DIR/Initial"

# Asset catalog flatten: NSImage(named:) resolves loose files in Resources;
# the compiled catalog is unavailable without Xcode's actool. Dark SVG
# variants keep their names and are picked up as normal images.
for set in "$ROOT_DIR"/Resources/Images.xcassets/*.imageset(N); do
  [[ -d "$set" ]] || continue
  for f in "$set"/*.png(N) "$set"/*.svg(N) "$set"/*.pdf(N); do
    [[ -e "$f" ]] || continue
    cp "$f" "$RESOURCES_DIR/$(basename "$f")"
  done
done

# ---- Info.plist ----
cat > "$CONTENTS_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIdentifier</key><string>local.skybook</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIconFile</key><string>$APP_NAME.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLName</key><string>local.skybook</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>skybook</string>
        <string>miaoyan</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
      </array>
      <key>CFBundleTypeIconFile</key><string>Markdown.icns</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>mdown</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Plain Text</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>CFBundleTypeIconFile</key><string>Markdown.icns</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>txt</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
plutil -lint "$CONTENTS_DIR/Info.plist" > /dev/null

# The bundle accessor looks only at the app root and the build machine's
# .build path; a bundle left out of the root ships a launch crasher. Fail the
# package instead. Guarded on Highlightr so a build without SPM bundles (never
# seen) still packages.
if [[ -d "$BUILD_DIR/Highlightr_Highlightr.bundle" && ! -d "$APP_DIR/Highlightr_Highlightr.bundle" ]]; then
  echo "error: resource bundles missing from the app root" >&2
  exit 1
fi

# The bundle is intentionally left unsealed: sealing it before the root
# bundles exist is impossible (codesign rejects unsealed root contents), and
# sealing it before they are copied leaves a broken seal, which Gatekeeper
# reports as a damaged app - worse than an unsigned one. An unsealed bundle
# with an ad-hoc-signed arm64 binary opens exactly like v0.2.0 did:
# right-click -> Open.
touch "$APP_DIR"
echo "$APP_DIR"
