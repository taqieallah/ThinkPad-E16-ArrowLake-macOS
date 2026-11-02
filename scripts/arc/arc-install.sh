#!/bin/bash
# On the laptop: put ArcXe.kext (opt-in, idle unless arcxe=1) into the aux kernel collection next to XeGfx.
#   sudo bash /Volumes/1401/xegfx-e16/arc/arc-install.sh        undo: ... --undo
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
if [ "${1:-}" = --undo ]; then
  B=$(ls -d /Library/XeGfx-E16/arc-backup-* 2>/dev/null | tail -1); [ -n "$B" ] || { echo "no backup"; exit 1; }
  cp -p "$B/AuxiliaryKernelExtensions.kc" "$KC"; rm -rf "$EXT/ArcXe.kext"; echo "restored from $B - restart"; exit 0; fi
[ -f "$HERE/ArcXe.kext/Contents/MacOS/ArcXe" ] || { echo "STOP: ArcXe.kext missing"; exit 1; }
grep -aq arcxe "$HERE/ArcXe.kext/Contents/MacOS/ArcXe" || { echo "STOP: this ArcXe has no arcxe opt-in guard - not installing"; exit 1; }
B=/Library/XeGfx-E16/arc-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$B"; cp -p "$KC" "$B/"
IDS=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk '{print $1}' | grep -E '^[a-z]+\.[A-Za-z0-9.-]+$' | grep -v '^com\.apple\.')
rm -rf "$EXT/ArcXe.kext"; ditto --norsrc --noextattr "$HERE/ArcXe.kext" "$EXT/ArcXe.kext"
find "$EXT/ArcXe.kext" -name '._*' -delete; chown -R root:wheel "$EXT/ArcXe.kext"; chmod -R 755 "$EXT/ArcXe.kext"
codesign -f -s - "$EXT/ArcXe.kext" || { echo "STOP: signing failed"; rm -rf "$EXT/ArcXe.kext"; exit 1; }
NEW=$KC.arc-new; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / --allow-missing-kdk -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z -v > "$B/kmutil.log" 2>&1; then
  tail -25 "$B/kmutil.log"; rm -rf "$EXT/ArcXe.kext" "$NEW"; echo "FAILED: kmutil (nothing changed)"; exit 1; fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null)
for id in $IDS com.arc.ArcXe; do printf '%s\n' "$INS" | grep -q "^$id[[:space:]]" || { echo "FAILED: $id missing (nothing changed)"; rm -rf "$EXT/ArcXe.kext" "$NEW"; exit 1; }; done
mv -f "$NEW" "$KC"; sync
echo "OK (backup $B). Restart and allow it in Privacy & Security if asked. ArcXe stays idle until: sudo bash $HERE/arc-mode.sh on"
