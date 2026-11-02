#!/bin/bash
# On the laptop: install the rebuilt NVMTLDriver.  sudo bash /Volumes/1401/xegfx-e16/plugin-install.sh   (then restart)
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$HERE/NVMTLDriver" ] || { echo "STOP: NVMTLDriver is not next to this script"; exit 1; }
T=$(find /Library/GPUBundles -path '*NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver' -type f | head -1)
[ -n "$T" ] || { echo "STOP: installed NVMTLDriver not found under /Library/GPUBundles"; exit 1; }
cp -p "$T" "$T.before-mip" 2>/dev/null; cp "$HERE/NVMTLDriver" "$T"; chown root:wheel "$T"; chmod 755 "$T"; codesign -f -s - "$T"
cp "$HERE/NVMTLDriver" "$HERE/userland/NVMTLDriver" 2>/dev/null
echo "installed -> $T  (old copy: $T.before-mip)"; grep -ac "E16 mip path" "$T" | sed 's/^/mip patch present: /'
echo "now restart, log in, and run xe-up.sh as usual"
