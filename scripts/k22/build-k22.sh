#!/bin/bash
# On the Mac (M5):   bash build-k22.sh          (from wherever this folder is; the USB stick "1401" may be in)
# K22 = late-frame GPU clock floor: when WindowServer's composite is still running 3 ms after the flip worker took its
# frame, the SLPC minimum clock is raised to the maximum, and put back 150 ms after the last late frame (ArrowWhatever
# 0035/0036's idea, written for this tree). Rebuilds XeGfx core + XeGfxAccel from this repository's driver/ sources,
# then makes a k22 package = the final 1.0.1 package with the two new kexts.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); W=$HOME/src/xe-e16; WTL=$W/wtl; UP=$HOME/Desktop/xe-update
R=$W/e16-repo; FINAL=$HOME/Desktop/E16-final/xegfx-e16/final; OUT=$HOME/Desktop/k22
[ -d "$WTL/kexts/XeGfxAccel" ] || { echo "STOP: no driver tree in $WTL"; exit 1; }
[ -f "$UP/core/build-core.sh" ] || { echo "STOP: no $UP/core/build-core.sh (the script that built final 1.0.1)"; exit 1; }
[ -f "$FINAL/install.sh" ] || { echo "STOP: no final 1.0.1 package in $FINAL"; exit 1; }

echo ">>> 1/4 repository"
if [ -d "$R/.git" ]; then git -C "$R" pull -q --ff-only; else git clone -q https://github.com/taqieallah/ThinkPad-E16-ArrowLake-macOS.git "$R"; fi
grep -q "xg_i915_gt_boost" "$R/driver/xkpi/src/i915/xg_i915_exec.c" || { echo "STOP: the repository has no k22 sources yet"; exit 1; }
echo "    $(git -C "$R" log -1 --format='%h %s' | cut -c1-90)"

echo ">>> 2/4 k22 sources into $WTL (the previous files are kept in $WTL/.k22-backup)"
F="xkpi/src/i915/xg_i915_exec.c shim/include/xg_i915.h shim/src/xnu/xg_kext.cpp kexts/XeGfxAccel/accel/nvrm-accel.cpp"
mkdir -p "$WTL/.k22-backup"
# the Mac's files must be the repository's files from before k22 (or already k22); anything else would be lost
BASE=$(git -C "$R" log --format=%H --grep='^k22: late-frame' | tail -1)
[ -n "$BASE" ] || { echo "STOP: no k22 commit in the repository"; exit 1; }
for f in $F; do
  if ! git -C "$R" show "$BASE^:driver/$f" | cmp -s - "$WTL/$f" && ! cmp -s "$R/driver/$f" "$WTL/$f"; then
    [ "${FORCE:-0}" = 1 ] || { echo "STOP: $WTL/$f has changes the repository does not (FORCE=1 overwrites; a copy is kept)"; exit 1; }; fi
  [ -f "$WTL/.k22-backup/$(basename "$f")" ] || cp -p "$WTL/$f" "$WTL/.k22-backup/$(basename "$f")"
  cp "$R/driver/$f" "$WTL/$f"; done
grep -q "xgGtMin" "$WTL/shim/src/xnu/xg_kext.cpp" && grep -q "E16 k22" "$WTL/kexts/XeGfxAccel/accel/nvrm-accel.cpp" || { echo "STOP: copy failed"; exit 1; }

echo ">>> 3/4 build (core takes a while; log: $UP/core/build-core.log)"
REBUILD=1 bash "$UP/core/build-core.sh"
grep -aq "xgGtMin" "$UP/kexts/XeGfx.kext/Contents/MacOS/XeGfx" || { echo "STOP: built core has no xgGtMin"; exit 1; }
grep -aq "E16 k22" "$UP/kexts/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel" || { echo "STOP: built accel has no k22 floor"; exit 1; }

echo ">>> 4/4 package $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"; rsync -a --exclude '._*' --exclude .DS_Store "$FINAL/" "$OUT/"
for k in XeGfx XeGfxAccel; do rm -rf "$OUT/kexts/$k.kext"; ditto "$UP/kexts/$k.kext" "$OUT/kexts/$k.kext"; done
cp "$HERE/k22-measure.sh" "$HERE/cpu-measure.sh" "$HERE/README-k22.txt" "$OUT/"
sed -i '' 's/E16 final 1.0 installed/E16 k22 installed/' "$OUT/install.sh"
if [ -d /Volumes/1401/xegfx-e16 ]; then T=/Volumes/1401/xegfx-e16/k22
  rm -rf "$T"; mkdir -p "$T"; rsync -rt --exclude '._*' --exclude .DS_Store "$OUT/" "$T/"; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true; sync
  bad=0; while IFS= read -r f; do cmp -s "$OUT/$f" "$T/$f" || { echo "MISMATCH $f"; bad=1; }; done < <(cd "$OUT" && find . -type f ! -name '._*')
  [ $bad = 0 ] && echo "copied to $T (checked)" || { echo "STOP: copy to the stick differs - run this again"; exit 1; }
else echo "stick not in: copy $OUT to /Volumes/1401/xegfx-e16/k22 later (or AnyDesk)"; fi
echo "DONE. On the laptop:  sudo bash /Volumes/1401/xegfx-e16/k22/install.sh   (undo: ... install.sh --undo)"
