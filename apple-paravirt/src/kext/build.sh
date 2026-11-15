#!/bin/bash
# Build the x86_64 ReimsAPVBridge kext on the MacBook Air (or any macOS host).
#
#   bash build.sh /path/to/MacKernelSDK [output-dir]
#
# The output is a real x86_64 kext for the ThinkPad E16 (macOS 26.7.1 25G241),
# even when the build host is Apple Silicon.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Build on macOS with Xcode or the Command Line Tools." >&2
    exit 1
fi
if [[ $# -lt 1 ]]; then
    echo "Usage: bash build.sh /path/to/MacKernelSDK [output-dir]" >&2
    exit 2
fi

sdk="$(cd "$1" && pwd)"
headers="$sdk/Headers"
libs="$sdk/Library/x86_64"
for required in "$headers/IOKit/pci/IOPCIDevice.h" "$libs/libkmod.a"; do
    if [[ ! -f "$required" ]]; then
        echo "Missing MacKernelSDK file: $required" >&2
        exit 1
    fi
done

out="${2:-build}"
cc="$(xcrun --find clang)"
cxx="$(xcrun --find clang++)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Regenerate the site table from sites.json so the kext and the offline
# verifier can never disagree about addresses or bytes.
python3 ../tooling/gen-site-table.py

name=ReimsPCIProbe
bundle="$tmp/$name.kext"
binary="$bundle/Contents/MacOS/$name"
mkdir -p "$(dirname "$binary")"
target=(-arch x86_64 -mmacosx-version-min=11.0)
flags=("${target[@]}" -mkernel -nostdinc -fno-builtin -fno-common
       -fno-stack-protector -mno-mmx -mno-sse -mno-sse2 -mno-avx
       -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
       -I "$headers" -O2 -Wall -Wextra -Werror)
"$cc" "${flags[@]}" -c kmod.c -o "$tmp/kmod.o"
"$cxx" "${flags[@]}" -std=c++17 -fapple-kext -fno-exceptions -fno-rtti \
    -c ReimsAPVBridge.cpp -o "$tmp/bridge.o"
runtime_dir="$("$cc" -print-resource-dir)/lib/darwin"
runtime=()
if [[ -f "$runtime_dir/libclang_rt.cc_kext.a" ]]; then
    runtime=("$runtime_dir/libclang_rt.cc_kext.a")
fi
"$cc" "${target[@]}" -nostdlib -Xlinker -kext -Xlinker -no_data_const \
    "$tmp/kmod.o" "$tmp/bridge.o" -L"$libs" -lkmod ${runtime[@]+"${runtime[@]}"} -o "$binary"
cp Info.plist "$bundle/Contents/Info.plist"
plutil -lint "$bundle/Contents/Info.plist"
xcrun lipo -verify_arch x86_64 "$binary"
xcrun otool -hv "$binary"

mkdir -p "$out"
if [[ -e "$out/$name.kext" ]]; then
    echo "Move the older $out/$name.kext out of the way before rebuilding." >&2
    exit 1
fi
mv "$bundle" "$out/$name.kext"
echo "Built $PWD/$out/$name.kext"
