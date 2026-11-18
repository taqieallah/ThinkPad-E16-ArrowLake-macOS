#!/bin/bash
# On the laptop, booted WITH the driver and logged in (desktop slow):
#   sudo bash /Volumes/1401/xegfx-e16/MeowARL/k23-ws-sample.sh
# k23-perf showed WindowServer at ~108 % CPU, Terminal at ~100 %, frames reaching the panel at ~30/s by CPU copy, and
# CoreAnimation "timed out fence" errors. This samples where WindowServer and the busiest app spend their time (GPU
# fence waits? software rendering? the Metal plug-in compiling?) and keeps the last 15 minutes of the driver's and
# WindowServer's messages. Reads only. Takes about 30 s.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Volumes/1401/xegfx-e16/logs; mkdir -p "$B" 2>/dev/null || B=/Users/Shared
D=$B/ws-$(date +%m%d-%H%M%S); mkdir -p "$D"
top -l 2 -s 3 -o cpu -n 12 -stats pid,command,cpu,threads,state > "$D/top.txt" 2>&1
echo "1/3 sampling WindowServer (8 s)"
sample WindowServer 8 -file "$D/sample-WindowServer.txt" >/dev/null 2>&1
APP=$(sed -n '/^PID/,$p' "$D/top.txt" | tail -12 | awk '$2!="WindowServer" && $2!="top" && $2!="kernel_task" && $2!="sample" {print $1; exit}')
if [ -n "$APP" ]; then echo "2/3 sampling the busiest app, pid $APP (5 s)"; sample "$APP" 5 -file "$D/sample-app-$APP.txt" >/dev/null 2>&1; fi
echo "3/3 messages"
for f in /Users/Shared/nmx-flight.log /Users/Shared/nmx-accel.log; do [ -f "$f" ] && tail -c 2000000 "$f" > "$D/$(basename "$f")"; done
log show --last 15m --predicate 'sender BEGINSWITH "MeowXE3" OR eventMessage CONTAINS "[drm]" OR eventMessage CONTAINS "xe 0000" OR eventMessage CONTAINS "GuC" OR (process == "WindowServer" AND messageType >= 16) OR eventMessage CONTAINS "fence" OR eventMessage CONTAINS "MTL"' --style compact > "$D/log.txt" 2>&1
sysctl -a 2>/dev/null | grep -E "^debug\.(nvaccel|nmx|xe)" > "$D/counters.txt"
echo "fence timeouts in 15 min: $(grep -c 'timed out fence' "$D/log.txt")"
awk '/Sort by top of stack/{f=1;next} f&&NF{print; if(++n==8) exit}' "$D/sample-WindowServer.txt"
echo "saved in $D"
