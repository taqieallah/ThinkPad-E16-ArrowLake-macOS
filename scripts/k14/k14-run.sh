#!/bin/bash
# On the laptop, after xe-up (the GPU must be up):   bash /Volumes/1401/xegfx-e16/k14/k14-run.sh
# Runs the Xiaomi-pad Metal stack's self-test on our ANV: a compute kernel, a render pass, a zero-copy import, then the
# translation of QuartzCore's own shaders (what WindowServer draws the desktop with). Changes nothing on the system.
HERE=$(cd "$(dirname "$0")" && pwd); GB=/Library/GPUBundles/nvmtl; OUT=$HERE/k14-result.txt
[ -f "$GB/libvulkan.dylib" ] && [ -f "$GB/intel_icd.json" ] || { echo "STOP: no Vulkan loader / intel_icd.json in $GB"; exit 1; }
QC=$(find /System/Library/Frameworks/QuartzCore.framework -name '*.metallib' -size +100k 2>/dev/null | head -1)
T=/tmp/xe-m2v-probe; cp "$HERE/xe-m2v-probe" "$T"; chmod +x "$T"
{ echo "== $(date)  macOS $(sw_vers -productVersion)"; echo "QuartzCore metallib: ${QC:-none}"
  VK_ICD_FILENAMES=$GB/intel_icd.json VK_DRIVER_FILES=$GB/intel_icd.json METAL2VULKAN_SHADER_CACHE_OPTIONAL=1 \
    "$T" "$GB/libvulkan.dylib" "$QC" 2>&1 | grep -v "^pair .*: Ok" | tail -60; } | tee "$OUT"
echo; echo "(saved to $OUT)"
