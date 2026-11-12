#!/bin/bash
# On the Mac:   bash ~/Desktop/xe-update/k13/build-k13.sh
# K13 = hardware mouse cursor. XeGfxIntelFB 0.9.5 accepts the E16's GOP framebuffer at 0xff600000 (0.9.4 refused it:
# "hw cursor off: display not as the GOP left it"), so the pointer moves on its own plane instead of WindowServer
# recompositing the screen around it on every move.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); W=$HOME/src/xe-e16; WTL=$W/wtl
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
grep -q "E16 0.9.5" "$WTL/kexts/XeGfxIntelFB/intelfb.cpp" || { echo "STOP: the 0.9.5 source is not in $WTL"; exit 1; }
OUTROOT=$W/out/kexts bash "$WTL/build/build_xegfxintelfb.sh"
K=$W/out/kexts/XeGfxIntelFB/XeGfxIntelFB.kext
grep -aq "E16 0.9.5\|0.9.5" "$K/Contents/Info.plist" || { echo "STOP: built kext is not 0.9.5"; exit 1; }
rm -rf "$HERE/XeGfxIntelFB.kext"; ditto "$K" "$HERE/XeGfxIntelFB.kext"
if [ -d /Volumes/1401/xegfx-e16 ]; then T=/Volumes/1401/xegfx-e16/k13; mkdir -p "$T"
  rm -rf "$T/XeGfxIntelFB.kext"; ditto --norsrc --noextattr "$HERE/XeGfxIntelFB.kext" "$T/XeGfxIntelFB.kext"
  cp "$HERE/k13-install.sh" "$T/"; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true; echo "copied to /Volumes/1401/xegfx-e16/k13"
else echo "USB not mounted: copy k13/XeGfxIntelFB.kext and k13/k13-install.sh to the stick's xegfx-e16/k13"; fi
echo DONE
