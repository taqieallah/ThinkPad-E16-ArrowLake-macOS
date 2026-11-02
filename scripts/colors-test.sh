#!/bin/bash
# On the laptop: undo the mip plugin and turn off Intel colour compression (CCS) and fast clears for the Metal plugin.
#   sudo bash /Volumes/1401/xegfx-e16/colors-test.sh        (undo:  sudo bash .../colors-test.sh --undo)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
C=/Library/GPUBundles/nvmtl/nvrm610.conf
T=$(find /Library/GPUBundles -path '*NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver' -type f | head -1)
if [ "${1:-}" = --undo ]; then
  [ -f "$C.before-colors" ] && mv "$C.before-colors" "$C" || sed -i '' '/^INTEL_DEBUG=/d' "$C" 2>/dev/null
  echo "conf restored:"; cat "$C" 2>/dev/null; exit 0; fi
# 1) the plugin from before the mip change
if [ -n "$T" ] && [ -f "$T.before-mip" ]; then cp "$T.before-mip" "$T"; codesign -f -s - "$T" 2>/dev/null; echo "plugin: old version back (mip patch $(grep -ac 'E16 mip path' "$T"))"; fi
# 2) INTEL_DEBUG=noccs,nofc in the plugin's conf
mkdir -p "$(dirname "$C")"; [ -f "$C" ] && [ ! -f "$C.before-colors" ] && cp "$C" "$C.before-colors"
touch "$C"; sed -i '' '/^INTEL_DEBUG=/d' "$C"; echo "INTEL_DEBUG=noccs,nofc" >> "$C"; chmod 644 "$C"
echo "conf now:"; cat "$C"; echo "now restart, log in, run xe-up.sh"
