#!/bin/bash
# On the Mac: (1) NVMTLDriver with the on-disk pipeline cache (zep245 b214), (2) NullMoth 2.6.6's faster shader
# translator (fxhash, PR #187) + the HONOR A-41 Half fix. Results next to this script.   bash ~/Desktop/xe-update/build-perf.sh
set -e; HERE=$(cd "$(dirname "$0")" && pwd); W=$HOME/src/xe-e16; cd "$W"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export PATH=$HOME/.venvs/mesa/bin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
L=$HERE/build-perf.log; : > "$L"
echo ">>> plugin (pipeline cache)"
grep -q "zep245 b214" wtl/plugin/nvmtl_vk.c || { echo "STOP: pipeline-cache patch missing in wtl/plugin/nvmtl_vk.c"; exit 1; }
XEGFX_DEPS=$W XEGFX_OUT=$W/out RELEASE=1 bash wtl/build/build_plugin.sh >> "$L" 2>&1 || { tail -30 "$L"; echo "PLUGIN BUILD FAILED"; exit 1; }
cp "$W/out/plugin/NVMTLDriver" "$HERE/NVMTLDriver"; codesign -f -s - "$HERE/NVMTLDriver" >> "$L" 2>&1
echo "    pcache in binary: $(grep -ac 'pcache: ' "$HERE/NVMTLDriver")"
echo ">>> translator (NullMoth 2.6.6 + Half fix)"
[ -d nm ] || git clone -q --depth 1 --branch v2.6.6 https://github.com/nullmoth/nvidia-macos-driver.git nm 2>>"$L" || git clone -q --depth 1 https://github.com/nullmoth/nvidia-macos-driver.git nm
T=nm/translator/translator/src/native/emitter/types.rs
grep -q "LlType::Half => self.const_float16_bits(f32_to_f16_bits" $T || perl -0pi -e 's/(LlValue::Float32Bits\(bits\) => match self\.resolve_type\(ty\)\? \{\n\s*LlType::Float => self\.const_float32_bits\(\*bits\),\n)/$1                LlType::Half => self.const_float16_bits(f32_to_f16_bits(f32::from_bits(*bits))),   \/\/ HONOR A-41\n/' $T
grep -q "f32_to_f16_bits(f32::from_bits" $T || { echo "STOP: Half fix did not apply"; exit 1; }
grep -q "fn f32_to_f16_bits" -r nm/translator/translator/src || { echo "STOP: f32_to_f16_bits not in this translator"; exit 1; }
O=$W/out/xlate-nm; mkdir -p "$O"
( cd nm/translator && cargo build --release --target x86_64-apple-darwin --manifest-path wrapper/Cargo.toml --target-dir "$O/target" ) >> "$L" 2>&1 || { tail -30 "$L"; echo "TRANSLATOR BUILD FAILED"; exit 1; }
D=$O/target/x86_64-apple-darwin/release/libnvmtl_translate.dylib
cp "$D" "$HERE/libnvmtl_translate.dylib"; strip -S "$HERE/libnvmtl_translate.dylib"
install_name_tool -id @rpath/libnvmtl_translate.dylib "$HERE/libnvmtl_translate.dylib"; codesign -f -s - "$HERE/libnvmtl_translate.dylib" >> "$L" 2>&1
lipo -info "$HERE/NVMTLDriver" "$HERE/libnvmtl_translate.dylib"; echo "DONE"
