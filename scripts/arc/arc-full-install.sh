#!/bin/bash
# On the laptop: the ArcMTL desktop (ArcXe + ArcFB + ArcAccel + Mesa ANV + translator + ArcMTLDriver.bundle).
# All three kexts stay idle unless their boot-args are set (arc-mode.sh desktop), so normal XeGfx boots are untouched.
#   sudo bash /Volumes/1401/xegfx-e16/arc/arc-full-install.sh         undo: ... --undo
HERE=$(cd "$(dirname "$0")" && pwd); F=$HERE/full; [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc; GB=/Library/GPUBundles
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
KEXTS="ArcXe ArcFB ArcAccel"
if [ "${1:-}" = --undo ]; then
  B=$(ls -d /Library/XeGfx-E16/arcfull-backup-* 2>/dev/null | tail -1); [ -n "$B" ] || { echo "no backup"; exit 1; }
  cp -p "$B/AuxiliaryKernelExtensions.kc" "$KC"; rm -rf "$EXT/ArcFB.kext" "$EXT/ArcAccel.kext" "$GB/ArcMTLDriver.bundle" "$GB/arcmtl" "$GB/arcmtl-allow.txt"
  [ -d "$B/ArcXe.kext" ] && { rm -rf "$EXT/ArcXe.kext"; ditto "$B/ArcXe.kext" "$EXT/ArcXe.kext"; }
  echo "restored from $B - restart"; exit 0; fi
for k in $KEXTS; do [ -f "$F/kexts/$k.kext/Contents/MacOS/$k" ] || { echo "STOP: $k.kext missing"; exit 1; }; done
for f in arcmtl/libvulkan_intel.dylib arcmtl/libarcmtl_translate.dylib arcmtl/intel_icd.json GPUBundles/ArcMTLDriver.bundle/Contents/MacOS/ArcMTLDriver GPUBundles/arcmtl-allow.txt; do
  [ -e "$F/$f" ] || { echo "STOP: $f missing"; exit 1; }; done
grep -aq arcxe "$F/kexts/ArcXe.kext/Contents/MacOS/ArcXe" || { echo "STOP: ArcXe without the opt-in guard"; exit 1; }
B=/Library/XeGfx-E16/arcfull-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$B"; cp -p "$KC" "$B/"
[ -d "$EXT/ArcXe.kext" ] && ditto "$EXT/ArcXe.kext" "$B/ArcXe.kext"
IDS=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk '{print $1}' | grep -E '^[a-z]+\.[A-Za-z0-9.-]+$' | grep -v '^com\.apple\.')
# the kexts were stamped with the Mac's library versions: re-stamp them with this Mac's (the laptop's) own
MAP=$(for k in /System/Library/Extensions/*.kext /System/Library/Extensions/*.kext/Contents/PlugIns/*.kext; do
  p=$k/Contents/Info.plist; [ -f "$p" ] || continue
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$p" 2>/dev/null) || continue
  v=$(/usr/libexec/PlistBuddy -c "Print :OSBundleCompatibleVersion" "$p" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$p" 2>/dev/null)
  echo "$id $v"; done)
for k in $KEXTS; do
  rm -rf "$EXT/$k.kext"; ditto --norsrc --noextattr "$F/kexts/$k.kext" "$EXT/$k.kext"; find "$EXT/$k.kext" -name '._*' -delete
  P=$EXT/$k.kext/Contents/Info.plist
  for lib in $(/usr/libexec/PlistBuddy -c "Print :OSBundleLibraries" "$P" | awk '/ = /{print $1}'); do
    case $lib in com.apple.kpi.*) continue;; esac
    v=$(printf '%s\n' "$MAP" | awk -v i="$lib" '$1==i{print $2; exit}')
    [ -n "$v" ] && /usr/libexec/PlistBuddy -c "Set :OSBundleLibraries:$lib $v" "$P" && echo "  $k: $lib -> $v"
  done
  chown -R root:wheel "$EXT/$k.kext"; chmod -R 755 "$EXT/$k.kext"; codesign -f -s - "$EXT/$k.kext" >/dev/null 2>&1
done
NEW=$KC.arc-new; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / --allow-missing-kdk -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z -v > "$B/kmutil.log" 2>&1; then
  tail -30 "$B/kmutil.log"; rm -f "$NEW"; rm -rf "$EXT/ArcFB.kext" "$EXT/ArcAccel.kext"; echo "FAILED: kmutil (kernel collection unchanged; log $B/kmutil.log)"; exit 1; fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null)
for id in $IDS com.arc.ArcXe com.arc.ArcFB com.arc.ArcAccel; do printf '%s\n' "$INS" | grep -q "^$id[[:space:]]" || {
  echo "FAILED: $id missing from the new collection (unchanged)"; rm -f "$NEW"; exit 1; }; done
mv -f "$NEW" "$KC"
# userspace
rm -rf "$GB/ArcMTLDriver.bundle" "$GB/arcmtl"; mkdir -p "$GB/arcmtl/aircache" "$GB/arcmtl/spvcache" "$GB/arcmtl/air-runtime"
ditto --norsrc --noextattr "$F/GPUBundles/ArcMTLDriver.bundle" "$GB/ArcMTLDriver.bundle"
cp -f "$F/arcmtl/"* "$GB/arcmtl/"; cp -f "$F/GPUBundles/arcmtl-allow.txt" "$GB/arcmtl-allow.txt"
LL=$(ls -d /System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/*/Libraries/libLLVM.dylib 2>/dev/null | tail -1)
[ -n "$LL" ] && ln -sfn "$LL" "$GB/arcmtl/air-runtime/libLLVM.dylib" && echo "  AIR reader: $LL"
find "$GB/ArcMTLDriver.bundle" "$GB/arcmtl" -name '._*' -delete
chown -R root:wheel "$GB/ArcMTLDriver.bundle" "$GB/arcmtl" "$GB/arcmtl-allow.txt"; chmod -R go-w,a+rX "$GB/ArcMTLDriver.bundle" "$GB/arcmtl"
chown -R _windowserver:wheel "$GB/arcmtl/aircache" "$GB/arcmtl/spvcache"
for f in "$GB/arcmtl/"*.dylib "$GB/ArcMTLDriver.bundle"; do codesign -f -s - "$f" >/dev/null 2>&1; done
sync; echo "OK (backup $B)."
echo "Next: sudo bash $HERE/arc-mode.sh desktop   then restart. Back to normal: arc-mode.sh off (from the Mac too)."
