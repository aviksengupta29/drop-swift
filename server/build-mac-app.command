#!/bin/bash
#
# Builds "DropSwift Server.app" and packages it into DropSwift-Server.dmg.
# Double-click the app -> it starts the server and shows its IP + port.
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

# --- bundle the server code ------------------------------------------------
cp server.py "$APP/Contents/Resources/server.py"

# --- app icon (if present) -------------------------------------------------
ICON_SRC="../assets/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi

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
    <key>LSMinimumSystemVersion</key>      <string>11.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

# --- the launcher executable ----------------------------------------------
cat > "$APP/Contents/MacOS/DropSwiftServer" <<'LAUNCH'
#!/bin/bash
# DropSwift Server launcher: starts the server, shows IP + port, keeps running.

HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../Resources"

# Find a usable python3 (Finder gives apps a minimal PATH).
PY=""
for c in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         "$HOME/anaconda3/bin/python3" /opt/anaconda3/bin/python3; do
    if [ -x "$c" ]; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    osascript -e 'display dialog "Python 3 was not found on this Mac. Install it from python.org, then try again." with title "DropSwift Server" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

SHARE="$HOME/Desktop/DropSwift"
PORT=8080
mkdir -p "$SHARE"

# If a server is already on the port, just report it instead of starting another.
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    ALREADY=1
else
    ALREADY=0
    nohup "$PY" "$RES/server.py" --dir "$SHARE" --port "$PORT" \
        > /tmp/dropswift_server.log 2>&1 &
    SRV=$!
    disown "$SRV" 2>/dev/null || true
    sleep 1
fi

# Work out this Mac's LAN IP.
IP="$("$PY" -c "import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try:
    s.connect(('8.8.8.8',80)); print(s.getsockname()[0])
except Exception:
    print('127.0.0.1')
finally:
    s.close()" 2>/dev/null)

MSG="DropSwift Server is running.

IP address : $IP
Port       : $PORT
Sharing    : $SHARE

Open the DropSwift app on your phone — it should find this Mac automatically. If you ever enter it by hand, use the IP and port above.

Keep this running in the background, or click Stop Server."

BTN="$(osascript -e "display dialog \"$MSG\" with title \"DropSwift Server\" buttons {\"Stop Server\", \"Keep Running\"} default button \"Keep Running\"" 2>/dev/null)"

if echo "$BTN" | grep -q "Stop Server"; then
    pkill -f "Resources/server.py" 2>/dev/null
    pkill -f "dns-sd -R" 2>/dev/null
    osascript -e 'display notification "DropSwift Server stopped." with title "DropSwift Server"' 2>/dev/null
fi
# On "Keep Running" we simply exit; the disowned server keeps serving.
LAUNCH
chmod +x "$APP/Contents/MacOS/DropSwiftServer"

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
echo " then double-click it to start the server."
echo "============================================================"
