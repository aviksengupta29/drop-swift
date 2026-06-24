#!/bin/bash
#
# Builds "DropSwift Server.app" — a native SwiftUI app with a Liquid-Glass UI
# (logo, IP/port, folder picker) — and packages it into DropSwift-Server.dmg.
# The app runs the bundled Python server.py underneath.
#
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="DropSwift Server"
BUILD="./build"
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/DropSwift-Server.dmg"

echo "Cleaning previous build..."
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- bundle the server code + assets --------------------------------------
cp server.py "$APP/Contents/Resources/server.py"

ICON_SRC="../assets/AppIcon.icns"
[ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

LOGO_SRC="../DropSwift/DropSwift/Assets.xcassets/AppLogo.imageset/AppLogo.png"
[ -f "$LOGO_SRC" ] && cp "$LOGO_SRC" "$APP/Contents/Resources/AppLogo.png"

# --- Info.plist ------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>DropSwift Server</string>
    <key>CFBundleDisplayName</key>         <string>DropSwift Server</string>
    <key>CFBundleIdentifier</key>          <string>com.avik.dropswift.server</string>
    <key>CFBundleExecutable</key>          <string>DropSwiftServer</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

# --- compile the native SwiftUI app ---------------------------------------
echo "Compiling native macOS app..."
xcrun swiftc -parse-as-library -O \
    -o "$APP/Contents/MacOS/DropSwiftServer" \
    macapp/DropSwiftServerApp.swift
chmod +x "$APP/Contents/MacOS/DropSwiftServer"

# Ad-hoc sign so it launches cleanly on Apple Silicon.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# --- package into a .dmg ---------------------------------------------------
echo "Creating disk image..."
STAGE="$BUILD/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install convenience

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -quiet -format UDZO "$DMG"
rm -rf "$STAGE"

echo ""
echo "============================================================"
echo " Built: $(cd "$BUILD" && pwd)/DropSwift-Server.dmg"
echo " Open the .dmg, drag 'DropSwift Server' to Applications,"
echo " then open it (right-click -> Open the first time)."
echo "============================================================"
