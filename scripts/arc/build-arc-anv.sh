#!/bin/bash
# On the Mac: ArcMTL stage 2 = Mesa ANV (Vulkan) for ArcXe + vk_offscreen_test, cross-built for x86_64.
#   bash ~/Desktop/xe-update/arc/build-arc-anv.sh
# Homebrew no longer runs on Intel, so: the normal (arm64) Homebrew provides the build tools, Mesa's two build-time
# compilers (mesa_clc, vtn_bindgen2) are built for arm64 first, then Mesa ANV is cross-compiled for x86_64. The x86
# binaries meson wants to test-run go through Rosetta.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HOME/src/ArcMTL; TP=$SRC/third_party; MESA=$TP/mesa
L=$HERE/build-arc-anv.log; : > "$L"; log() { echo "$*"; echo "$*" >> "$L"; }
[ -d "$SRC/.git" ] || { echo "run build-arc.sh first"; exit 1; }
arch -x86_64 /usr/bin/true 2>/dev/null || { log ">>> installing Rosetta"; softwareupdate --install-rosetta --agree-to-license; }
BREW=/opt/homebrew/bin/brew
if [ ! -x $BREW ]; then log ">>> installing Homebrew (asks for your password)"; /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; fi
HB=$($BREW --prefix); export PATH="$HB/bin:/usr/bin:/bin:/usr/sbin:/sbin"; export HOMEBREW_NO_AUTO_UPDATE=1
log ">>> build tools (arm64 Homebrew)"
$BREW install meson ninja pkgconf bison flex glslang llvm spirv-llvm-translator spirv-tools libclc python3 >> "$L" 2>&1 || { tail -30 "$L"; echo "BREW FAILED"; exit 1; }
python3 -m pip install --user --break-system-packages mako pyyaml packaging >> "$L" 2>&1 || true
python3 -c 'import mako, yaml, packaging' || { echo "STOP: python3 has no mako/yaml/packaging"; exit 1; }
export PATH="$HB/opt/bison/bin:$HB/opt/flex/bin:$PATH"
log "    meson $(meson --version), llvm $($HB/opt/llvm/bin/llvm-config --version)"
log ">>> sources"
[ -d "$TP/Vulkan-Headers/.git" ] || git clone -q --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git "$TP/Vulkan-Headers" >> "$L" 2>&1
[ -d "$MESA/.git" ] || git clone -q --depth 1 --branch mesa-26.2.6 https://gitlab.freedesktop.org/mesa/mesa.git "$MESA" >> "$L" 2>&1
python3 "$SRC/mesa-anv/apply_mesa_anv_macos.py" "$MESA" >> "$L" 2>&1 || { tail -20 "$L"; echo "ARC MESA PATCH FAILED"; exit 1; }
log "    Mesa $(cat "$MESA/VERSION") + ArcXe IOKit shim"

log ">>> 1/2 Mesa build-time compilers for this Mac (arm64)"
NAT=$SRC/build/mesa-native; TOOLS=$SRC/build/mesa-native-tools; mkdir -p "$TOOLS"
LLVMP="$HB/opt/llvm/bin"
if [ ! -f "$NAT/build.ninja" ]; then
  PATH="$LLVMP:$PATH" PKG_CONFIG_PATH="$HB/opt/llvm/lib/pkgconfig:$HB/lib/pkgconfig:$HB/share/pkgconfig" \
  meson setup "$NAT" "$MESA" -Dbuildtype=release -Dvulkan-drivers= -Dgallium-drivers= -Dplatforms= -Dopengl=false \
    -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=enabled -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
    -Dprecomp-compiler=auto -Dspirv-tools=enabled -Dzstd=disabled -Dxmlconfig=disabled -Dvalgrind=disabled \
    -Dlibunwind=disabled -Dbuild-tests=false >> "$L" 2>&1 || { tail -40 "$L"; echo "NATIVE CONFIGURE FAILED"; exit 1; }
fi
PATH="$LLVMP:$PATH" ninja -C "$NAT" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 >> "$L" 2>&1 || { tail -40 "$L"; echo "NATIVE TOOLS FAILED"; exit 1; }
cp -f "$NAT/src/compiler/clc/mesa_clc" "$NAT/src/compiler/spirv/vtn_bindgen2" "$TOOLS/"
"$TOOLS/mesa_clc" --help >/dev/null 2>&1 || true
log "    mesa_clc + vtn_bindgen2 ($(lipo -archs "$TOOLS/mesa_clc"))"

log ">>> 2/2 Mesa ANV for x86_64 (this takes a while)"
CROSS=$SRC/build/x86_64-darwin.ini; EMPTY=$SRC/build/no-pkgconfig; mkdir -p "$EMPTY"
SDK=$(xcrun --show-sdk-path)
cat > "$CROSS" <<INI
[binaries]
c = ['clang', '-arch', 'x86_64', '-isysroot', '$SDK']
cpp = ['clang++', '-arch', 'x86_64', '-isysroot', '$SDK']
objc = ['clang', '-arch', 'x86_64', '-isysroot', '$SDK']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[properties]
needs_exe_wrapper = false
pkg_config_libdir = ['$EMPTY']
[built-in options]
c_args = ['-mmacosx-version-min=15.0']
cpp_args = ['-mmacosx-version-min=15.0']
c_link_args = ['-mmacosx-version-min=15.0']
cpp_link_args = ['-mmacosx-version-min=15.0']
[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
INI
XB=$SRC/build/mesa-anv-x86
if [ ! -f "$XB/build.ninja" ]; then
  PATH="$TOOLS:$HB/opt/bison/bin:$HB/opt/flex/bin:/usr/bin:$PATH" meson setup "$XB" "$MESA" --cross-file "$CROSS" -Dbuildtype=release \
    -Dvulkan-drivers=intel -Dgallium-drivers= -Dplatforms= -Dopengl=false -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dintel-elk=false -Dintel-rt=disabled -Ddisplay-info=disabled -Dzlib=enabled -Dzstd=disabled -Dxmlconfig=disabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dbuild-tests=false -Dllvm=disabled -Dspirv-tools=disabled \
    -Dmesa-clc=system -Dprecomp-compiler=auto >> "$L" 2>&1 || { tail -50 "$L"; echo "X86 CONFIGURE FAILED (log: $L)"; exit 1; }
fi
PATH="$TOOLS:$HB/opt/bison/bin:$HB/opt/flex/bin:/usr/bin:$PATH" ninja -C "$XB" src/intel/vulkan/libvulkan_intel.dylib >> "$L" 2>&1 || { grep -E 'error:|FAILED' "$L" | head -30; echo "ANV BUILD FAILED (log: $L)"; exit 1; }
log "    ninja done, packaging"
OUT=$SRC/out/arcmtl; mkdir -p "$OUT" "$SRC/out/tools"; D=$OUT/libvulkan_intel.dylib
cp -f "$XB/src/intel/vulkan/libvulkan_intel.dylib" "$D"; chmod 755 "$D"
[ "$(lipo -archs "$D")" = x86_64 ] || { log "STOP: $D is $(lipo -archs "$D"), not x86_64"; exit 1; }
EXT=$(otool -L "$D" | tail -n +2 | awk '{print $1}' | grep -v -E '^/usr/lib/|^/System/|libvulkan_intel\.dylib$' || true)   # otool -L lists the library's own id first
[ -z "$EXT" ] || { log "STOP: non-system dependencies: $EXT"; exit 1; }
strip -S "$D"; install_name_tool -id /Library/GPUBundles/arcmtl/libvulkan_intel.dylib "$D"; codesign -f -s - "$D" >> "$L" 2>&1
SYMS=$(nm -gU "$D" | awk '{print $3}')   # no early-exit grep in a pipe: pipefail would see nm's SIGPIPE
grep -Eq '^(_vk_icdGetInstanceProcAddr|_vkGetInstanceProcAddr)$' <<<"$SYMS" || { log "STOP: no Vulkan ICD entry point"; exit 1; }
cp -f "$SRC/mesa-anv/intel_icd.json" "$OUT/"
xcrun clang -arch x86_64 -O2 -Wall -I"$TP/Vulkan-Headers/include" "$SRC/tools/vk_offscreen_test.c" -o "$SRC/out/tools/vk_offscreen_test" >> "$L" 2>&1 || { tail -20 "$L"; log "TEST TOOL FAILED"; exit 1; }
codesign -f -s - "$SRC/out/tools/vk_offscreen_test" >> "$L" 2>&1
log "    libvulkan_intel.dylib $(stat -f %z "$D") B (x86_64)"
U=/Volumes/1401/xegfx-e16/arc
if [ -d /Volumes/1401/xegfx-e16 ]; then
  mkdir -p "$U/arcmtl"; cp -f "$OUT/"* "$U/arcmtl/"; cp -f "$SRC/out/tools/vk_offscreen_test" "$HERE/arc-test2.sh" "$U/"
  dot_clean /Volumes/1401/xegfx-e16 2>/dev/null || true; log "copied to the USB stick (xegfx-e16/arc)"
else log "USB stick not mounted: files are in $SRC/out"; fi
log DONE
