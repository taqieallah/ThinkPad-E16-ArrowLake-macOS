#!/bin/bash
# Build the x86_64 apv-host daemon on the MacBook Air.
#
#   bash build.sh
#
# The Reims C library (lib/libreims_vgpu.dylib, x86_64, commit 1fe0acb68) is
# built out of tree; see ../host-proto/build.sh for the exact cargo command that
# produces it. This script only links the daemon against it.
set -euo pipefail
cd "$(dirname "$0")"
xcrun clang++ -std=c++17 -arch x86_64 -mmacosx-version-min=26.0 -O2 -g \
    -Wall -Wextra -I include \
    apv-host.cpp panel.cpp lib/libreims_vgpu.dylib \
    '-Wl,-rpath,@loader_path/lib' \
    -framework IOKit -framework CoreFoundation -framework Metal -framework Foundation \
    -framework IOSurface \
    -pthread -o apv-host
codesign -f -s - apv-host
codesign -f -s - lib/libreims_vgpu.dylib
xcrun lipo -verify_arch x86_64 apv-host
echo "built $PWD/apv-host"
