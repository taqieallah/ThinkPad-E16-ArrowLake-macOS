#!/bin/bash
# On the Mac: ArcMTL stage 1 for the E16 (ArcXe.kext + arc_probe), opt-in only.
#   bash ~/Desktop/xe-update/arc/build-arc.sh
# ArcXe stays OFF on a normal boot (our XeGfx stack untouched); it attaches only when OpenCore passes arcxe=1.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HOME/src/ArcMTL; PIN=e04b0fa7385244656d85cea26762904632465c89
L=$HERE/build-arc.log; : > "$L"; log() { echo "$*"; echo "$*" >> "$L"; }
[ -d "$SRC/.git" ] || git clone https://github.com/longurara/ArcMTL "$SRC" >> "$L" 2>&1
( cd "$SRC" && git fetch -q origin && git checkout -q -f "$PIN" ) >> "$L" 2>&1 || { log "STOP: could not check out ArcMTL $PIN"; exit 1; }
log ">>> ArcMTL $(cd "$SRC" && git log -1 --format='%h %ad %s' --date=short)"
python3 "$HERE/patch-arcxe-e16.py" "$SRC" | tee -a "$L" || { echo "STOP: E16 patches did not apply"; exit 1; }
grep -q E16-NBB "$SRC/kexts/ArcXe/ArcXeExec.cpp" || { echo "STOP: E16-NBB missing"; exit 1; }
OUT=$SRC/out; mkdir -p "$OUT/kexts" "$OUT/tools"
bash "$SRC/kexts/ArcXe/build.sh" "$OUT/kexts" >> "$L" 2>&1 || { tail -30 "$L"; echo "ARCXE BUILD FAILED"; exit 1; }
xcrun clang -arch x86_64 -O2 -Wall -I"$SRC/include" "$SRC/tools/arc_probe.c" -o "$OUT/tools/arc_probe" -framework IOKit -framework CoreFoundation >> "$L" 2>&1 || { tail -20 "$L"; echo "ARC_PROBE BUILD FAILED"; exit 1; }
codesign -f -s - "$OUT/tools/arc_probe" >> "$L" 2>&1
grep -aq arcxe "$OUT/kexts/ArcXe.kext/Contents/MacOS/ArcXe" || { echo "STOP: built ArcXe has no arcxe guard"; exit 1; }
log "    ArcXe.kext $(stat -f %z "$OUT/kexts/ArcXe.kext/Contents/MacOS/ArcXe") B, arc_probe $(stat -f %z "$OUT/tools/arc_probe") B"
U=/Volumes/1401/xegfx-e16/arc
if [ -d /Volumes/1401/xegfx-e16 ]; then
  mkdir -p "$U"; rm -rf "$U/ArcXe.kext"; ditto --norsrc --noextattr "$OUT/kexts/ArcXe.kext" "$U/ArcXe.kext"
  cp "$OUT/tools/arc_probe" "$HERE/arc-install.sh" "$HERE/arc-test2.sh" "$HERE/arc-mode.sh" "$HERE/arc-test.sh" "$U/"
  cp "$HERE/../xe-up.sh" /Volumes/1401/xegfx-e16/xe-up.sh; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true
  log "copied to the USB stick (xegfx-e16/arc + xe-up v10)"
else log "USB stick not mounted: files are in $OUT"; fi
log DONE
