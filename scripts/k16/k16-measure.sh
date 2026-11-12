#!/bin/bash
# On the laptop, after xe-up-k12 + k16-tune:   sudo bash /Volumes/1401/xegfx-e16/k16/k16-measure.sh
# KEEP MOVING A WINDOW / opening Mission Control for the whole 20 s. Writes k16/measure.txt and k16/ws-sample.txt.
# Then on the Mac:  cp /Volumes/1401/xegfx-e16/k16/*.txt ~/Desktop/xe-update/k16/
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); O=$HERE/measure.txt
K="debug.nvaccel_xe_flips debug.nvaccel_xe_flip_miss debug.nvaccel_xe_k9_free debug.nvaccel_xe_k9_mark debug.nvaccel_xe_k9_idle debug.nvaccel_xe_k9_forced debug.nvaccel_xe_k9_max_us debug.nvaccel_iop_ok debug.nvaccel_xe_copy_done debug.nvaccel_surface_gpu_marks debug.nvaccel_surface_gpu_waits debug.nvaccel_surface_gpu_timeouts"
snap() { for k in $K; do printf "%s=%s " "${k#debug.nvaccel_}" "$(sysctl -n $k 2>/dev/null)"; done; echo; }
WS=$(pgrep -x WindowServer)
echo "move a window around NOW (20 s)..."
{ echo "== $(date)"; sysctl debug.nvaccel_xe_flip debug.nvaccel_surface_gpu_on debug.xegfx_gt_freq 2>/dev/null; echo "xe-live $(cat /Library/GPUBundles/nvmtl/xe-live 2>/dev/null)"
  sysctl -n debug.legioncpu.status 2>/dev/null
  echo "before: $(snap)"; } > "$O"
sample "$WS" 10 -file "$HERE/ws-sample.txt" >/dev/null 2>&1 &
top -l 4 -s 3 -stats pid,command,cpu,th -o cpu -n 8 > /tmp/k16-top.txt 2>&1
wait
{ echo "after:  $(snap)"; sysctl debug.xegfx_gt_freq 2>/dev/null; echo "--- top"; grep -A9 "^PID" /tmp/k16-top.txt | tail -10
  echo "--- powermetrics"; powermetrics -n 1 -i 1000 --samplers cpu_power,gpu_power 2>/dev/null | grep -iE "Average frequency|GPU HW active|GPU idle|Package Power" | head -8; } >> "$O"
cat "$O"; echo; echo "saved $O and $HERE/ws-sample.txt - copy both to the Mac (see top of this script)"
