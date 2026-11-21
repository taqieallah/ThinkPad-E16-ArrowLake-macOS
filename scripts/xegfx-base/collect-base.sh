#!/bin/bash
# On the Mac M5, stick in:   bash ~/src/xe-e16/e16-repo/scripts/xegfx-base/collect-base.sh
# The laptop was cleaned: /Library/GPUBundles is empty, and k22/install.sh only UPDATES an installed XeGfx Metal plug-in.
# This puts together the plug-in's base from what the Mac already has (nothing is built, nothing downloaded):
#   GPUBundles/NVMTLDriver.bundle   Info.plist + Resources from a NullMoth bundle on the Mac, MacOS/NVMTLDriver = the k22
#                                   package's E16 plug-in (pipeline cache, completion marks, mip path)
#   GPUBundles/nvmtl/libvulkan_intel.dylib + libdrm.2.dylib   Mesa ANV + libdrm built for XeGfx (~/src/xe-e16/prefix)
#   GPUBundles/nvmtl/libvulkan.dylib                           the Khronos Vulkan loader (x86_64)
#   GPUBundles/nvmtl/libnvmtl_translate.dylib                  NullMoth 2.6.6 translator + E16 half fix
#   GPUBundles/nvmtl/intel_icd.json, nvrm610.conf (INTEL_DEBUG=noccs,nofc), GPUBundles/nvmtl-allow.txt
# Output: ~/Desktop/xegfx-base, copied to /Volumes/1401/xegfx-e16/base with base-install.sh (checked).
# It prints every file it picked: send me the output if anything says MISSING.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); OUT=$HOME/Desktop/xegfx-base; G=$OUT/GPUBundles; N=$G/nvmtl
STICK=/Volumes/1401/xegfx-e16; GB=/Library/GPUBundles/nvmtl
rm -rf "$OUT"; mkdir -p "$N" "$G/NVMTLDriver.bundle/Contents/MacOS"; bad=0
pick() {  # pick <label> <candidates...>: first existing x86_64 file
  local l=$1; shift
  for f in "$@"; do [ -f "$f" ] || continue
    lipo -archs "$f" 2>/dev/null | grep -q x86_64 || { [ "${f##*.}" = json ] || continue; }
    echo "  $l: $f ($(stat -f '%z bytes, %Sm' "$f"))" >&2; echo "$f"; return 0; done
  echo "  $l: MISSING" >&2; return 1; }
newest() { find "$@" -type f 2>/dev/null | while read -r f; do stat -f '%m %N' "$f"; done | sort -rn | cut -d' ' -f2-; }

echo ">>> plug-in binary"
P=$(pick NVMTLDriver "$STICK/k22/NVMTLDriver" "$HOME/Desktop/k22/NVMTLDriver" "$STICK/final/NVMTLDriver" "$HOME/Desktop/xe-update/NVMTLDriver") || bad=1
[ -n "${P:-}" ] && { grep -aq "E16 mip path" "$P" || echo "  !! $P has no 'E16 mip path' (not the E16 plug-in?)"; cp "$P" "$G/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"; }

echo ">>> bundle Info.plist (from a NullMoth bundle on the Mac)"
SK=""; for b in "$HOME"/Desktop/MeowARL-1.0.71-baseline/payload/GPUBundles/NVMTLDriver.bundle "$HOME"/Desktop/MeowARL*/payload/GPUBundles/NVMTLDriver.bundle "$STICK"/MeowARL*/payload/GPUBundles/NVMTLDriver.bundle; do
  [ -f "$b/Contents/Info.plist" ] && { SK=$b; break; }; done
if [ -n "$SK" ]; then echo "  Info.plist: $SK"; cp "$SK/Contents/Info.plist" "$G/NVMTLDriver.bundle/Contents/"
  [ -d "$SK/Contents/Resources" ] && ditto "$SK/Contents/Resources" "$G/NVMTLDriver.bundle/Contents/Resources"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$G/NVMTLDriver.bundle/Contents/Info.plist"
else echo "  Info.plist: MISSING"; bad=1; fi

echo ">>> Mesa ANV + libdrm"
A=$(pick libvulkan_intel $(newest "$HOME/src/xe-e16/prefix/lib" -name libvulkan_intel.dylib) $(newest "$HOME/src" -maxdepth 6 -name libvulkan_intel.dylib -not -path '*MeowARL*' -not -path '*nmx*')) || bad=1
D=""; [ -n "${A:-}" ] && D=$(pick libdrm "$(dirname "$A")/libdrm.2.dylib" $(newest "$HOME/src/xe-e16/prefix/lib" -name libdrm.2.dylib)) || bad=1
if [ -n "${A:-}" ] && [ -n "$D" ]; then
  cp "$A" "$N/libvulkan_intel.dylib"; cp "$D" "$N/libdrm.2.dylib"; chmod u+w "$N"/*.dylib
  OLDDRM=$(otool -L "$N/libvulkan_intel.dylib" | awk '/libdrm\.2\.dylib/ {print $1; exit}')
  install_name_tool -id "$GB/libdrm.2.dylib" "$N/libdrm.2.dylib" 2>/dev/null
  install_name_tool -id "$GB/libvulkan_intel.dylib" ${OLDDRM:+-change "$OLDDRM" "$GB/libdrm.2.dylib"} "$N/libvulkan_intel.dylib" 2>/dev/null
  echo "  ANV now links: $(otool -L "$N/libvulkan_intel.dylib" | awk 'NR>1 && /libdrm/ {print $1}')"
fi

echo ">>> Vulkan loader"
L=$(pick libvulkan $(newest "$HOME/src" -maxdepth 7 \( -name 'libvulkan.1.dylib' -o -name 'libvulkan.1.*.dylib' -o -name libvulkan.dylib \) -not -name '*intel*') \
    "$HOME"/Desktop/MeowARL-1.0.71-baseline/payload/GPUBundles/nvmtl/libvulkan.1.*.dylib "$HOME"/Desktop/MeowARL*/payload/GPUBundles/nvmtl/libvulkan.1.*.dylib) || bad=1
[ -n "${L:-}" ] && { cp "$L" "$N/libvulkan.dylib"; chmod u+w "$N/libvulkan.dylib"; install_name_tool -id "$GB/libvulkan.dylib" "$N/libvulkan.dylib" 2>/dev/null; }

echo ">>> translator"
T=$(pick translator "$HOME/Desktop/xe-update/libnvmtl_translate.dylib" "$HOME/Desktop/xe-update/GPUBundles/nvmtl/libnvmtl_translate.dylib") || bad=1
[ -n "${T:-}" ] && cp "$T" "$N/libnvmtl_translate.dylib"

echo ">>> settings"
printf '{\n    "file_format_version": "1.0.1",\n    "ICD": {\n        "library_path": "%s",\n        "api_version": "1.4.363",\n        "library_arch": "64"\n    }\n}\n' "$GB/libvulkan_intel.dylib" > "$N/intel_icd.json"
printf 'INTEL_DEBUG=noccs,nofc\n' > "$N/nvrm610.conf"
printf '# E16: programs that get the GPU through Metal\nWindowServer\nsystem_profiler\nSystem Information\n*\n' > "$G/nvmtl-allow.txt"
find "$G" -type f \( -name '*.dylib' -o -name NVMTLDriver \) -exec codesign -f -s - {} \; 2>/dev/null
codesign -f -s - "$G/NVMTLDriver.bundle" 2>/dev/null && codesign -v "$G/NVMTLDriver.bundle" && echo "  bundle signed"
cp "$HERE/base-install.sh" "$OUT/"
echo; find "$G" -type f | sed "s|$OUT/||"
[ $bad = 0 ] || { echo; echo "STOP: something is MISSING above - send me this output"; exit 1; }
if [ -d "$STICK" ]; then rm -rf "$STICK/base"; mkdir -p "$STICK/base"
  rsync -rt --exclude '._*' --exclude .DS_Store "$OUT/" "$STICK/base/"; dot_clean "$STICK/base" 2>/dev/null; sync
  ok=1; while IFS= read -r f; do cmp -s "$OUT/$f" "$STICK/base/$f" || { echo "MISMATCH $f"; ok=0; }; done < <(cd "$OUT" && find . -type f)
  [ $ok = 1 ] && echo "copied to $STICK/base (checked)" || { echo "STOP: copy differs, run again"; exit 1; }
else echo "stick not in: copy $OUT to /Volumes/1401/xegfx-e16/base later"; fi
echo "DONE. On the laptop:  sudo bash /Volumes/1401/xegfx-e16/base/base-install.sh   then   sudo bash /Volumes/1401/xegfx-e16/k22/install.sh"
