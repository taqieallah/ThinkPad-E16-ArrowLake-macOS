#!/bin/bash
# ArcMTL stage 2 on the laptop (booted with arcxe=1): Mesa ANV renders an offscreen frame through ArcXe.
#   sudo bash /Volumes/1401/xegfx-e16/arc/arc-test2.sh
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
ioreg -c ArcXeService | grep -q ArcXeService || { echo "ArcXe is not attached: boot with arc-mode.sh on first"; exit 1; }
D=/Volumes/1401/xegfx-e16/logs/arc2-$(date +%H%M%S); mkdir -p "$D"
export ARC_VULKAN_ICD="$HERE/arcmtl/libvulkan_intel.dylib"
( cd "$D" && time "$HERE/vk_offscreen_test" "$ARC_VULKAN_ICD" ) 2>&1 | tee "$D/vk.txt"
log show --last 3m --predicate 'eventMessage CONTAINS "ArcXe"' --style compact > "$D/kernel.txt" 2>&1
sync; echo; echo "saved in $D"
