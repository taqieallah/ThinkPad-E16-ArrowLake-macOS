#!/bin/bash
# On the Mac: build the x86_64 frame-rate bench and put it (and fps-check.sh) on the USB stick.
set -e; H=$(cd "$(dirname "$0")" && pwd)
xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -fobjc-arc -O2 "$H/ca_bench.m" -o "$H/ca_bench" -framework Cocoa -framework QuartzCore
codesign -f -s - "$H/ca_bench"; lipo -archs "$H/ca_bench"
cp "$H/ca_bench" "$H/../fps-check.sh" /Volumes/1401/xegfx-e16/ && echo "copied to the USB stick"
