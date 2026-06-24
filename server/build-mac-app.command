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
# DropSwift Server launcher: pick a save folder, start the server, then show a
# status window with the IP + port. Uses only built-in macOS dialogs.

HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../Resources"
OSA="/usr/bin/osascript"
PORT=8080

# Find a usable python3 (Finder gives apps a minimal PATH).
PY=""
for c in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         "$HOME/anaconda3/bin/python3" /opt/anaconda3/bin/python3; do
    if [ -x "$c" ]; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    "$OSA" -e 'display dialog "Python 3 was not found on this Mac. Install it from python.org, then try again." with title "DropSwift Server" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

# Remember the last chosen folder between launches.
CONF="$HOME/Library/Application Support/DropSwift"
mkdir -p "$CONF"
FOLDER_FILE="$CONF/folder.txt"
if [ -f "$FOLDER_FILE" ]; then LAST="$(cat "$FOLDER_FILE")"; else LAST="$HOME/Desktop/DropSwift"; fi
[ -d "$LAST" ] || LAST="$HOME/Desktop/DropSwift"
mkdir -p "$LAST"

lan_ip() {
    "$PY" -c "import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try:
    s.connect(('8.8.8.8',80)); print(s.getsockname()[0])
except Exception:
    print('127.0.0.1')
finally:
    s.close()" 2>/dev/null
}

choose_folder() {
"$OSA" <<ASCRIPT 2>/dev/null
try
    set d to (POSIX file "$LAST") as alias
on error
    set d to (path to desktop)
end try
set f to choose folder with prompt "Choose the folder where files from your phone will be saved:" default location d
POSIX path of f
ASCRIPT
}

start_server() {
    pkill -f "server.py --dir" 2>/dev/null
    pkill -f "dns-sd -R" 2>/dev/null
    sleep 0.4
    nohup "$PY" "$RES/server.py" --dir "$1" --port "$PORT" > /tmp/dropswift_server.log 2>&1 &
    disown 2>/dev/null || true
    sleep 1
}

# 1) Ask where to save incoming files (pre-filled with the last choice).
SEL="$(choose_folder)"
if [ -n "$SEL" ]; then FOLDER="${SEL%/}"; else FOLDER="$LAST"; fi
printf '%s' "$FOLDER" > "$FOLDER_FILE"
mkdir -p "$FOLDER"

# 2) Start the server and show the status window.
start_server "$FOLDER"
IP="$(lan_ip)"

while true; do
    BTN="$("$OSA" <<ASCRIPT 2>/dev/null
set msg to "DropSwift Server is running.

IP address:   $IP
Port:           $PORT
Saving to:    $FOLDER

On your phone, open DropSwift — it finds this Mac automatically. To enter it by hand, use the IP and port above."
set r to display dialog msg with title "DropSwift Server" buttons {"Stop Server", "Change Folder…", "Keep Running"} default button "Keep Running"
button returned of r
ASCRIPT
)"
    case "$BTN" in
        "Stop Server")
            pkill -f "server.py --dir" 2>/dev/null
            pkill -f "dns-sd -R" 2>/dev/null
            "$OSA" -e 'display notification "DropSwift Server stopped." with title "DropSwift Server"' 2>/dev/null
            break ;;
        "Change Folder…")
            SEL="$(choose_folder)"
            if [ -n "$SEL" ]; then
                FOLDER="${SEL%/}"
                printf '%s' "$FOLDER" > "$FOLDER_FILE"
                mkdir -p "$FOLDER"
                start_server "$FOLDER"
            fi ;;
        *)
            # Keep Running (or dismissed): leave the server running, exit.
            break ;;
    esac
done
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
