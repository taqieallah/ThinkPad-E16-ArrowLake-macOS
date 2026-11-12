#!/bin/bash
# On the laptop, after xe-up:   bash /Volumes/1401/xegfx-e16/k14/k14b-run.sh
# Times the same desktop-like scene (12 shadowed windows moving, plus blurred panels) on today's driver (old) and the Xiaomi-pad
# Metal stack (new), both on our ANV. Lower ms = smoother. Changes nothing on the system.
HERE=$(cd "$(dirname "$0")" && pwd); GB=/Library/GPUBundles/nvmtl; OUT=$HERE/k14b-result.txt
QC=$(find /System/Library/Frameworks/QuartzCore.framework -name '*.metallib' -size +100k 2>/dev/null | head -1)
T=/tmp/xe-m2v-bench; cp "$HERE/xe-m2v-bench" "$T"; chmod +x "$T"; mkdir -p /tmp/xe-m2v-cache
export VK_ICD_FILENAMES=$GB/intel_icd.json VK_DRIVER_FILES=$GB/intel_icd.json
{ echo "== $(date)  macOS $(sw_vers -productVersion)"
  echo "--- old (today's driver)"; "$T" old "$GB/libvulkan.dylib" /tmp/xe-m2v-cache "$QC" 2>&1 | grep -v "PrecisionNote\|degrade-" | tail -25
  echo "--- new (Xiaomi-pad stack)"; "$T" new "$GB/libvulkan.dylib" /tmp/xe-m2v-cache "$QC" 2>&1 | grep -v "PrecisionNote\|degrade-" | tail -40
} | tee "$OUT"
echo; echo "(saved to $OUT)"
