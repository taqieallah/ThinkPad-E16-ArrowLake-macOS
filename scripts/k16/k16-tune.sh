#!/bin/bash
# On the laptop, right after xe-up-k12 (until xe-up does it itself):   sudo bash /Volumes/1401/xegfx-e16/k16/k16-tune.sh
# The settings measured best on 2026-11-12: zero-copy flip, WindowServer does not wait for its composites (the kernel
# does, K9b), apps do not wait for every command buffer (xe-live 64).
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
sysctl -w debug.nvaccel_xe_flip=1 debug.nvaccel_surface_gpu_on=1 >/dev/null
echo 64 > /Library/GPUBundles/nvmtl/xe-live
sysctl debug.nvaccel_xe_flip debug.nvaccel_surface_gpu_on; echo "xe-live $(cat /Library/GPUBundles/nvmtl/xe-live)"
sysctl -n debug.legioncpu.status 2>/dev/null | cut -c1-80
