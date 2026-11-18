#!/bin/bash
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
launchctl bootout system/com.e16.meowarl.bootcap 2>/dev/null
rm -f /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist; rm -rf "/Library/Application Support/MeowARL"; echo "removed"
