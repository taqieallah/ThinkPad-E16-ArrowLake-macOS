#!/bin/bash
# On the laptop, after xe-up (best with --fast):   sudo bash /Volumes/1401/xegfx-e16/k22/k22-measure.sh
# Is a clocked-down GPU what makes the animations stutter? Two 20-second rounds of the same thing, A then B:
#   with k22 installed:   A = late-frame floor off (nvaccel_xe_boost_us=0), B = on (3000 us)
#   without k22 (final):  A = SLPC as it is,                                  B = GPU floor fixed at its maximum (RP0)
# DURING EACH ROUND keep minimizing and restoring a window (genie) / opening Mission Control, the same way both times.
# Writes logs/k22-measure-<time>.txt on the stick. Everything it changes is put back at the end.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
D=/Volumes/1401/xegfx-e16/logs; mkdir -p "$D" 2>/dev/null || D=/tmp; O=$D/k22-measure-$(date +%m%d-%H%M%S).txt
S=sysctl; SEC=${SEC:-20}
gt() { $S -n debug.xegfx_gt_freq 2>/dev/null; }
field() { gt | tr ' ' '\n' | sed -n "s/^$1=//p"; }
shown() { echo $(( $($S -n debug.nvaccel_xe_flips 2>/dev/null || echo 0) + $($S -n debug.nvaccel_iop_ok 2>/dev/null || echo 0) )); }
[ -n "$(gt)" ] || { echo "STOP: no debug.xegfx_gt_freq - run xe-up first"; exit 1; }
MIN0=$(field min); RP0=$(field rp0); MAX=$(field max)
if $S -n debug.nvaccel_xe_boost_us >/dev/null 2>&1; then KIND=k22; B0=$($S -n debug.nvaccel_xe_boost_us); else KIND=static; fi
restore() { if [ $KIND = k22 ]; then $S -w debug.nvaccel_xe_boost_us=$B0 >/dev/null; else $S -w debug.xegfx_gt_min_mhz=$MIN0 >/dev/null 2>&1; fi; }
trap 'restore; echo "settings put back"' EXIT INT TERM
round() {  # $1 name
  local f0 l0 b0 n=0 sum=0 atmin=0 a; f0=$(shown); l0=$($S -n debug.nvaccel_xe_late 2>/dev/null || echo 0); b0=$($S -n debug.nvaccel_xe_boosts 2>/dev/null || echo 0)
  for i in $(seq 1 $SEC); do sleep 1; a=$(field act); [ -n "$a" ] || a=0
    if [ "$a" -gt 0 ]; then n=$((n+1)); sum=$((sum+a)); [ "$a" -le "$MIN0" ] && atmin=$((atmin+1)); fi
    printf "\r  %s: %2d/%d s  GPU %4s MHz   " "$1" $i $SEC "$a"; done; echo
  local fr=$(( $(shown) - f0 ))
  printf "%-3s frames/s %5s | GPU busy samples %2d/%d, avg %4s MHz, at the floor %2d | late %s, raises %s\n" "$1" \
    "$(echo "scale=1; $fr/$SEC" | bc)" $n $SEC "$( [ $n -gt 0 ] && echo $((sum/n)) || echo -)" $atmin \
    $(( $($S -n debug.nvaccel_xe_late 2>/dev/null || echo 0) - l0 )) $(( $($S -n debug.nvaccel_xe_boosts 2>/dev/null || echo 0) - b0 )) | tee -a "$O"
}
{ echo "== $(date)  kind=$KIND  $(gt)"
  echo "flip=$($S -n debug.nvaccel_xe_flip 2>/dev/null) gpu_on=$($S -n debug.nvaccel_surface_gpu_on 2>/dev/null) xe-live=$(cat /Library/GPUBundles/nvmtl/xe-live 2>/dev/null)"
  [ $KIND = k22 ] && [ "$($S -n debug.nvaccel_surface_gpu_on 2>/dev/null)" != 1 ] && echo "NOTE: gpu_on=0 (safe mode): the k22 floor only sees late frames after xe-up --fast"
} | tee "$O"
echo; echo "Round A in 5 s: minimize/restore a window again and again for $SEC s"; sleep 5
if [ $KIND = k22 ]; then $S -w debug.nvaccel_xe_boost_us=0 >/dev/null; fi
round A
echo; echo "Round B in 5 s: do exactly the same again"; sleep 5
if [ $KIND = k22 ]; then $S -w debug.nvaccel_xe_boost_us=3000 >/dev/null; else $S -w debug.xegfx_gt_min_mhz=$RP0 >/dev/null || echo "could not set the floor"; fi
round B
restore; trap - EXIT
{ echo "after: $(gt)"; echo "(A/B compare frames/s; B should be higher and smoother. Also: did B FEEL smoother?)"; } | tee -a "$O"
echo "saved $O"
