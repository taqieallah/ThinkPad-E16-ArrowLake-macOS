#!/bin/bash
# On the Mac: rebuild XeGfxAccel (XGDR selector 1 = WindowServer completion marks) and NVMTLDriver (sends them), and put
# both on the USB stick if it is mounted.       bash ~/Desktop/xe-update/build-k9.sh
set -e; HERE=$(cd "$(dirname "$0")" && pwd); W=$HOME/src/xe-e16; cd "$W"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export PATH=$HOME/.venvs/mesa/bin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
L=$HERE/build-k9.log; : > "$L"
grep -q "XGDR selector 1" wtl/kexts/XeGfxAccel/accel/nvrm-accel.cpp || { echo "STOP: accel patch missing"; exit 1; }
grep -q "nvmtl_xe_gpu_mark" wtl/plugin/nvmtl_vk.c || { echo "STOP: plugin patch missing"; exit 1; }
echo ">>> XeGfxAccel"; export OGKM=$W/ogkm OUTROOT=$W/out/kexts
bash wtl/build/build_xegfxaccel.sh >> "$L" 2>&1 || { tail -30 "$L"; echo "ACCEL BUILD FAILED"; exit 1; }
K=$W/out/kexts/XeGfxAccel/26/XeGfxAccel.kext; [ -d "$K" ] || { echo "STOP: $K not built"; exit 1; }
echo "    $K"; rm -rf "$HERE/XeGfxAccel.kext"; ditto "$K" "$HERE/XeGfxAccel.kext"
echo ">>> NVMTLDriver"
XEGFX_DEPS=$W XEGFX_OUT=$W/out RELEASE=1 bash wtl/build/build_plugin.sh >> "$L" 2>&1 || { tail -30 "$L"; echo "PLUGIN BUILD FAILED"; exit 1; }
cp "$W/out/plugin/NVMTLDriver" "$HERE/NVMTLDriver"; codesign -f -s - "$HERE/NVMTLDriver" >> "$L" 2>&1
echo "    marks over XGDR in plugin: $(grep -ac 'XGDR selector 1' "$HERE/NVMTLDriver")   pcache: $(grep -ac 'pcache: ' "$HERE/NVMTLDriver")"
if [ -d /Volumes/1401/xegfx-e16 ]; then D=/Volumes/1401/xegfx-e16
  rm -rf "$D/kexts/XeGfxAccel.kext"; ditto --norsrc --noextattr "$HERE/XeGfxAccel.kext" "$D/kexts/XeGfxAccel.kext"
  cp "$HERE/NVMTLDriver" "$D/NVMTLDriver"; cp "$HERE/NVMTLDriver" "$D/userland/NVMTLDriver"; cp "$HERE/k9-install.sh" "$HERE/xe-up.sh" "$D/"
  dot_clean "$D" 2>/dev/null; echo "copied to the USB stick"; else echo "USB not mounted - copy XeGfxAccel.kext, NVMTLDriver, k9-install.sh by hand"; fi
echo DONE
