#!/bin/bash
# On the laptop:   sudo bash /Volumes/1401/xegfx-e16/MeowARL/k23-collect.sh          (this boot)
#                  sudo bash .../k23-collect.sh prev    (after a boot that failed: the last 3 hours, all boots)
# Collects what MeowARL (MeowXE3 on Arrow Lake H) left: NullMoth's flight log, the driver's kernel messages, the GPU as
# macOS sees it. Into xegfx-e16/logs/meowarl-<time>/ on the stick (or /Users/Shared). Reads only.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Volumes/1401/xegfx-e16/logs; mkdir -p "$B" 2>/dev/null || B=/Users/Shared
D=$B/meowarl-$(date +%m%d-%H%M%S); mkdir -p "$D"
for f in /Users/Shared/nmx-flight.log /Users/Shared/nmx-accel.log /Users/Shared/MeowXE3-install.log; do
  [ -f "$f" ] && cp "$f" "$D/"; done
# WindowServer / kernel crash reports of the last day (the first WindowServer crash of a boot is the one that matters)
mkdir -p "$D/crashes"
find /Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports/Retired -maxdepth 1 -type f \
  \( -name 'WindowServer*' -o -name 'Kernel*' -o -name '*panic*' \) -mtime -1 -exec cp {} "$D/crashes/" \; 2>/dev/null
echo "crash reports: $(ls "$D/crashes" | wc -l | tr -d ' ')"
P='sender == "MeowXE3" OR sender == "MeowXE3Accel" OR sender == "MeowXE3AGDC" OR eventMessage CONTAINS[c] "NullMoth" OR eventMessage CONTAINS "NMX" OR eventMessage CONTAINS[c] "xe 0000" OR eventMessage CONTAINS "[drm]" OR eventMessage CONTAINS "GuC" OR eventMessage CONTAINS "DMC"'
if [ "${1:-}" = prev ]; then log show --last 3h --predicate "$P" --style compact > "$D/kernel.txt" 2>&1
else log show --last boot --predicate "$P" --style compact > "$D/kernel.txt" 2>&1; fi
{ sw_vers; uname -a; echo; nvram boot-args 2>/dev/null; nvram nullmoth-fbflags 2>/dev/null; csrutil status; echo
  kmutil showloaded 2>/dev/null | grep -iE "meowxe3|nmx|lilu|whatevergreen|legion|xegfx"
  echo; system_profiler SPDisplaysDataType
  echo; ioreg -lw0 -r -c IOPCIDevice -k vendor-id 2>/dev/null | grep -E '"(IOName|device-id|vendor-id)"|MeowXE3|NMX' | head -40
  echo; ioreg -lw0 2>/dev/null | grep -oE '"(NMX[A-Za-z]*|MeowXE3[A-Za-z]*)"' | sort | uniq -c
  echo; ls -la /Library/NullMoth/firmware/i915 /Library/NullMoth/firmware/xe 2>&1
} > "$D/system.txt" 2>&1
echo "kernel lines: $(wc -l < "$D/kernel.txt")"; grep -iE "probe|force|guc|dmc|firmware|wedged|error|fail" "$D/kernel.txt" | tail -25
echo; echo "saved in $D"
