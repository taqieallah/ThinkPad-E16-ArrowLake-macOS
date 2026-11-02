#!/bin/bash
# Frame-rate check: while this runs (15 s), keep scrolling in Safari / dragging a window.
#   sudo bash /Volumes/1401/xegfx-e16/fps-check.sh          (you scroll)
#   sudo bash /Volumes/1401/xegfx-e16/fps-check.sh bench    (fixed animation, comparable between runs)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D=/Volumes/1401/xegfx-e16/logs/fps-$(date +%H%M%S); mkdir -p "$D"
k() { sysctl -n "$1" 2>/dev/null || echo 0; }
C="debug.nvaccel_pipe_perform debug.nvaccel_xe_flips debug.nvaccel_xe_copy_queued debug.nvaccel_xe_copy_done debug.nvaccel_xe_copy_dropped debug.nvaccel_xe_k9_forced debug.nvaccel_surface_gpu_timeouts"
{ echo "flip=$(k debug.nvaccel_xe_flip) flip_hold=$(k debug.nvaccel_xe_flip_hold) surface_gpu_on=$(k debug.nvaccel_surface_gpu_on) k9=$(k debug.nvaccel_xe_k9) idle_ms=$(k debug.nvaccel_xe_idle_ms)"; sw_vers -productVersion; } > "$D/settings.txt"
B=$(dirname "$0")/ca_bench
if [ "${1:-}" = bench ] && [ -x "$B" ]; then echo "bench: an orange block sweeps for 15 s - do not touch anything"; sudo -u "$(stat -f %Su /dev/console)" "$B" & sleep 0.5
else echo "scroll / drag windows now for 15 seconds..."; fi
[ "${1:-}" = bench ] || ( for p in WindowServer com.apple.WebKit.GPU Safari; do pid=$(pgrep -x "$p" | head -1); [ -n "$pid" ] && sample "$pid" 8 -file "$D/sample-$p.txt" >/dev/null 2>&1 & done; wait ) &
prev=""; echo "sec pipe_perform xe_flips copy_queued copy_done copy_dropped k9_forced gpu_timeouts" > "$D/fps.txt"
for s in $(seq 0 15); do
  cur=""; for c in $C; do cur="$cur $(k $c)"; done
  if [ -n "$prev" ]; then
    a=($cur); b=($prev); line=""
    for i in "${!a[@]}"; do line="$line $(( ${a[$i]} - ${b[$i]} ))"; done
    echo "$s$line" | tee -a "$D/fps.txt"
  fi
  prev=$cur; sleep 1
done
wait; top -l 2 -o cpu -n 8 -stats pid,command,cpu | tail -9 > "$D/top.txt"
cat "$D/settings.txt"; sync; echo "per second: pipe_perform = frames WindowServer sent, xe_flips = frames shown. saved in $D"
