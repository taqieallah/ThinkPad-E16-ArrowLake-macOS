#!/bin/bash
# On the laptop:   sudo bash /Volumes/1401/xegfx-e16/base/base-install.sh        (undo: ... base-install.sh --undo)
# Puts the XeGfx Metal plug-in's base into /Library/GPUBundles (NVMTLDriver.bundle, nvmtl/ with ANV, libdrm, the Vulkan
# loader and the translator, the allow list) with normal modes (folders 755, programs 755, the rest 644, root:wheel):
# a copy from the FAT stick would be rwx------ and WindowServer could not load it. Then run k22/install.sh.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
HERE=$(cd "$(dirname "$0")" && pwd); S=$HERE/GPUBundles; G=/Library/GPUBundles; BK=/Library/XeGfx-E16/base-backup
if [ "${1:-}" = --undo ]; then
  for p in NVMTLDriver.bundle nvmtl nvmtl-allow.txt; do rm -rf "$G/$p"; done
  [ -d "$BK" ] && ditto "$BK" "$G"; echo "base removed (previous contents put back if there were any)"; exit 0; fi
for f in NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver NVMTLDriver.bundle/Contents/Info.plist nvmtl/libvulkan_intel.dylib \
         nvmtl/libdrm.2.dylib nvmtl/libvulkan.dylib nvmtl/libnvmtl_translate.dylib nvmtl/intel_icd.json; do
  [ -f "$S/$f" ] || { echo "STOP: $f missing in $S"; exit 1; }; done
mkdir -p "$G" "$BK"
for p in NVMTLDriver.bundle nvmtl nvmtl-allow.txt; do [ -e "$G/$p" ] && { rm -rf "$BK/$p"; mv "$G/$p" "$BK/$p"; }; done
ditto --norsrc --noextattr "$S" "$G"
find "$G" -name '._*' -delete; xattr -cr "$G" 2>/dev/null
chown -R root:wheel "$G"
find "$G" -type d -exec chmod 755 {} +; find "$G" -type f -exec chmod 644 {} +
find "$G" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O && chmod 755 "$1"' _ {} \;
codesign -v "$G/NVMTLDriver.bundle" 2>&1 && echo "bundle signature OK"
sudo -u _windowserver test -r "$G/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" && echo "WindowServer can read the plug-in"
ls -la "$G" "$G/nvmtl"
echo "DONE. Now:  sudo bash /Volumes/1401/xegfx-e16/k22/install.sh   then restart, log in, and:"
echo "            sudo bash /Volumes/1401/xegfx-e16/k22/xe-up.sh --fast"
