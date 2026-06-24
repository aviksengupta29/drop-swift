#!/bin/bash
#
# DropSwift — install auto-start.
#
# Double-click this file (or run it in Terminal) ONCE. After that, the
# DropSwift server starts automatically every time you log in to your Mac,
# runs invisibly in the background, and restarts itself if it ever stops.
# You'll never need to run the python script by hand again.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="$SCRIPT_DIR/server.py"
SHARE_DIR="$HOME/Desktop/DropSwift"     # phone files land here — easy to find
PORT=8080
PYTHON="$(command -v python3 || echo /usr/bin/python3)"
LABEL="com.avik.dropswift"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$SHARE_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SERVER_PY</string>
        <string>--dir</string>
        <string>$SHARE_DIR</string>
        <string>--port</string>
        <string>$PORT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/dropswift.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/dropswift.err.log</string>
</dict>
</plist>
EOF

# (Re)load the agent so it starts now and at every login.
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo ""
echo "============================================================"
echo " DropSwift auto-start is installed and running."
echo "   Python      : $PYTHON"
echo "   Shared folder: $SHARE_DIR"
echo "   Port         : $PORT"
echo ""
echo " Your phone's files will appear in:  $SHARE_DIR"
echo " The DropSwift app should now find this Mac automatically."
echo ""
echo " To stop it permanently, run: ./uninstall-autostart.command"
echo "============================================================"
echo ""
echo "If the app can't connect, allow incoming connections for"
echo "python in: System Settings -> Network -> Firewall."
