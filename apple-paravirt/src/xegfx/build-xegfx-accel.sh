#!/bin/bash
# Build (and ad-hoc sign) the patched XeGfxAccel from the WTLIntelGfx tree in this directory.
#
#   bash build-xegfx-accel.sh
#
# Environment:
#   WTL_TREE  tree to build (default: ./wtl)
#   OUTROOT   output root (default: ./kexts)  -> $OUTROOT/XeGfxAccel/26/XeGfxAccel.kext
#   OGKM      open-gpu-kernel-modules 615.78.08 tree (default: ~/src/xe-e16/ogkm)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tree="${WTL_TREE:-$here/wtl}"
out="${OUTROOT:-$here/kexts}"
export OGKM="${OGKM:-$HOME/src/xe-e16/ogkm}"
[ -d "$tree/kexts/XeGfxAccel" ] || { echo "STOP: $tree is not the WTLIntelGfx tree" >&2; exit 1; }
[ -d "$OGKM/src/nvidia" ] || { echo "STOP: OGKM=$OGKM is not an open-gpu-kernel-modules tree" >&2; exit 1; }
grep -q XG_PANEL_SELECTOR "$tree/kexts/XeGfxAccel/accel/xg_panel_abi.h" || {
    echo "STOP: the tree has no panel patch (xg_panel_abi.h missing)" >&2; exit 1; }
( cd "$tree" && OUTROOT="$out" bash build/build_xegfxaccel.sh )
kext="$out/XeGfxAccel/26/XeGfxAccel.kext"
[ -d "$kext" ] || { echo "STOP: build produced no kext at $kext" >&2; exit 1; }
codesign -f -s - "$kext"
codesign --verify --strict "$kext"
xcrun lipo -verify_arch x86_64 "$kext/Contents/MacOS/XeGfxAccel"
grep -aq 'XG_PANEL ABI 1' "$kext/Contents/MacOS/XeGfxAccel" || {
    echo "STOP: built kext lacks the panel marker" >&2; exit 1; }
shasum -a 256 "$kext/Contents/MacOS/XeGfxAccel"
echo "built and signed $kext"
