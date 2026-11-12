#!/bin/bash
# On the Mac (M5), after build-k14.sh:   bash ~/Desktop/xe-update/k14/build-k14b.sh
# K14 phase 2a: UniXNU's AdrenoMetal frontend + bridge as one x86_64 program (xe-m2v-bench) that times the same desktop-like
# CoreAnimation scene on today's NVMTLDriver and on the new stack. Nothing is installed on the laptop.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=$HOME/src/xe-e16/k14; L=$HERE/build-k14b.log; : > "$L"
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
TC=$(dirname "$(rustup which --toolchain stable rustc)"); export PATH=$TC:$PATH RUSTC=$TC/rustc
LLAS=/opt/homebrew/opt/llvm/bin/llvm-as
[ -d "$D/m2v" ] && [ -d "$D/am" ] && [ -x "$LLAS" ] || { echo "STOP: run build-k14.sh first"; exit 1; }
S=$D/nmbstatic; rm -rf "$S"; mkdir -p "$S/air" "$S/deps"; cp "$HERE/bench/nmbstatic/Cargo.toml" "$HERE/bench/nmbstatic/build.rs" "$S/"
ln -sfn "$D/m2v" "$S/deps/m2v"; ln -sfn "$D/am" "$S/deps/am"
F=$D/m2v/crates/metal2vulkan-validation/fixtures/public
$LLAS "$F/examples/runtime_examples.ll" -o "$S/air/runtime_examples.air"
$LLAS "$D/am/shaders/scanout_convert.ll" -o "$S/air/scanout_convert.air"
$LLAS "$F/kernel_function_constant_gate_fold.ll" -o "$S/air/fc.air"
echo ">>> 1/3 the bridge as a static library (x86_64)"
( cd "$S" && "$TC/cargo" build --release --target x86_64-apple-darwin ) >> "$L" 2>&1 || { grep -E "^error" -A8 "$L" | head -40; echo "BRIDGE BUILD FAILED (log $L)"; exit 1; }
A=$S/target/x86_64-apple-darwin/release/libnmb.a; echo "    libnmb.a $(stat -f %z "$A") B"
echo ">>> 2/3 the AdrenoMetal frontend (x86_64, ARC)"
O=$D/obj; mkdir -p "$O"
CXX=(clang++ -arch x86_64 -mmacosx-version-min=14.0 -std=gnu++2b -fobjc-arc -O2 -g -w -I"$D/am" -I"$D/am/bridge")
FE=$D/am/NativeBridgeMetalFrontend.x86.mm
git -C "$D/am" show beeab71:NativeBridgeMetalFrontend.mm > "$FE"   # f6f3808 (diagnostics) left code outside its functions
python3 "$HERE/bench/fix-frontend.py" "$FE" >> "$L"
"${CXX[@]}" -c "$FE" -o "$O/frontend.o" >> "$L" 2>&1 || { grep -E "error:" "$L" | head -30; echo "FRONTEND COMPILE FAILED (log $L)"; exit 1; }
echo ">>> 3/3 xe-m2v-bench"
"${CXX[@]}" -c "$HERE/bench/xe_m2v_bench.mm" -o "$O/bench.o" >> "$L" 2>&1 || { grep -E "error:" "$L" | head -20; echo "BENCH COMPILE FAILED"; exit 1; }
clang++ -arch x86_64 -mmacosx-version-min=14.0 "$O/bench.o" "$O/frontend.o" "$A" -o "$HERE/xe-m2v-bench" \
  -framework Foundation -framework Metal -framework QuartzCore -framework CoreImage -framework CoreGraphics -framework IOSurface \
  -framework IOKit -framework Security -framework CoreFoundation -lc++ -lresolv >> "$L" 2>&1 \
  || { grep -E "Undefined|error|ld:" -A3 "$L" | head -40; echo "LINK FAILED (log $L)"; exit 1; }
codesign -f -s - "$HERE/xe-m2v-bench" >> "$L" 2>&1; echo "    xe-m2v-bench $(stat -f %z "$HERE/xe-m2v-bench") B"
if [ -d /Volumes/1401/xegfx-e16 ]; then T=/Volumes/1401/xegfx-e16/k14; mkdir -p "$T"; cp "$HERE/xe-m2v-bench" "$HERE/k14b-run.sh" "$T/"; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true; echo "copied to $T"
else echo "USB not mounted: copy k14/xe-m2v-bench and k14/k14b-run.sh to the stick's xegfx-e16/k14"; fi
echo DONE
