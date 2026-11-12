#!/bin/bash
# On the Mac (M5):   bash ~/Desktop/xe-update/k12/build-k12.sh
# K12 = apps and Safari reach the GPU without /dev/dri (their sandbox refuses it): XeGfx core + XeGfxAccel with the
# XGDR open/close/list selectors (core/build-core.sh rebuilds both and the plugin), and libdrm that uses them.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); UP=$(dirname "$HERE"); W=$HOME/src/xe-e16; WTL=$W/wtl
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export PATH=$HOME/.venvs/mesa/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
L=$HERE/build-k12.log; : > "$L"
grep -q "xg_fd_task_open" "$WTL/shim/src/xnu/xg_fd.cpp" || { echo "STOP: K12 kernel sources are not in $WTL"; exit 1; }
grep -q "selector 2 (kind 0 card" "$WTL/kexts/XeGfxAccel/accel/nvrm-accel.cpp" || { echo "STOP: K12 accel source missing"; exit 1; }
grep -q "drmXeGfxOpendir" "$WTL/userland/patches/libdrm-xegfx.patch" || { echo "STOP: K12 libdrm patch missing"; exit 1; }

echo ">>> 1/3 XeGfx core + XeGfxAccel + NVMTLDriver (core/build-core.sh, takes a while)"
bash "$UP/core/build-core.sh" || { echo "CORE BUILD FAILED - see $UP/core/build-core.log"; exit 1; }
grep -aq "xgDrmOpen" "$UP/kexts/XeGfx.kext/Contents/MacOS/XeGfx" || { echo "STOP: built core has no xgDrmOpen"; exit 1; }
grep -aq "XGDR open" "$UP/kexts/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel" || { echo "STOP: built accel has no XGDR open"; exit 1; }

echo ">>> 2/3 libdrm 2.4.134 for x86_64 with the K12 patch"
D=$W/drm-k12; rm -rf "$D"
git clone -q https://gitlab.freedesktop.org/mesa/drm.git "$D" >> "$L" 2>&1 || git clone -q https://github.com/freedesktop/mesa-drm.git "$D" >> "$L" 2>&1
git -C "$D" checkout -q b97cbde15c5c3abfe44d78e8f57139e50f612fec
git -C "$D" apply "$WTL/userland/patches/libdrm-macos.patch"
git -C "$D" apply "$WTL/userland/patches/libdrm-xegfx.patch"
cat > "$D/x86.ini" <<INI
[binaries]
c = ['clang', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
[built-in options]
c_args = ['-mmacosx-version-min=14.0']
c_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=14.0']
[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
INI
meson setup "$D/build" "$D" --cross-file "$D/x86.ini" --prefix="$D/prefix" --libdir=lib -Dbuildtype=release \
  -Dintel=disabled -Damdgpu=disabled -Dradeon=disabled -Dnouveau=disabled -Dvmwgfx=disabled -Domap=disabled \
  -Dexynos=disabled -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled -Dfreedreno=disabled \
  -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dinstall-test-programs=false >> "$L" 2>&1 \
  || { tail -30 "$L"; echo "LIBDRM CONFIGURE FAILED"; exit 1; }
ninja -C "$D/build" >> "$L" 2>&1 || { tail -30 "$L"; echo "LIBDRM BUILD FAILED"; exit 1; }
meson install -C "$D/build" >> "$L" 2>&1
LIB=$D/prefix/lib/libdrm.2.dylib
lipo -archs "$LIB" | grep -q x86_64 || { echo "STOP: libdrm is not x86_64"; exit 1; }
nm -gU "$LIB" | grep -q _drmXeGfxOpendir || { echo "STOP: libdrm lacks the K12 functions"; exit 1; }
cp -L "$LIB" "$HERE/libdrm.2.dylib"; install_name_tool -id @rpath/libdrm.2.dylib "$HERE/libdrm.2.dylib"; codesign -f -s - "$HERE/libdrm.2.dylib" >> "$L" 2>&1
echo "    libdrm.2.dylib $(stat -f %z "$HERE/libdrm.2.dylib") B"

echo ">>> 3/3 drmtest"
clang -arch x86_64 -mmacosx-version-min=14.0 -I"$D/prefix/include" -I"$D/prefix/include/libdrm" "$HERE/drmtest.c" \
  "$HERE/libdrm.2.dylib" -o "$HERE/drmtest" >> "$L" 2>&1 || { tail -10 "$L"; echo "DRMTEST BUILD FAILED"; exit 1; }
codesign -f -s - "$HERE/drmtest" >> "$L" 2>&1

if [ -d /Volumes/1401/xegfx-e16 ]; then T=/Volumes/1401/xegfx-e16/k12; mkdir -p "$T"
  cp "$HERE/libdrm.2.dylib" "$HERE/drmtest" "$HERE/k12-install.sh" "$HERE/k12-test.sh" "$T/"; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true
  echo "copied to the USB stick (kexts + plugin by build-core, k12/ by this script)"
else echo "USB not mounted: copy kexts/, NVMTLDriver, full-install.sh and k12/ by hand"; fi
echo DONE
