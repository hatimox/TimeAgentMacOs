#!/usr/bin/env bash
# Build TimeAgent into a universal (arm64 + x86_64) .app bundle and a .dmg.
#
# Usage: scripts/package.sh [version]
#   version defaults to the value of $VERSION or "0.0.0".
#
# Output (under ./dist):
#   TimeAgent.app   — the double-clickable bundle
#   TimeAgent.dmg   — disk image wrapping the .app for distribution
#
# The build is ad-hoc signed (codesign -s -). It runs, but is NOT notarized, so
# first launch needs right-click → Open (or `xattr -dr com.apple.quarantine`).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="TimeAgent"
EXECUTABLE="TimeAgentMac"          # SPM product name
BUNDLE_ID="net.omnevo.timeagent"
VERSION="${1:-${VERSION:-0.0.0}}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Packaging $APP_NAME $VERSION"
rm -rf "$DIST"
mkdir -p "$DIST"

# --- build a universal binary -------------------------------------------------
echo "==> Building release (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

# --- assemble the .app bundle -------------------------------------------------
echo "==> Assembling bundle"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RES"

cp "$BIN_PATH/$EXECUTABLE" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>TimeAgent detects active meetings by checking whether the microphone is in use.</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

# --- ad-hoc sign --------------------------------------------------------------
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" || true

# --- build the .dmg -----------------------------------------------------------
echo "==> Creating DMG"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "==> Done:"
echo "    $APP"
echo "    $DMG"
