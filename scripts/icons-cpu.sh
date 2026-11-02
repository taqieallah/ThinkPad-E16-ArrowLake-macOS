#!/bin/bash
# On the laptop: draw app icons on the CPU (iconservicesagent off the GPU), as zep245/IrisXe does on Tahoe, and clear
# the icon cache so the icons already drawn wrong are drawn again.   sudo bash /Volumes/1401/xegfx-e16/icons-cpu.sh
#   back to the GPU: sudo bash /Volumes/1401/xegfx-e16/icons-cpu.sh --undo
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
A=/Library/GPUBundles/nvmtl-allow.txt
if [ "${1:-}" = --undo ]; then
  grep -v '^ *- *iconservicesagent *$' "$A" > "$A.tmp" && cat "$A.tmp" > "$A"; rm -f "$A.tmp"
else
  grep -q '^ *- *iconservicesagent *$' "$A" 2>/dev/null || { { echo '- iconservicesagent'; cat "$A" 2>/dev/null; } > "$A.tmp" && cat "$A.tmp" > "$A"; rm -f "$A.tmp"; }
fi
echo "nvmtl-allow.txt:"; cat "$A"
rm -rf /Library/Caches/com.apple.iconservices.store
find /private/var/folders -maxdepth 4 -name 'com.apple.iconservices*' -exec rm -rf {} + 2>/dev/null
find /private/var/folders -maxdepth 4 -name 'com.apple.dock.iconcache' -exec rm -rf {} + 2>/dev/null
killall iconservicesagent iconservicesd 2>/dev/null; killall Dock 2>/dev/null
echo "icon cache cleared; icons will be redrawn (give it a minute). A restart + xe-up makes it certain."
