#!/bin/bash
# On the Mac: build dlprobe for the Intel laptop and put it on the USB stick.   bash ~/Desktop/xe-update/probe/build-probe.sh
set -e; cd "$(dirname "$0")"
clang -arch x86_64 -mmacosx-version-min=13.0 -O2 dlprobe.c -framework CoreVideo -framework CoreGraphics -o dlprobe
codesign -f -s - dlprobe; lipo -info dlprobe
if [ -d /Volumes/1401/xegfx-e16 ]; then cp dlprobe /Volumes/1401/xegfx-e16/dlprobe && echo "copied to /Volumes/1401/xegfx-e16/dlprobe"; else echo "USB not mounted: copy dlprobe to xegfx-e16/ by hand"; fi
