#!/bin/bash
# On the Mac: the whole ArcMTL desktop for the E16 = ArcXe + ArcFB + ArcAccel (Tahoe) + AIR->SPIR-V translator +
# ArcMTLDriver.bundle (Metal plugin). Mesa ANV comes from build-arc-anv.sh (run that first).
#   bash ~/Desktop/xe-update/arc/build-arc-full.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HOME/src/ArcMTL; TP=$SRC/third_party
NMPIN=470e391e8cf8d7e499cdabfa7f2daadb6e14bcfd
L=$HERE/build-arc-full.log; : > "$L"; log() { echo "$*"; echo "$*" >> "$L"; }
[ -f "$SRC/out/arcmtl/libvulkan_intel.dylib" ] || { echo "run build-arc-anv.sh first"; exit 1; }
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
( cd "$SRC" && git fetch -q origin && git checkout -q -f e04b0fa7385244656d85cea26762904632465c89 ) >> "$L" 2>&1
python3 "$HERE/patch-arcxe-e16.py" "$SRC" | tee -a "$L" || { echo "STOP: E16 patches did not apply"; exit 1; }
log ">>> ArcMTL $(cd "$SRC" && git log -1 --format='%h %ad %s' --date=short)"
log ">>> Mesa ANV with this ArcMTL's patches (incremental)"
bash "$HERE/build-arc-anv.sh" >> "$L" 2>&1 || { tail -20 "$HERE/build-arc-anv.log"; echo "MESA STEP FAILED (log: $HERE/build-arc-anv.log)"; exit 1; }
OUT=$SRC/out; mkdir -p "$OUT/kexts/26" "$OUT/arcmtl" "$OUT/GPUBundles" "$OUT/tools"

log ">>> kexts"
bash "$SRC/kexts/ArcXe/build.sh" "$OUT/kexts" >> "$L" 2>&1 || { tail -30 "$L"; echo "ARCXE FAILED"; exit 1; }
bash "$SRC/kexts/ArcFB/build.sh" "$OUT/kexts" >> "$L" 2>&1 || { tail -30 "$L"; echo "ARCFB FAILED"; exit 1; }
ARC_TAHOE=1 bash "$SRC/kexts/ArcAccel/build.sh" "$OUT/kexts/26" >> "$L" 2>&1 || { tail -30 "$L"; echo "ARCACCEL FAILED"; exit 1; }
for k in kexts/ArcXe kexts/ArcFB kexts/26/ArcAccel; do n=$(basename $k); log "    $n.kext $(stat -f %z "$OUT/$k.kext/Contents/MacOS/$n") B"; done

log ">>> NullMoth translator + plugin sources (pinned ${NMPIN:0:7})"
if [ ! -d "$TP/nullmoth/.git" ]; then
  git clone -q --filter=blob:none --sparse https://github.com/nullmoth/nvidia-macos-driver.git "$TP/nullmoth" >> "$L" 2>&1
  ( cd "$TP/nullmoth" && git sparse-checkout set --no-cone /LICENSE /NOTICE '/translator/**' '/plugin/**' ) >> "$L" 2>&1
fi
( cd "$TP/nullmoth" && git fetch -q origin && git checkout -q -f "$NMPIN" ) >> "$L" 2>&1 || { log "STOP: NullMoth $NMPIN not available"; exit 1; }

log ">>> translator (Rust, x86_64)"
rustup target add x86_64-apple-darwin >> "$L" 2>&1 || true
( cd "$TP/nullmoth/translator" && MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --release --target x86_64-apple-darwin \
    --manifest-path wrapper/Cargo.toml --target-dir "$SRC/build/xlate-target" ) >> "$L" 2>&1 || { tail -30 "$L"; echo "TRANSLATOR FAILED"; exit 1; }
T=$OUT/arcmtl/libarcmtl_translate.dylib
cp -f "$SRC/build/xlate-target/x86_64-apple-darwin/release/libnvmtl_translate.dylib" "$T"
strip -S "$T"; install_name_tool -id /Library/GPUBundles/arcmtl/libarcmtl_translate.dylib "$T"; codesign -f -s - "$T" >> "$L" 2>&1
TS=$(nm -gU "$T" | awk '{print $3}')
for s in _nvmtl_translate _nvmtl_translate_free _nvmtl_reflect _nvmtl_lower_buffer_addresses; do
  grep -Fxq "$s" <<<"$TS" || { log "STOP: translator lacks $s"; exit 1; }; done
log "    libarcmtl_translate.dylib $(stat -f %z "$T") B ($(lipo -archs "$T"))"

log ">>> ArcMTLDriver.bundle"
PS=$SRC/build/arc-plugin-src; B=$OUT/GPUBundles/ArcMTLDriver.bundle
python3 "$SRC/plugin/adapt_arc_plugin.py" "$TP/nullmoth/plugin" "$PS" >> "$L" 2>&1 || { tail -20 "$L"; echo "PLUGIN ADAPT FAILED"; exit 1; }
rm -rf "$B"; mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources"
( cd "$PS" && MACOSX_DEPLOYMENT_TARGET=15.0 xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -bundle -fobjc-arc -fvisibility=hidden -O2 -DNVMTL_RELEASE=1 \
    -Wno-protocol -Wno-incomplete-implementation -Wno-deprecated-declarations -Wno-objc-protocol-method-implementation \
    -I"$TP/Vulkan-Headers/include" -I"$PS" -o "$B/Contents/MacOS/ArcMTLDriver" "$PS/ArcMTLDevice.m" \
    -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework QuartzCore ) >> "$L" 2>&1 || { grep -E 'error' "$L" | head -20; echo "PLUGIN BUILD FAILED"; exit 1; }
cp -f "$SRC/plugin/Info.plist" "$B/Contents/Info.plist"; cp -f "$SRC/plugin/arcmtl-allow.txt" "$OUT/GPUBundles/arcmtl-allow.txt"
# air-runtime/libLLVM.dylib: Homebrew's LLVM here is arm64 only, so on the laptop install links macOS's own x86_64
# libLLVM (GPUCompiler.framework) at /Library/GPUBundles/arcmtl/air-runtime/libLLVM.dylib, a path the plugin also tries
PSY=$(nm -gU "$B/Contents/MacOS/ArcMTLDriver")
grep -Fq '_OBJC_CLASS_$_ArcMTLDevice' <<<"$PSY" || { log "STOP: plugin has no ArcMTLDevice class"; exit 1; }
codesign -f -s - "$B" >> "$L" 2>&1
log "    ArcMTLDriver $(stat -f %z "$B/Contents/MacOS/ArcMTLDriver") B ($(lipo -archs "$B/Contents/MacOS/ArcMTLDriver"))"

U=/Volumes/1401/xegfx-e16/arc
if [ -d /Volumes/1401/xegfx-e16 ]; then
  F=$U/full; rm -rf "$F"; mkdir -p "$F/kexts" "$F/arcmtl" "$F/GPUBundles"
  for k in ArcXe ArcFB; do ditto --norsrc --noextattr "$OUT/kexts/$k.kext" "$F/kexts/$k.kext"; done
  ditto --norsrc --noextattr "$OUT/kexts/26/ArcAccel.kext" "$F/kexts/ArcAccel.kext"
  cp -f "$OUT/arcmtl/libvulkan_intel.dylib" "$OUT/arcmtl/intel_icd.json" "$T" "$F/arcmtl/"
  ditto --norsrc --noextattr "$B" "$F/GPUBundles/ArcMTLDriver.bundle"; cp -f "$OUT/GPUBundles/arcmtl-allow.txt" "$F/GPUBundles/"
  cp -f "$HERE/arc-full-install.sh" "$HERE/arc-mode.sh" "$U/"; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true
  log "copied to the USB stick (xegfx-e16/arc/full)"
else log "USB stick not mounted: files are in $OUT"; fi
log DONE
