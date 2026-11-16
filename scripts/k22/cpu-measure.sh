#!/bin/bash
# On the laptop:   sudo bash /Volumes/1401/xegfx-e16/k22/cpu-measure.sh        (about 40 s, changes nothing)
# How fast do the 255H's cores really run under macOS's own power management (XCPM, LegionCpuPower off)?
# HybridPM (yusufklncc/intel-gpu-macos-driver) fixes XCPM's HWP unit on hybrid CPUs, but leaves Arrow Lake H (model
# 0xC5) alone because its unit was never measured. The clock a fully busy core reaches here gives that unit:
# XCPM asks for the turbo ratio in 100 MHz steps, the core runs at ratio x its real unit.
# Spec of the Core Ultra 7 255H: P-cores up to 5.1 GHz, E-cores 4.4 GHz, low-power E-cores 2.5 GHz.
# Writes logs/cpu-measure-<time>.txt on the stick. Close other apps first.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
D=/Volumes/1401/xegfx-e16/logs; mkdir -p "$D" 2>/dev/null || D=/tmp; O=$D/cpu-measure-$(date +%m%d-%H%M%S).txt
N=$(sysctl -n hw.logicalcpu); PIDS=""
cleanup() { [ -n "$PIDS" ] && kill $PIDS 2>/dev/null; }
trap cleanup EXIT INT TERM
# powermetrics prints "CPU n duty cycles" then that CPU's "CPU Average frequency ... (x Mhz)"
sample() {  # $1 label
  powermetrics --samplers cpu_power -i 2000 -n 2 2>/dev/null | awk -v L="$1" '
    /^CPU [0-9]+ duty cycles/ { c=$2 }
    /^CPU Average frequency as fraction of nominal/ && c!="" { m=$(NF-1); gsub(/[()]/,"",m); s[c]+=m; k[c]++; c="" }
    /^System Average frequency/ { sys=$0 }
    END { printf "%s: ", L; best=0; for (i in s) { a=s[i]/k[i]; printf "cpu%s=%d ", i, a; if (a>best) {best=a; bi=i} }
          printf "\n%s: fastest cpu%s at %d MHz | %s\n", L, bi, best, sys }'
}
{ echo "== $(date)"
  sysctl machdep.cpu.brand_string machdep.cpu.family machdep.cpu.model machdep.cpu.stepping machdep.cpu.core_count machdep.cpu.thread_count hw.logicalcpu 2>/dev/null
  printf 'model hex: 0x%X\n' "$(sysctl -n machdep.cpu.model)"
  echo "boot-args: $(nvram boot-args 2>/dev/null | cut -f2-)"
  echo "kexts: $(kmutil showloaded 2>/dev/null | grep -oE 'LegionCpuPower|HybridPM|CpuTopologyRebuild|CPUFriend|CpuTscSync' | sort -u | tr '\n' ' ')"
  sysctl -a 2>/dev/null | grep -iE "^machdep\.xcpm\.(hwp|mode|cpu|perf|epp|turbo)" | head -30
} > "$O"
echo "1/3 idle (4 s)"; sample idle >> "$O"
echo "2/3 one busy thread (8 s)"; yes > /dev/null & PIDS="$!"; sleep 3; sample "1-thread" >> "$O"; cleanup; PIDS=""; sleep 2
echo "3/3 all $N threads busy (8 s)"; for i in $(seq 1 $N); do yes > /dev/null & PIDS="$PIDS $!"; done; sleep 3; sample "all-threads" >> "$O"
cleanup; PIDS=""; trap - EXIT
cat "$O"; echo; echo "saved $O"
