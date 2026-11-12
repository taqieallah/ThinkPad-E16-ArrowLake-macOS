#!/bin/bash
# On the Mac (M5):   bash ~/Desktop/xe-update/k14/build-k14.sh
# K14 phase 1: the Xiaomi-pad Metal stack (UniXNU's AdrenoMetal bridge on the metal2vulkan runtime) built for x86_64 and
# run on our ANV, as a plain program: nothing on the laptop's system changes. Output: k14/xe-m2v-probe + k14-run.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=$HOME/src/xe-e16/k14; mkdir -p "$D"; L=$HERE/build-k14.log; : > "$L"
export PATH=$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
M2V_REV=555b13d57; AM_REV=c1351337d7e4ca00c80e1b7efeaf404bddc1be9e
step() { echo ">>> $*"; echo ">>> $*" >> "$L"; }

step "1/5 Rust (1.98 or newer, x86_64 target)"
command -v rustup >/dev/null || { echo "STOP: rustup missing (brew install rustup && rustup-init -y)"; exit 1; }
rustup toolchain install stable --profile minimal >> "$L" 2>&1
rustup target add --toolchain stable x86_64-apple-darwin >> "$L" 2>&1
echo "    $(rustc +stable --version)"

step "2/5 LLVM's llvm-as (assembles the self-test's AIR)"
LLAS=""; for c in /opt/homebrew/opt/llvm/bin/llvm-as /opt/homebrew/opt/llvm@21/bin/llvm-as /opt/homebrew/opt/llvm@20/bin/llvm-as; do [ -x "$c" ] && { LLAS=$c; break; }; done
if [ -z "$LLAS" ]; then echo "    installing llvm with Homebrew (a few minutes)"; brew install llvm >> "$L" 2>&1 || { tail -5 "$L"; echo "STOP: brew install llvm failed"; exit 1; }; LLAS=/opt/homebrew/opt/llvm/bin/llvm-as; fi
echo "    $($LLAS --version | grep -i version | head -1)"

step "3/5 sources: metal2vulkan $M2V_REV + AdrenoMetal's bridge patches, AdrenoMetal $AM_REV"
[ -d "$D/m2v/.git" ] || git clone -q https://github.com/steelbrain/metal2vulkan "$D/m2v"
[ -d "$D/am/.git" ] || git clone -q https://github.com/UniXNU/AdrenoMetal "$D/am"
git -C "$D/am" fetch -q origin; git -C "$D/am" checkout -q -f "$AM_REV"
git -C "$D/m2v" fetch -q origin; git -C "$D/m2v" checkout -q -f "$M2V_REV"; git -C "$D/m2v" clean -qfd
for p in "$D"/am/bridge/patches/*.patch; do git -C "$D/m2v" apply "$p" || { echo "STOP: patch $(basename "$p") does not apply"; exit 1; }; done

step "4/5 the probe crate"
P=$D/probe; rm -rf "$P"; mkdir -p "$P/src" "$P/air" "$P/deps"; cp "$HERE/probe/Cargo.toml" "$HERE/probe/build.rs" "$P/"; cp "$HERE/probe/src/main.rs" "$P/src/"
ln -sfn "$D/m2v" "$P/deps/m2v"; ln -sfn "$D/am" "$P/deps/am"
F=$D/m2v/crates/metal2vulkan-validation/fixtures/public/examples
$LLAS "$F/runtime_examples.ll" -o "$P/air/runtime_examples.air"
$LLAS "$D/am/shaders/scanout_convert.ll" -o "$P/air/scanout_convert.air"
: > "$P/air/fc.air"
echo "    AIR $(stat -f %z "$P/air/runtime_examples.air") B"

step "5/5 cargo build (x86_64-apple-darwin, release)"
( cd "$P" && cargo +stable build --release --target x86_64-apple-darwin ) >> "$L" 2>&1 || { grep -E "^error" -A6 "$L" | head -40; echo "BUILD FAILED (log $L)"; exit 1; }
B=$P/target/x86_64-apple-darwin/release/xe-m2v-probe; lipo -archs "$B" | grep -q x86_64 || { echo "STOP: not x86_64"; exit 1; }
cp "$B" "$HERE/xe-m2v-probe"; codesign -f -s - "$HERE/xe-m2v-probe" >> "$L" 2>&1
echo "    xe-m2v-probe $(stat -f %z "$HERE/xe-m2v-probe") B"
if [ -d /Volumes/1401/xegfx-e16 ]; then T=/Volumes/1401/xegfx-e16/k14; mkdir -p "$T"; cp "$HERE/xe-m2v-probe" "$HERE/k14-run.sh" "$T/"; dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true; echo "copied to /Volumes/1401/xegfx-e16/k14"
else echo "USB not mounted: copy k14/xe-m2v-probe and k14/k14-run.sh to the stick's xegfx-e16/k14"; fi
echo DONE
