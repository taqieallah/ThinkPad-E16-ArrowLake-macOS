#!/bin/bash
# On the laptop:   sudo bash /Volumes/1401/xegfx-e16/k13/k13-install.sh       undo: ... k13-install.sh --undo
# Installs XeGfxIntelFB 0.9.5 (hardware cursor on the E16) and rebuilds the auxiliary kernel collection.
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
B=/Library/XeGfx-E16/k13-backup
if [ "${1:-}" = --undo ]; then
  [ -d "$B/XeGfxIntelFB.kext" ] && [ -f "$B/AuxiliaryKernelExtensions.kc" ] || { echo "no backup in $B"; exit 1; }
  rm -rf "$EXT/XeGfxIntelFB.kext"; ditto "$B/XeGfxIntelFB.kext" "$EXT/XeGfxIntelFB.kext"; cp -p "$B/AuxiliaryKernelExtensions.kc" "$KC"
  nvram xeintelfb-starts=%00; echo "0.9.4 back - restart"; exit 0; fi
[ -d "$HERE/XeGfxIntelFB.kext" ] || { echo "STOP: $HERE/XeGfxIntelFB.kext missing"; exit 1; }
[ -d "$EXT/XeGfxIntelFB.kext" ] || { echo "STOP: no installed XeGfxIntelFB to replace"; exit 1; }
if [ ! -d "$B/XeGfxIntelFB.kext" ]; then mkdir -p "$B"; ditto "$EXT/XeGfxIntelFB.kext" "$B/XeGfxIntelFB.kext"; cp -p "$KC" "$B/"; fi
rm -rf "$EXT/XeGfxIntelFB.kext"; ditto --norsrc --noextattr "$HERE/XeGfxIntelFB.kext" "$EXT/XeGfxIntelFB.kext"
find "$EXT/XeGfxIntelFB.kext" -name '._*' -delete; chown -R root:wheel "$EXT/XeGfxIntelFB.kext"; chmod -R 755 "$EXT/XeGfxIntelFB.kext"
codesign -f -s - "$EXT/XeGfxIntelFB.kext" >/dev/null 2>&1
IDS=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 !~ /^com\.apple\./ {print $1}')
NEW=$KC.k13-new; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / --allow-missing-kdk -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > /tmp/k13-kmutil.log 2>&1; then
  tail -20 /tmp/k13-kmutil.log; echo "FAILED: kmutil - putting 0.9.4 back"
  rm -rf "$EXT/XeGfxIntelFB.kext"; ditto "$B/XeGfxIntelFB.kext" "$EXT/XeGfxIntelFB.kext"; exit 1; fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null)
for id in $IDS org.watchthelight.XeGfxIntelFB; do printf '%s\n' "$INS" | grep -q "^$id[[:space:]]" || { echo "FAILED: $id missing from the new collection - nothing changed"; rm -f "$NEW"
  rm -rf "$EXT/XeGfxIntelFB.kext"; ditto "$B/XeGfxIntelFB.kext" "$EXT/XeGfxIntelFB.kext"; exit 1; }; done
mv -f "$NEW" "$KC"; nvram xeintelfb-starts=%00
echo "XeGfxIntelFB 0.9.5 installed. Restart, wait 2 minutes on the desktop, run xe-up-k12.sh, then:"
echo "  log show --last boot --style compact | grep -i 'hw cursor' | tail -3"
