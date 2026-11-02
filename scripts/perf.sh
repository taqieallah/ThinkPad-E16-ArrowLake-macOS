#!/bin/bash
# On the laptop, with the desktop up: what is WindowServer spending its CPU on?   sudo bash /Volumes/1401/xegfx-e16/perf.sh
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D=/Volumes/1401/xegfx-e16/logs/perf-$(date +%H%M%S); mkdir -p "$D"
S=/usr/sbin/sysctl; a=$($S -n debug.nvaccel_iop_ok)
top -l 2 -s 5 -o cpu -n 15 -stats pid,command,cpu,time > "$D/top.txt" 2>&1
b=$($S -n debug.nvaccel_iop_ok); echo "frames in ~5 s: $((b-a))  (iop_ok $a -> $b)" | tee "$D/fps.txt"
P=$(pgrep -x WindowServer | head -1); echo "WindowServer pid $P"
sample "$P" 10 -file "$D/ws-sample.txt" >/dev/null 2>&1 || echo "sample failed"
for d in $(find /private/var/folders -maxdepth 5 -type d -path '*nvmtl*' 2>/dev/null); do echo "$(du -sh "$d" | cut -f1) $(find "$d" -type f | wc -l) files  $d"; done > "$D/caches.txt"
$S -a 2>/dev/null | grep -E '^debug\.nvaccel_(iop|surface|pipe)' > "$D/sysctl.txt"
sync; echo "DONE -> $D"; cat "$D/caches.txt" | head; grep -A3 "^Processes" "$D/top.txt" | tail -2
