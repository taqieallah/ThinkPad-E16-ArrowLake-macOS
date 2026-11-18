#!/bin/bash
# On the Mac (M5):   bash build-k23.sh            (30-90 min the first time; safe to run again)
# K23 = MeowXE3 (cuadra8998: NullMoth's NMXGPU = Linux 6.14 xe on macOS, with NMXAccel, the Metal plugin, ANV, Zink)
# for the ThinkPad E16's Arrow Lake H (8086:7D51). MeowXE3 ships for Intel Xe3 (Wildcat / Panther Lake); its kernel
# driver is rebuilt here from the same sources and patches with Arrow Lake H moved from i915 to xe (arl-on-xe.py), and
# swapped into MeowXE3's release package together with the Meteor Lake GPU firmware Arrow Lake uses.
# Output: ~/Desktop/MeowARL (installer + payload), also copied to /Volumes/1401/xegfx-e16/MeowARL when the stick is in.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export NULLMOTH_BUILD_ROOT=${NULLMOTH_BUILD_ROOT:-$HOME/nmx}
ROOT=$NULLMOTH_BUILD_ROOT; SRC=$ROOT/build/gpu-src; OUT=$ROOT/out
MEOW_COMMIT=fdb56f4                     # MeowXE3 main on 2026-11-17 (1.0.12 + hand-off)
REL=v1.0.12; RELZIP=MeowXE3-1.0.12.zip
PKG=$HOME/Desktop/MeowARL; VER=1.0.71   # 1.0.12 + Arrow Lake
log() { printf '\n>>> %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "STOP: missing $1"; exit 1; }; }
need git; need python3; need rsync; need curl; need ditto; need codesign
xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || { echo "STOP: Command Line Tools missing: xcode-select --install"; exit 1; }
# MeowXE3 builds on the 26 SDK: use 26.x when the Mac has one (xcrun does not know CLT SDKs by version name, so by path)
SDK=""; for d in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk \
    /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26*.sdk; do [ -d "$d" ] && { SDK=$d; break; }; done
if [ -n "$SDK" ]; then export SDKROOT=$SDK; fi
echo "SDK: ${SDK:-default $(xcrun --sdk macosx --show-sdk-version) (no 26.x SDK found)}"
mkdir -p "$ROOT"

log "1/6 MeowXE3 sources ($MEOW_COMMIT)"
M=$ROOT/MeowXE3-repo
[ -d "$M/.git" ] || git clone -q https://github.com/cuadra8998/MeowXE3.git "$M"
git -C "$M" fetch -q origin && git -C "$M" -c advice.detachedHead=false checkout -q -f "$MEOW_COMMIT" && git -C "$M" clean -qfd

log "2/6 NMXGPU sources at MeowXE3's pins + its patches (setup-nmxgpu-wcl.sh)"
if [ -f "$SRC/xkpi/.k23-setup-done" ] && [ "${FRESH:-0}" != 1 ]; then echo "already set up (FRESH=1 redoes it)"
else
  python3 -I "$HERE/fix-meow-patches.py" "$M"     # 0104 repeats ericek's drm-kmod hunk: git refuses it as published
  # the setup's fetch restores changed files but keeps files earlier patches added: start drm-kmod clean
  [ -d "$SRC/kpi/drm-kmod/.git" ] && { git -C "$SRC/kpi/drm-kmod" reset -q --hard; git -C "$SRC/kpi/drm-kmod" clean -qfdx; }
  bash "$M/patches/nmxgpu/setup-nmxgpu-wcl.sh"; touch "$SRC/xkpi/.k23-setup-done"; fi

log "3/6 Arrow Lake H on xe"
python3 -I "$HERE/arl-on-xe.py" "$SRC" $SDK

log "4/6 build NMXGPU (log: $SRC/xkpi/k23-build.log)"
cd "$SRC/xkpi"
if [ -f "$OUT/NMXGPU.kext/Contents/MacOS/NMXGPU" ] && [ "${REBUILD:-0}" != 1 ] && [ "$OUT/NMXGPU.kext/Contents/MacOS/NMXGPU" -nt override/xe/nmx_xe_module.c ]; then
  echo "built already (REBUILD=1 builds again)"
else
  ./build-guest.sh all "$OUT" 2>&1 | tee k23-build.log | grep -E "compile failures|NMXGPU [0-9a-f]{8}|error:" | tail -20
  grep -q "compile failures: 0" k23-build.log || { echo "STOP: compile failures - send me $SRC/xkpi/k23-build.log and logs*/*.failed"; exit 1; }
fi
B=$OUT/NMXGPU.kext/Contents/MacOS/NMXGPU
[ -f "$B" ] || { echo "STOP: no $B"; exit 1; }
# (grep on the file itself: "strings | grep -q" fails under pipefail when grep stops at the first match)
LC_ALL=C grep -aq "fd81,7d51,7dd1" "$B" || { echo "STOP: the built driver has no 7d51 in its force_probe list"; exit 1; }
echo "NMXGPU: $(stat -f %z "$B") bytes, force_probe has 7d51"

log "5/6 MeowXE3 $REL release package"
R=$ROOT/release; mkdir -p "$R"
if [ ! -f "$R/$RELZIP" ]; then
  if [ -f "$HOME/Downloads/$RELZIP" ]; then cp "$HOME/Downloads/$RELZIP" "$R/"
  else curl -fL --retry 3 -o "$R/$RELZIP.part" "https://github.com/cuadra8998/MeowXE3/releases/download/$REL/$RELZIP" && mv "$R/$RELZIP.part" "$R/$RELZIP" \
    || { echo "STOP: download $RELZIP from https://github.com/cuadra8998/MeowXE3/releases into ~/Downloads, then run this again"; exit 1; }; fi
fi
rm -rf "$R/x"; mkdir -p "$R/x"; ditto -x -k "$R/$RELZIP" "$R/x"
INST=$(find "$R/x" -name "Install MeowXE3.command" -maxdepth 3 | head -1)
[ -n "$INST" ] || { echo "STOP: no installer in $RELZIP"; exit 1; }
SRCPKG=$(dirname "$INST")
[ -f "$SRCPKG/payload/MeowXE3.kext/Contents/MacOS/MeowXE3" ] || { echo "STOP: no payload/MeowXE3.kext in $RELZIP"; exit 1; }

log "6/6 package $PKG"
rm -rf "$PKG"; ditto "$SRCPKG" "$PKG"
K=$PKG/payload/MeowXE3.kext; PB=/usr/libexec/PlistBuddy
echo "release kexts:"; for k in "$K" "$K"/Contents/PlugIns/*.kext; do
  echo "  $(basename "$k") $($PB -c 'Print :CFBundleVersion' "$k/Contents/Info.plist")"; done
# the driver: our build, under MeowXE3's name (bundle ids, plug-ins and Info.plist stay MeowXE3's)
cp "$B" "$K/Contents/MacOS/MeowXE3"
$PB -c "Set :CFBundleVersion $VER" -c "Set :CFBundleShortVersionString $VER" "$K/Contents/Info.plist"
rm -rf "$K/Contents/_CodeSignature"; codesign -f -s - "$K" 2>&1 | grep -v "replacing existing" || true
codesign -v --deep "$K" && echo "signed ad hoc"
# Arrow Lake's GPU firmware: xe 6.14 asks Meteor Lake's GuC/HuC/GSC by these names, the display Meteor Lake's DMC
FWS=$ROOT/repos/linux-firmware/i915; FWD=$PKG/payload/firmware/i915; mkdir -p "$FWD"
n=0; for f in "$FWS"/mtl_guc_70.bin "$FWS"/mtl_huc_gsc.bin "$FWS"/mtl_gsc_*.bin "$FWS"/mtl_dmc.bin; do
  [ -f "$f" ] && { cp "$f" "$FWD/"; n=$((n+1)); }; done
[ -f "$FWD/mtl_guc_70.bin" ] && [ -f "$FWD/mtl_dmc.bin" ] || { echo "STOP: Meteor Lake GuC/DMC firmware missing in $FWS"; exit 1; }
echo "firmware: $n Meteor Lake files"; ls "$FWD"
# the installer accepts 8086:7D51 (as an untested GPU) and calls this package's version
I="$PKG/Install MeowXE3.command"
grep -q '^SUPPORTED="fd80"' "$I" || { echo "STOP: installer's SUPPORTED line changed"; exit 1; }
python3 -I - "$I" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('SUPPORTED="fd80"', 'SUPPORTED="fd80"\nARL="7d51 7dd1"   # E16 k23: Arrow Lake H on xe (MeowARL)', 1)
old = '  elif [[ " $XE3_OTHER " == *" $id "* ]]; then'
new = ('  elif [[ " $ARL " == *" $id "* ]]; then warn "GPU 8086:$(echo "$id" | tr a-f A-F) Arrow Lake H - MeowARL (E16 k23), first runs"; CHECK_WARN=1\n'
       + old)
assert s.count(old) == 1, "installer GPU check changed"
s = s.replace(old, new, 1)
# OpenCore on a USB stick volume (the E16's "1401": EFI/OC at the root of a plain volume, not a partition named EFI)
eo = '    [ -n "$MNT_BY_US" ] && diskutil unmount "$dev" >/dev/null 2>&1; MNT_BY_US=""\n  done\n  return 1\n}'
en = ('    [ -n "$MNT_BY_US" ] && diskutil unmount "$dev" >/dev/null 2>&1; MNT_BY_US=""\n  done\n'
      '  # E16 k23: OpenCore on a mounted volume (a USB stick such as 1401); MEOWARL_OC=<EFI/OC folder> picks one\n'
      '  local c; for c in ${MEOWARL_OC:-} /Volumes/*/EFI/OC; do\n'
      '    [ -f "$c/config.plist" ] && { OC=$c; ESP=$(df "$c" | awk \'NR==2 {print $1}\'); return 0; }; done\n'
      '  return 1\n}')
assert s.count(eo) == 1, "installer find_esp changed"
s = s.replace(eo, en, 1)
# started from the FAT stick: run from a clean copy on the Mac's own disk. A FAT volume keeps every file's extended
# attributes as an AppleDouble file (._name); copied into a kext or bundle they break its code seal.
ho = 'HERE=$(cd "$(dirname "$0")" && pwd)\n'
hn = (ho + '# E16 k23: from a FAT (msdos) volume such as the stick: copy the package to local disk without AppleDouble files and\n'
      '# extended attributes, then run that copy (same arguments; sudo is asked there as usual)\n'
      'if [ -z "${MEOWARL_LOCAL:-}" ] && mount | grep -q "^$(df "$HERE" | awk \'NR==2 {print $1}\') on .*(msdos"; then\n'
      '  L=/Users/Shared/MeowARL-run; echo "MeowARL: copying the package off the stick to $L ..."\n'
      '  rm -rf "$L" && ditto --norsrc --noextattr --noqtn "$HERE" "$L" || { echo "copy to $L failed"; exit 1; }\n'
      '  find "$L" -name "._*" -delete 2>/dev/null; xattr -cr "$L" 2>/dev/null\n'
      '  MEOWARL_LOCAL=1 exec bash "$L/$(basename "$0")" "$@"\n'
      'fi\n')
assert s.count(ho) == 1, "installer HERE line changed"
s = s.replace(ho, hn, 1)
s = s.replace('exec sudo MEOWXE3_FAST="$FAST" bash "$0" "$@"', 'exec sudo MEOWXE3_FAST="$FAST" MEOWARL_LOCAL="${MEOWARL_LOCAL:-}" bash "$0" "$@"', 1)
open(p, "w").write(s)
EOF
bash -n "$I" && echo "installer accepts 7D51"
# a package copied through the FAT stick carries AppleDouble files (._Info.plist ...): inside a kext they break its
# code seal ("a sealed resource is missing or invalid"). The driver install drops them and the copies' xattrs.
python3 -I - "$PKG/payload/install-meowxe3.sh" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
a = '[ -f "$HERE/MeowXE3.kext/Contents/MacOS/MeowXE3" ] || { echo "MeowXE3.kext missing next to this script"; exit 1; }\n'
b = a + ('# E16 k23: AppleDouble files from a FAT copy (._*) out of the payload; they break the kexts\' and bundles\' seals\n'
         'find "$HERE" -name "._*" -delete 2>/dev/null; true\n')
c = 'rm -rf $K && cp -R "$HERE/MeowXE3.kext" $E/ || { echo "copy failed"; exit 1; }\n'
d = c + 'find $K -name "._*" -delete 2>/dev/null; xattr -cr $K 2>/dev/null   # E16 k23: nothing but the bundle in the seal\n'
assert s.count(a) == 1 and s.count(c) == 1, "install-meowxe3.sh changed"
open(p, "w").write(s.replace(a, b, 1).replace(c, d, 1))
EOF
bash -n "$PKG/payload/install-meowxe3.sh" && echo "driver install drops AppleDouble files"
# the laptop has no Command Line Tools (fresh macOS, maybe offline): dwarfdump there is only an installer stub. The kext's
# UUID is read here, on the build Mac, and the install checks the collection against that file.
dwarfdump --uuid "$K/Contents/MacOS/MeowXE3" | awk '{print $2; exit}' > "$PKG/payload/MeowXE3.uuid"
grep -qE '^[0-9A-F-]{36}$' "$PKG/payload/MeowXE3.uuid" || { echo "STOP: no UUID for MeowXE3"; exit 1; }
python3 -I - "$PKG/payload/install-meowxe3.sh" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
a = "WANT=$(dwarfdump --uuid $K/Contents/MacOS/MeowXE3 | awk '{print $2}')\n"
b = ('# E16 k23: the UUID comes from the build Mac (no Command Line Tools needed here)\n'
     'WANT=$(cat "$HERE/MeowXE3.uuid" 2>/dev/null)\n'
     '[ -n "$WANT" ] || WANT=$(dwarfdump --uuid $K/Contents/MacOS/MeowXE3 | awk \'{print $2}\')\n')
assert s.count(a) == 1, "install-meowxe3.sh UUID line changed"
open(p, "w").write(s.replace(a, b, 1))
EOF
bash -n "$PKG/payload/install-meowxe3.sh" && echo "install checks the UUID from MeowXE3.uuid ($(cat "$PKG/payload/MeowXE3.uuid"))"
cp "$HERE/k23-collect.sh" "$HERE/README-k23.txt" "$PKG/"
echo "$VER $(date '+%F %T') MeowXE3 $MEOW_COMMIT + arl-on-xe; NMXGPU $(shasum -a 256 "$B" | cut -c1-12)" > "$PKG/MeowARL-VERSION.txt"

if [ -d /Volumes/1401/xegfx-e16 ]; then T=/Volumes/1401/xegfx-e16/MeowARL
  rm -rf "$T"; mkdir -p "$T"; rsync -rt --exclude '._*' --exclude .DS_Store "$PKG/" "$T/"; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true; sync
  bad=0; while IFS= read -r f; do cmp -s "$PKG/$f" "$T/$f" || { echo "MISMATCH $f"; bad=1; }; done < <(cd "$PKG" && find . -type f ! -name '._*')
  [ $bad = 0 ] && echo "copied to $T (checked)" || { echo "STOP: the copy on the stick differs - run this again"; exit 1; }
else echo "stick not in: copy $PKG to /Volumes/1401/xegfx-e16/MeowARL later"; fi
echo; echo "DONE. On the laptop (fresh macOS): read MeowARL/README-k23.txt"
