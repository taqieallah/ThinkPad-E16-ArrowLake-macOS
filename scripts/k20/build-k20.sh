#!/bin/bash
# On the Mac (M5):   bash ~/Desktop/xe-update/k20/build-k20.sh   -> ~/Desktop/k20-laptop (send it to the laptop by AnyDesk)
# K20 phase 1 (the reims idea on bare metal): reims-vgpu's host side - the part that, in a VM, runs outside macOS and
# executes what Apple's paravirtual GPU driver sends - built for x86_64 macOS on its Vulkan platform (metal2vulkan),
# so that it runs on the laptop over our ANV. Plus reims's own test runner (pgrun), which plays the VM and drives the
# host side exactly as the guest driver would. Nothing is installed on the laptop.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=$HOME/src/xe-e16/k20; mkdir -p "$D"; L=$HERE/build-k20.log; : > "$L"
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
REV=1fe0acb   # reims-vgpu main of 2026-10-29
AREAS="smoke blit compute render_draw render_pass textures display_present fifo_framing device_create"
echo ">>> 1/4 reims-vgpu $REV"
[ -d "$D/reims/.git" ] || git clone -q https://github.com/steelbrain/reims-vgpu "$D/reims"
git -C "$D/reims" fetch -q origin; git -C "$D/reims" checkout -q -f "$REV"
cd "$D/reims"
echo ">>> 2/4 Rust (the repo pins its toolchain) + x86_64 target"
rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)" --profile minimal >> "$L" 2>&1
rustup target add x86_64-apple-darwin >> "$L" 2>&1
TC=$(dirname "$(rustup which rustc)"); export PATH=$TC:$PATH RUSTC=$TC/rustc; echo "    $("$TC/rustc" --version)"
# the Vulkan crate compiles its Metal shaders with Xcode's Metal toolchain on a Mac; this Mac has only the command-line
# tools, so it takes the metallibs the repo commits for Linux builds (the same files, checked by their sha256 record)
sed -i '' 's/if !cfg!(target_os = "macos") {/if true { \/\/ k20: committed metallibs (no Xcode Metal toolchain)/' crates/reims-vgpu-vulkan/build.rs
grep -q "k20: committed metallibs" crates/reims-vgpu-vulkan/build.rs || { echo "STOP: build.rs patch did not apply"; exit 1; }
echo ">>> 3/4 libreims_vgpu.dylib (Vulkan platform, x86_64, no SDL) - several minutes"
"$TC/cargo" build --release -p reims-vgpu-c --lib --no-default-features --features vulkan --target x86_64-apple-darwin >> "$L" 2>&1 \
  || { grep -E "^error" -A8 "$L" | head -40; echo "BUILD FAILED (log $L)"; exit 1; }
O=$HOME/Desktop/k20-laptop; rm -rf "$O"; mkdir -p "$O/scenarios" "$O/expected"
cp target/x86_64-apple-darwin/release/libreims_vgpu_c.dylib "$O/libreims_vgpu.dylib"; install_name_tool -id @rpath/libreims_vgpu.dylib "$O/libreims_vgpu.dylib"
echo ">>> 4/4 pgrun (x86_64) + scenarios: $AREAS"
clang -arch x86_64 -mmacosx-version-min=26.0 -fobjc-arc -O1 -g -Wno-deprecated-declarations -Wno-unguarded-availability-new \
  -I crates/reims-vgpu-c/include "$O/libreims_vgpu.dylib" -Wl,-rpath,@executable_path -framework Foundation -framework Metal \
  tests/suite/runner/pgrun.m -o "$O/pgrun" >> "$L" 2>&1 || { tail -20 "$L"; echo "PGRUN BUILD FAILED"; exit 1; }
codesign -f -s - "$O/libreims_vgpu.dylib" "$O/pgrun" >> "$L" 2>&1
cp -R tests/suite/fixtures "$O/fixtures"
for a in $AREAS; do cp -R "tests/suite/generated/$a" "$O/scenarios/"; cp -R "tests/suite/expected/$a" "$O/expected/"; done
cp "$HERE/k20-run.sh" "$O/"
echo "    $(ls "$O"/scenarios/*/*.jsonl | wc -l | tr -d ' ') scenarios, $(du -sh "$O" | cut -f1)"
echo "    ready: ~/Desktop/k20-laptop - send that whole folder to the laptop's Desktop (AnyDesk file transfer)"
echo DONE
