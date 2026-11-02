#!/bin/bash
# On the laptop: XeGfx core (built from source, GGTT flip slots) + XeGfxAccel (zero-copy flip) + NVMTLDriver.
#   sudo bash /Volumes/1401/xegfx-e16/full-install.sh          undo: sudo bash /Volumes/1401/xegfx-e16/full-install.sh --undo
# After xe-up the flip is OFF; turn it on live:  sudo sysctl debug.nvaccel_xe_flip=1     (=0 goes back to copying)
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
T=$(find /Library/GPUBundles -path '*NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver' -type f | head -1)
KEXTS="XeGfx XeGfxAccel"
if [ "${1:-}" = --undo ]; then
  B=$(ls -d /Library/XeGfx-E16/full-backup-* 2>/dev/null | tail -1); [ -n "$B" ] || { echo "no backup"; exit 1; }
  cp -p "$B/AuxiliaryKernelExtensions.kc" "$KC"; for k in $KEXTS; do rm -rf "$EXT/$k.kext"; ditto "$B/$k.kext" "$EXT/$k.kext"; done
  cp -p "$B/NVMTLDriver" "$T"; codesign -f -s - "$T"; echo "restored from $B - restart"; exit 0; fi
for f in kexts/XeGfx.kext kexts/XeGfxAccel.kext NVMTLDriver; do [ -e "$HERE/$f" ] || { echo "STOP: $f missing"; exit 1; }; done
grep -aq xgFlipInit "$HERE/kexts/XeGfx.kext/Contents/MacOS/XeGfx" || { echo "STOP: kexts/XeGfx.kext is not the source build with flip slots"; exit 1; }
grep -aq "E16 zero-copy flip" "$HERE/kexts/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel" || { echo "STOP: kexts/XeGfxAccel.kext has no zero-copy flip"; exit 1; }
B=/Library/XeGfx-E16/full-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$B"
cp -p "$KC" "$B/"; for k in $KEXTS; do ditto "$EXT/$k.kext" "$B/$k.kext"; done; cp -p "$T" "$B/NVMTLDriver"
IDS=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk '{print $1}' | grep -E '^[a-z]+\.[A-Za-z0-9.-]+$' | grep -v '^com\.apple\.')
for k in $KEXTS; do
  rm -rf "$EXT/$k.kext"; ditto --norsrc --noextattr "$HERE/kexts/$k.kext" "$EXT/$k.kext"
  find "$EXT/$k.kext" -name '._*' -delete; chown -R root:wheel "$EXT/$k.kext"; chmod -R 755 "$EXT/$k.kext"
  codesign -f -s - "$EXT/$k.kext" && codesign -v "$EXT/$k.kext" || { echo "STOP: signing $k failed"; exit 1; }
done
NEW=$KC.e16-new; rm -f "$NEW"
restore() { for k in $KEXTS; do rm -rf "$EXT/$k.kext"; ditto "$B/$k.kext" "$EXT/$k.kext"; done; rm -f "$NEW"; }
if ! kmutil create -n aux --volume-root / --allow-missing-kdk -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z -v > "$B/kmutil.log" 2>&1; then
  tail -25 "$B/kmutil.log"; restore; echo "FAILED: kmutil (nothing changed; log $B/kmutil.log)"; exit 1; fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null)
for id in $IDS; do printf '%s\n' "$INS" | grep -q "^$id[[:space:]]" || { echo "FAILED: $id missing (nothing changed)"; restore; exit 1; }; done
mv -f "$NEW" "$KC"
cp "$HERE/NVMTLDriver" "$T"; chown root:wheel "$T"; chmod 755 "$T"; codesign -f -s - "$T"
sync; echo "OK (backup $B). Restart; allow the kexts in Privacy & Security if asked, restart again, log in, run xe-up.sh."
echo "Then: sudo sysctl debug.nvaccel_xe_flip=1   and watch:  sysctl debug.nvaccel_xe_flips debug.nvaccel_xe_flip_miss debug.nvaccel_xe_flip_fail"
