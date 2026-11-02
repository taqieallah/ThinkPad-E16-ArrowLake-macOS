#!/bin/bash
# On the laptop: install XeGfxAccel (completion marks) + NVMTLDriver (sends them). WindowServer then stops waiting for
# every composite itself; the panel copy waits for it in the kernel instead.
#   sudo bash /Volumes/1401/xegfx-e16/k9-install.sh            undo: sudo bash /Volumes/1401/xegfx-e16/k9-install.sh --undo
#   live A/B without reinstalling: sudo sysctl debug.nvaccel_surface_gpu_on=0 (old way) / =1 (new), WindowServer follows within 1 s
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
T=$(find /Library/GPUBundles -path '*NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver' -type f | head -1)
if [ "${1:-}" = --undo ]; then
  B=$(ls -d /Library/XeGfx-E16/k9-backup-* 2>/dev/null | tail -1); [ -n "$B" ] || { echo "no backup"; exit 1; }
  cp -p "$B/AuxiliaryKernelExtensions.kc" "$KC"; rm -rf "$EXT/XeGfxAccel.kext"; ditto "$B/XeGfxAccel.kext" "$EXT/XeGfxAccel.kext"
  cp -p "$B/NVMTLDriver" "$T"; codesign -f -s - "$T"; echo "restored from $B - restart"; exit 0; fi
for f in kexts/XeGfxAccel.kext NVMTLDriver; do [ -e "$HERE/$f" ] || { echo "STOP: $f missing"; exit 1; }; done
grep -aq 'XGDR selector 1' "$HERE/NVMTLDriver" || { echo "STOP: NVMTLDriver on the stick is not the K9 build"; exit 1; }
B=/Library/XeGfx-E16/k9-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$B"
cp -p "$KC" "$B/"; ditto "$EXT/XeGfxAccel.kext" "$B/XeGfxAccel.kext"; cp -p "$T" "$B/NVMTLDriver"
IDS=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk '{print $1}' | grep -E '^[a-z]+\.[A-Za-z0-9.-]+$' | grep -v '^com\.apple\.')
rm -rf "$EXT/XeGfxAccel.kext"; ditto --norsrc --noextattr "$HERE/kexts/XeGfxAccel.kext" "$EXT/XeGfxAccel.kext"
find "$EXT/XeGfxAccel.kext" -name '._*' -delete; chown -R root:wheel "$EXT/XeGfxAccel.kext"; chmod -R 755 "$EXT/XeGfxAccel.kext"
codesign -f -s - "$EXT/XeGfxAccel.kext" && codesign -v "$EXT/XeGfxAccel.kext" || { echo "STOP: signing failed"; exit 1; }
NEW=$KC.e16-new; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / --allow-missing-kdk -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z -v > "$B/kmutil.log" 2>&1; then
  tail -20 "$B/kmutil.log"; rm -rf "$EXT/XeGfxAccel.kext"; ditto "$B/XeGfxAccel.kext" "$EXT/XeGfxAccel.kext"; echo "FAILED: kmutil (nothing changed)"; exit 1; fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null)
for id in $IDS; do printf '%s\n' "$INS" | grep -q "^$id[[:space:]]" || { echo "FAILED: $id missing (nothing changed)"; rm -f "$NEW"; exit 1; }; done
mv -f "$NEW" "$KC"
cp "$HERE/NVMTLDriver" "$T"; chown root:wheel "$T"; chmod 755 "$T"; codesign -f -s - "$T"
sync; echo "OK (backup $B). Restart; macOS may ask to allow the kext again in Privacy & Security, then restart once more."
echo "After xe-up: sysctl debug.nvaccel_surface_gpu_marks debug.nvaccel_surface_gpu_waits  (both should grow)"
