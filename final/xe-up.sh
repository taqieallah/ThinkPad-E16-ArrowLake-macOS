#!/bin/bash
# E16 final 1.0 - xe-up: the GPU up after login.   sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh [--fast]
#   default: the safe display path (copy, WindowServer waits). --fast: zero-copy flip + kernel-side wait (smoother, but the
#   E16 showed black bands and freezes with it - only for testing). The previous boot's last kernel lines are kept in
#   logs/prevboot-*.txt each run, so a freeze that needed a restart leaves its trace without typing anything.
# xe-up v9: same steps as v2, but run as a one-shot LaunchDaemon. Restarting WindowServer ends the GUI session and
# with it Terminal and anything started from it (v1/v2 died there, so nothing after the restart was ever logged).
#   sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh     -> starts the daemon and returns; logs in /Volumes/1401/xegfx-e16/logs/
if [ "${1:-}" != "--run" ]; then
  [ "$(id -u)" = 0 ] || { echo "run: sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh"; exit 1; }
  SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0"); P=/Library/LaunchDaemons/org.e16.xeup.plist
  mkdir -p /Library/XeGfx-E16; [ "${1:-}" = --fast ] && echo fast > /Library/XeGfx-E16/xe-up-mode || echo safe > /Library/XeGfx-E16/xe-up-mode
  launchctl bootout system/org.e16.xeup 2>/dev/null
  cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.e16.xeup</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SELF</string><string>--run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>/var/log/xe-up.out</string>
  <key>StandardErrorPath</key><string>/var/log/xe-up.out</string>
</dict></plist>
PL
  chown root:wheel "$P"; chmod 644 "$P"
  launchctl bootstrap system "$P" && echo "xe-up started in the background (org.e16.xeup)."
  echo "In ~30 s the screen goes black while WindowServer restarts. Wait 3 minutes - the first time, shaders are translated (slow). If the login window comes back, log in."
  echo "Logs: /Volumes/1401/xegfx-e16/logs/  (progress: tail -f /var/log/xe-up.log)"
  exit 0
fi
# xe-up v2: core -> stages 1-7 -> accelerator -> AGDC on -> scanout pipe -> transaction hooks -> WindowServer restart.
#   sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh        (logs to /Volumes/1401/xegfx-e16/logs/)
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$(id -u)" = 0 ] || { echo "run: sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh"; exit 1; }
LOGD=/var/log; [ -d /Volumes/1401/xegfx-e16 ] && { LOGD=/Volumes/1401/xegfx-e16/logs; mkdir -p "$LOGD"; }
T=$(date +%H%M%S); LOG=$LOGD/xe-up-$T.log
W() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG" /var/log/xe-up.log; sync; }
S=/usr/sbin/sysctl; K=/usr/bin/kmutil
knob() { for n in "debug.xegfxaccel$1" "debug.nvaccel$1"; do $S -n "$n" >/dev/null 2>&1 && { echo "$n"; return; }; done; echo "debug.nvaccel$1"; }
results() { $S -b debug.xegfx_results 2>/dev/null | od -A n -t d4 | tr -s ' \n' ' ' | sed 's/^ *//;s/ *$//'; }

W "=== xe-up v10 start (macOS $(sw_vers -productVersion)) log $LOG"
pgrep -x WindowServer >/dev/null || { W "no WindowServer: log in first"; exit 1; }
MODE=$(cat /Library/XeGfx-E16/xe-up-mode 2>/dev/null || echo safe); W "mode $MODE  cpu: $($S -n debug.legioncpu.status 2>/dev/null | cut -c1-90)"
# what the kernel and WindowServer said before this boot ended (a freeze that needed the power button leaves it here)
( log show --last 8h --style compact --predicate 'process == "kernel" OR process == "WindowServer"' 2>/dev/null \
    | grep -iE "=== system boot|hang|reset|watchdog|timeout|stall|guc|wedged|panic|k9|legioncpu|gpu fault|engine" | tail -150
  echo "--- panic / hang reports"; ls -lt /Library/Logs/DiagnosticReports/ 2>/dev/null | head -8 ) > "$LOGD/prevboot-$T.txt" 2>&1 &
ioreg -c ArcXeService 2>/dev/null | grep -q ArcXeService && { W "ArcXe owns the GPU (arcxe=1 boot): not loading XeGfx. Back: sudo bash /Volumes/1401/xegfx-e16/arc/arc-mode.sh off, restart"; exit 1; }
# everything the display stack says from here on, for the post-mortem
log stream --style compact --predicate 'process == "WindowServer" OR (process == "kernel" AND (eventMessage CONTAINS "NMX" OR eventMessage CONTAINS "agdc" OR eventMessage CONTAINS "AGDC" OR eventMessage CONTAINS "XeGfx" OR eventMessage CONTAINS "IOFB")) OR eventMessage CONTAINS "NullMoth" OR eventMessage CONTAINS "IOPresentment"' > "$LOGD/stream-$T.log" 2>&1 &
STREAM=$!; sleep 2

# 1) core + stages
$K showloaded 2>/dev/null | grep -q 'org\.watchthelight\.XeGfx (' || $K load -b org.watchthelight.XeGfx 2>&1 | tail -2 | tee -a "$LOG"
for i in $(seq 1 20); do [ -n "$($S -n debug.xegfx_stage 2>/dev/null)" ] && break; sleep 1; done
[ -n "$($S -n debug.xegfx_stage 2>/dev/null)" ] || { W "FAIL: core did not load"; kill $STREAM; exit 2; }
$S -w debug.xegfx_wdog=60 >/dev/null; $S -w debug.xegfx_stage=7 >/dev/null 2>&1; sleep 3
r=$(results); W "results: $r"; set -- $r
[ "$6" = 1 ] && [ "$7" = 1 ] && [ "$8" = 1 ] || { W "FAIL: stages 5-7 not all 1"; kill $STREAM; exit 3; }

# 2) accelerator
$K showloaded 2>/dev/null | grep -q 'org\.watchthelight\.XeGfxAccel (' || $K load -b org.watchthelight.XeGfxAccel >/dev/null 2>&1
for i in $(seq 1 15); do ioreg -c NMXAccel -l 2>/dev/null | grep -q MetalPluginName && break; sleep 1; done
OK=$(knob _iop_ok); FB=$(knob fb); IOP=$(knob _iop)
[ -n "$($S -n $OK 2>/dev/null)" ] || { W "FAIL: accelerator not running"; kill $STREAM; exit 4; }
W "accelerator up: $(ioreg -c NMXAccel -l 2>/dev/null | grep -E 'MetalPluginName' | head -1 | sed 's/^[ |]*//')"; sleep 3

# 3) AGDC: IOPresentment pairs the framebuffer with a display pipe only through it (was missing in v1)
for i in $(seq 1 10); do $S -w debug.xegfx_agdc=1 >/dev/null 2>&1; sleep 1; [ "$($S -n debug.xegfx_agdc 2>/dev/null)" = 1 ] && break; done
W "agdc=$($S -n debug.xegfx_agdc 2>/dev/null)  fbmap: $($S -n debug.xegfx_agdc_fbmap 2>/dev/null)"
[ "$($S -n debug.xegfx_agdc 2>/dev/null)" = 1 ] || { W "FAIL: AGDC did not come up - stopping before WindowServer is touched"; kill $STREAM; exit 5; }

# 3b) K5: answer AGDC 0x921 (link config) from XeGfxIntelFB's NVRMTiming (needs XeGfxIntelFB 0.9.3)
W "IntelFB: $($K showloaded 2>/dev/null | grep -o 'XeGfxIntelFB ([^)]*)')  NVRMTiming: $(ioreg -l -w0 -c IOFramebuffer | grep -c NVRMTiming)"
# E16 guard check: without NVRMTiming XeGfxIntelFB is not driving the panel (usually its boot guard tripped after quick
# restarts). Going on would crash WindowServer in a loop, so stop here before WindowServer is touched.
if [ "$(ioreg -l -w0 -c IOFramebuffer | grep -c NVRMTiming)" = 0 ]; then
  W "STOP: XeGfxIntelFB is not driving the panel (boot guard: $(nvram xeintelfb-starts 2>/dev/null | awk '{print $2}'))."
  W "Fix: sudo nvram xeintelfb-starts=%00 ; restart ; wait 2 minutes on the desktop ; run xe-up again."
  kill $STREAM 2>/dev/null; exit 6; fi
for n in debug.xegfx_agdc_k5 debug.nvrmfb_agdc_k5; do $S -w $n=1 >/dev/null 2>&1 && { W "$n=$($S -n $n)"; break; }; done
# E16: with the async copy worker (XeGfxAccel E16) the kernel waits for the composite; XE_SURFGPU=0 for the old way
# v10: zero-copy flip + K9b (WindowServer does not wait; the flip worker waits for surface-ready OR GT idle).
# Safe default: use the copy path and let WindowServer wait for completion.  The E16 showed
# black horizontal bands with zero-copy under real desktop load.  Re-enable each feature only
# for an explicit diagnostic run with XE_FLIP=1 and/or XE_SURFGPU=1.
if $S -n debug.nvaccel_xe_k9 >/dev/null 2>&1; then
  if [ "$MODE" = fast ]; then XE_FLIP=${XE_FLIP:-1}; XE_SURFGPU=${XE_SURFGPU:-1}; fi
  $S -w debug.nvaccel_xe_flip=${XE_FLIP:-0} >/dev/null 2>&1
  $S -w debug.nvaccel_surface_gpu_on=${XE_SURFGPU:-0} >/dev/null 2>&1
else
  $S -w debug.nvaccel_surface_gpu_on=${XE_SURFGPU:-0} >/dev/null 2>&1
fi
W "surface_gpu_on=$($S -n debug.nvaccel_surface_gpu_on 2>/dev/null) xe_flip=$($S -n debug.nvaccel_xe_flip 2>/dev/null)"
# 4) scanout pipe, 5) hooks
$S -w $FB=3 >/dev/null 2>&1; W "$FB=3"; sleep 3
$S -w $IOP=1 >/dev/null 2>&1; W "$IOP=1"; sleep 3

# 6) frames? else restart WindowServer once
present_total() { local copies flips; copies=$($S -n "$OK" 2>/dev/null || echo 0); flips=$($S -n debug.nvaccel_xe_flips 2>/dev/null || echo 0); echo "$(( ${copies:-0} + ${flips:-0} ))"; }
probe() { a=$(present_total); for i in $(seq 1 $1); do sleep 3; b=$(present_total); [ "${b:-0}" -gt "${a:-0}" ] && { W "  successful copy/flip events $a -> $b"; return 0; }; done; return 1; }
if ! probe 7; then
  W "no frames yet - restarting WindowServer once"
  launchctl kickstart -k system/com.apple.WindowServer; sleep 5
fi
# watch for 5 minutes, one synced line every 5 s (survives a forced restart)
FAILK=$(knob _iop_fail); EMPK=$(knob _iop_empty); a0=$(present_total); t0=$(date +%s)
for i in $(seq 1 24); do
  sleep 5
  spv=$(find /var/folders -path '*nvmtl*' -type f 2>/dev/null | wc -l | tr -d ' ')
  cpu=$(ps -Ao pid,pcpu,comm | awk '/WindowServer$/{print $1":"$2"%"}' | tr '\n' ' ')
  W "  t+$(( $(date +%s)-t0 ))s  iop_ok=$($S -n $OK) fail=$($S -n $FAILK 2>/dev/null) empty=$($S -n $EMPK 2>/dev/null)  WS=$cpu  pipe i/v/c/p=$($S -n debug.nvaccel_pipe_init 2>/dev/null)/$($S -n debug.nvaccel_pipe_validate 2>/dev/null)/$($S -n debug.nvaccel_pipe_complete 2>/dev/null)/$($S -n debug.nvaccel_pipe_perform 2>/dev/null) scopies=$($S -n debug.nvaccel_scanout_copies 2>/dev/null) k5link=$($S -n debug.xegfx_agdc_k5_link 2>/dev/null) k5why=$($S -n debug.xegfx_agdc_k5_why 2>/dev/null)  shadercache=$spv"
  b=$(present_total); [ "${b:-0}" -gt "$(( ${a0:-0}+300 ))" ] && { W "OK: successful copy/flip events are increasing (visual correctness not checked)"; break; }
done
# full snapshot while WindowServer is up
D=$LOGD/diag-$T.txt
{ echo "### sysctl"; $S -a 2>/dev/null | grep -E '^debug\.(nvaccel|xegfx|nmx)'
  echo "### ioreg NMXAccel"; ioreg -l -w0 -c NMXAccel
  echo "### ioreg IOFramebuffer"; ioreg -l -w0 -c IOFramebuffer
  echo "### ioreg IODisplayConnect"; ioreg -l -w0 -c IODisplayConnect
  echo "### ioreg AGDC"; ioreg -l -w0 -r -n XeGfxDeviceControl; ioreg -l -w0 -c AppleGraphicsDeviceControl
  echo "### ioreg IGPU tree"; ioreg -w0 -r -n GFX0 -t
  echo "### system_profiler"; system_profiler SPDisplaysDataType
  echo "### boot-args"; nvram boot-args
} > "$D" 2>&1; sync; W "diag snapshot -> $D ($(wc -l < "$D") lines)"
W "$OK=$($S -n $OK) agdc_cmds=$($S -n debug.xegfx_agdc_cmds 2>/dev/null) client_set=$($S -n debug.xegfx_agdc_client_set 2>/dev/null)"
sleep 10; kill $STREAM 2>/dev/null; sync
# apps stop waiting for each command buffer (measured faster 2026-11-12, no glitches seen); 0 puts the wait back
[ -f /Library/GPUBundles/nvmtl/xe-live ] || [ -d /Library/GPUBundles/nvmtl ] && echo "${XE_LIVE:-64}" > /Library/GPUBundles/nvmtl/xe-live
W "xe-live $(cat /Library/GPUBundles/nvmtl/xe-live 2>/dev/null)  gt $($S -n debug.xegfx_gt_freq 2>/dev/null)"
W "=== xe-up final 1.0 end ($MODE)"; rm -f /Library/LaunchDaemons/org.e16.xeup.plist
