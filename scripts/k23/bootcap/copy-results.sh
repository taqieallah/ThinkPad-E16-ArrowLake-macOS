#!/bin/bash
# sudo bash copy-results.sh : copies /Users/Shared/meowarl-boot and the WindowServer crash reports to the stick
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
T=/Volumes/1401/xegfx-e16/logs/bootcap-$(date +%m%d-%H%M%S); mkdir -p "$T"
cp -R /Users/Shared/meowarl-boot "$T/" 2>/dev/null; mkdir -p "$T/crashes"
find /Library/Logs/DiagnosticReports -maxdepth 1 -name 'WindowServer*' -mtime -1 -exec cp {} "$T/crashes/" \;
ls -R "$T" | head -40; echo "copied to $T"
