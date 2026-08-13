#!/bin/bash
# Builds Umbra.app. Pass --install to also place it in /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Umbra"
BUNDLE_ID="io.github.frapsd.Umbra"
VERSION="1.0.0"

BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# main.swift must come last: swiftc allows top-level code only in a file with
# that name, and treats it as the entry point.
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Carbon \
  -framework IOKit \
  -framework ServiceManagement \
  Sources/GammaBlanker.swift \
  Sources/DDCService.swift \
  Sources/HotKey.swift \
  Sources/BlackoutController.swift \
  Sources/MenuBarApp.swift \
  Sources/SelfTest.swift \
  Sources/main.swift \
  -o "$MACOS_DIR/$APP_NAME"

if [ -f "Resources/$APP_NAME.icns" ]; then
  cp "Resources/$APP_NAME.icns" "$RESOURCES_DIR/"
else
  echo "warning: Resources/$APP_NAME.icns missing — run 'xcrun swift Tools/make-icon.swift Resources'" >&2
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for local use and for SMAppService; see the README on
# what users downloading a build need to do about Gatekeeper.
codesign --force --sign - "$APP_DIR"

echo
echo "Built: $APP_DIR"

if [ "${1:-}" = "--install" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_DIR" /Applications/
  echo "Installed: /Applications/$APP_NAME.app"
  echo "Launch it, then enable 'Launch at Login' from the menu."
else
  echo
  echo "  Verify:  $MACOS_DIR/$APP_NAME --selftest"
  echo "  Run:     open '$APP_DIR'"
  echo "  Install: ./build.sh --install"
fi
