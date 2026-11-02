#!/bin/bash
# On the Mac: rebuild NVMTLDriver (E16 mip fix) and put it next to this script.  bash ~/Desktop/xe-update/build-plugin.sh
set -e; HERE=$(cd "$(dirname "$0")" && pwd); W=$HOME/src/xe-e16; cd "$W"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export PATH=$HOME/.venvs/mesa/bin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
grep -q "E16 mip path" wtl/plugin/NVMTLObjects.m || { echo "STOP: the mip patch is not in wtl/plugin/NVMTLObjects.m"; exit 1; }
XEGFX_DEPS=$W XEGFX_OUT=$W/out RELEASE=1 bash wtl/build/build_plugin.sh > "$HERE/build-plugin.log" 2>&1 || { tail -25 "$HERE/build-plugin.log"; echo "BUILD FAILED"; exit 1; }
cp "$W/out/plugin/NVMTLDriver" "$HERE/NVMTLDriver"; codesign -f -s - "$HERE/NVMTLDriver"
lipo -info "$HERE/NVMTLDriver"; strings "$HERE/NVMTLDriver" | grep -c "E16 mip path" | sed 's/^/mip patch present: /'; echo "DONE -> $HERE/NVMTLDriver"
