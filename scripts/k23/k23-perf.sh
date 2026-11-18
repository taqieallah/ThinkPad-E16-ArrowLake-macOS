#!/bin/bash
# On the laptop, booted WITH the driver and logged in:
#   sudo bash /Volumes/1401/xegfx-e16/MeowARL/k23-perf.sh
# While it says "MOVE", drag a window around / open and close Launchpad for 15 s.
# Where does the slowness come from? Something eating the CPU (a fresh install indexes Spotlight and Photos), cores
# held at a low clock (macOS power management does not know Arrow Lake: the old install measured a busy core at
# 552 MHz), or the GPU path (frames, flips, copies: NMXAccel's counters before/after). Reads only.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Volumes/1401/xegfx-e16/logs; mkdir -p "$B" 2>/dev/null || B=/Users/Shared
D=$B/perf-$(date +%m%d-%H%M%S); mkdir -p "$D"
cnt() { sysctl -a 2>/dev/null | grep -E "^debug\.(nvaccel|nmx|xe)" ; }
{ sw_vers; uptime; echo "boot-args: $(nvram boot-args | cut -f2-)"; echo "fbflags: $(nvram nullmoth-fbflags | cut -f2-)"
  kmutil showloaded 2>/dev/null | grep -oE "MeowXE3[A-Za-z]*|LegionCpuPower|HybridPM|CPUFriend|CpuTopologyRebuild|CpuTscSync|Lilu|VirtualSMC" | sort -u | tr '\n' ' '; echo
  system_profiler SPDisplaysDataType 2>/dev/null
  ioreg -lw0 -r -c NMXAccel -d 1 | grep -E "VRAM|PerformanceStatistics|MetalPlugin|IOClass" | cut -c1-400
} > "$D/info.txt" 2>&1
echo "1/4 what uses the CPU (6 s)"
top -l 2 -s 5 -o cpu -n 20 -stats pid,command,cpu,mem,state > "$D/top.txt" 2>&1
echo "2/4 core clocks at rest (4 s)"
powermetrics --samplers cpu_power,gpu_power -i 2000 -n 2 > "$D/power-idle.txt" 2>&1
cnt > "$D/counters-before.txt"
echo "3/4 MOVE: drag a window, open/close Launchpad, for 15 s ..."
powermetrics --samplers cpu_power,gpu_power -i 3000 -n 5 > "$D/power-move.txt" 2>&1 &
P=$!; sleep 15; wait $P
cnt > "$D/counters-after.txt"
echo "4/4 the driver's messages of the last 3 minutes"
log show --last 3m --predicate 'sender BEGINSWITH "MeowXE3" OR (process == "WindowServer" AND messageType >= 16)' --style compact > "$D/log.txt" 2>&1
# summary
grep -E "^CPU Average frequency|^System Average frequency|Average frequency|GPU (HW )?active|GPU idle" "$D/power-move.txt" | sort | uniq -c | sort -rn | head -8
echo; sed -n '/^PID/,$p' "$D/top.txt" | tail -21 | head -8
diff "$D/counters-before.txt" "$D/counters-after.txt" | grep "^>" | head -30 > "$D/counters-changed.txt"
echo; echo "counters that moved: $(wc -l < "$D/counters-changed.txt" | tr -d ' ')"
echo "saved in $D"
