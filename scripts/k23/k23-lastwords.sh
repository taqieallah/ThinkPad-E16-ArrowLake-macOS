#!/bin/bash
# On the laptop, after boots that froze (boot "MeowXE3: start once without driver" first):
#   sudo bash /Volumes/1401/xegfx-e16/MeowARL/k23-lastwords.sh
# Saves the whole system log of the last 3 hours (no filter, compressed), so the last messages of each frozen boot -
# from every process, not only the driver - can be read. Plus the hang/spin/crash reports macOS wrote. Reads only.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Volumes/1401/xegfx-e16/logs; mkdir -p "$B" 2>/dev/null || B=/Users/Shared
D=$B/lastwords-$(date +%m%d-%H%M%S); mkdir -p "$D"
echo "1/2 system log, last 3 hours (1-3 minutes) ..."
log show --last 3h --info --style compact 2>/dev/null | gzip -6 > "$D/syslog-3h.txt.gz"
echo "2/2 hang / crash reports"
mkdir -p "$D/reports"
find /Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports/Retired -maxdepth 1 -type f -mmin -240 \
  \( -name '*.hang' -o -name '*.spin' -o -name '*.ips' -o -name '*.diag' -o -name '*panic*' \) -exec cp {} "$D/reports/" \; 2>/dev/null
ls -la "$D" "$D/reports" | tail -20
echo "saved in $D"
