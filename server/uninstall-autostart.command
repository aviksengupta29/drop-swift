#!/bin/bash
#
# DropSwift — remove auto-start.
#
# Double-click to stop the DropSwift server from running automatically.
# (Your shared folder and files are left untouched.)
#
LABEL="com.avik.dropswift"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "DropSwift auto-start removed. The background server is stopped."
