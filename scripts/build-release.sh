#!/bin/bash
set -e

# Configuration
APP_NAME="Typester"
BUNDLE_ID="com.typester.app"
TEAM_ID="R892A93W42"
VERSION="1.7.0"

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release-packaging"
DMG_STAGING="$PROJECT_DIR/dist/dmg-staging"
APP_BUNDLE="$DMG_STAGING/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/dist/$APP_NAME-$VERSION.dmg"
ARM64_BIN="$BUILD_DIR/typester-arm64"
X86_BIN="$BUILD_DIR/typester-x86_64"
UNIVERSAL_BIN="$BUILD_DIR/typester"

cd "$PROJECT_DIR"
mkdir -p "$BUILD_DIR"

# Newer SwiftPM/Xcode write a single .build/release/typester and overwrite it per
# --arch build, so copy each arch aside before the next build.

echo "==> Building release binary for arm64..."
swift build -c release --arch arm64 --product typester
cp -f "$PROJECT_DIR/.build/release/typester" "$ARM64_BIN"

echo "==> Building release binary for x86_64..."
if swift build -c release --arch x86_64 --product typester; then
    cp -f "$PROJECT_DIR/.build/release/typester" "$X86_BIN"
    echo "==> Creating universal binary..."
    lipo -create "$ARM64_BIN" "$X86_BIN" -output "$UNIVERSAL_BIN"
else
    echo "==> x86_64 build failed or unavailable; packaging arm64-only binary..."
    cp -f "$ARM64_BIN" "$UNIVERSAL_BIN"
fi

file "$UNIVERSAL_BIN"
lipo -info "$UNIVERSAL_BIN" || true

echo "==> Creating app bundle..."
rm -rf dist
mkdir -p "$DMG_STAGING"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Create Applications symlink for drag-and-drop install
ln -s /Applications "$DMG_STAGING/Applications"

# Copy binary
cp "$UNIVERSAL_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy icons
cp "Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp "Assets/MenuBarIcon.png" "$APP_BUNDLE/Contents/Resources/"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Typester needs microphone access to transcribe your speech to text.</string>
</dict>
</plist>
EOF

# Always codesign the bundle so Info.plist is bound and the identifier matches
# CFBundleIdentifier. Without this, TCC Accessibility grants often attach to a
# stale/adhoc linker identity and AXIsProcessTrusted() stays false after rebuilds.
ENTITLEMENTS="$PROJECT_DIR/Sources/typester.entitlements"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')"

    echo "==> Signing app with: $SIGNING_IDENTITY"
    codesign --force --deep --options runtime \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE"

    echo "==> Creating DMG..."
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

    echo "==> Signing DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"

    echo ""
    echo "==> Build complete!"
    echo "    App: $APP_BUNDLE"
    echo "    DMG: $DMG_PATH"
    echo ""
    echo "To notarize, run:"
    echo "    xcrun notarytool submit \"$DMG_PATH\" --apple-id YOUR_APPLE_ID --team-id $TEAM_ID --password APP_SPECIFIC_PASSWORD --wait"
    echo "    xcrun stapler staple \"$DMG_PATH\""
else
    echo "==> No Developer ID certificate; ad-hoc signing with identifier $BUNDLE_ID..."
    codesign --force --deep \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        --sign - \
        "$APP_BUNDLE"

    echo "==> Creating DMG..."
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

    echo ""
    echo "==> Build complete (ad-hoc signed)!"
    echo "    App: $APP_BUNDLE"
    echo "    DMG: $DMG_PATH"
    echo ""
    echo "NOTE: Ad-hoc builds get a new code identity each rebuild. After installing,"
    echo "remove Typester from System Settings → Privacy → Accessibility, re-add"
    echo "/Applications/Typester.app, enable it, then quit and reopen Typester."
    echo "For distribution, use a Developer ID certificate from developer.apple.com."
fi
