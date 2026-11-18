#!/bin/bash
# meowarl-bootcap.sh: run by launchd at every boot (com.e16.meowarl.bootcap). When MeowXE3 is on (nmxintel=1, no
# -nvoff) it waits 40 s - WindowServer has started (and maybe crashed) by then - and saves, read-only, what macOS built
# for MeowXE3's framebuffer: the framebuffer, its display and connection in the registry (IOFBConfig = the mode list
# IOGraphicsLib made), the accelerator, and the boot's WindowServer/CoreDisplay/kernel messages.
# Output: /Users/Shared/meowarl-boot/<time>/ . Off again with:  sudo bash uninstall-bootcap.sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
BA=$(nvram boot-args 2>/dev/null | cut -f2-)
case " $BA " in *" nmxintel=1 "*) ;; *) exit 0;; esac
case " $BA " in *" -nvoff "*) exit 0;; esac
sleep 40
D=/Users/Shared/meowarl-boot/$(date +%m%d-%H%M%S); mkdir -p "$D"
{ date; echo "boot-args: $BA"; sysctl -n kern.boottime; } > "$D/info.txt"
{ ioreg -lw0 -r -c NMXIntelGPUFB; ioreg -lw0 -r -c NMXGPUFB; } > "$D/ioreg-fb.txt" 2>&1
ioreg -lw0 -r -c IODisplayConnect > "$D/ioreg-display.txt" 2>&1
ioreg -lw0 -r -c IOFramebuffer -d 1 | grep -E "^\+-o|IOFBConfig|IOFBCurrent|IOFBModes|class" > "$D/ioreg-allfb.txt" 2>&1
ioreg -lw0 -r -c NMXAccel -d 1 > "$D/ioreg-accel.txt" 2>&1
ioreg -lw0 -r -c IOPCIDevice -n GFX0 -d 1 > "$D/ioreg-gfx0.txt" 2>&1
log show --last boot --predicate 'process == "WindowServer" OR (process == "kernel" AND (sender == "MeowXE3" OR sender == "MeowXE3Accel" OR sender == "MeowXE3AGDC" OR sender == "IOGraphicsFamily" OR sender == "IOAcceleratorFamily2"))' --style compact > "$D/log.txt" 2>&1
ls /Library/Logs/DiagnosticReports | grep -i windowserver | tail -5 > "$D/ws-crashes.txt"
# One-shot pipe test (armed by:  sudo touch /Users/Shared/meowarl-boot/PIPETEST ). The flag is removed BEFORE the test,
# so if it hangs, a forced power-off and a normal boot is all it takes. Opens NMXAccel's scanout gate
# (sysctl debug.nvaccelfb=3: the display pipe gets the framebuffer), restarts WindowServer, waits 40 s and saves again.
F=/Users/Shared/meowarl-boot/PIPETEST
if [ -f "$F" ]; then rm -f "$F"; sync
  { echo "before: $(sysctl -n debug.nvaccelfb 2>&1)"; sysctl -w debug.nvaccelfb=3 2>&1; echo "after: $(sysctl -n debug.nvaccelfb 2>&1)"; } > "$D/pipetest.txt"
  sleep 3; T0=$(date '+%Y-%m-%d %H:%M:%S'); killall WindowServer 2>>"$D/pipetest.txt"; sleep 40
  echo "WindowServer pid now: $(pgrep -x WindowServer)" >> "$D/pipetest.txt"
  { ioreg -lw0 -r -c NMXGPUFB; ioreg -lw0 -r -c NMXIntelGPUFB; } > "$D/pipetest-ioreg-fb.txt" 2>&1
  log show --start "$T0" --predicate 'process == "WindowServer" OR (process == "kernel" AND (sender == "MeowXE3" OR sender == "MeowXE3Accel" OR sender == "MeowXE3AGDC" OR sender == "IOGraphicsFamily" OR sender == "IOAcceleratorFamily2"))' --style compact > "$D/pipetest-log.txt" 2>&1
  ls /Library/Logs/DiagnosticReports | grep -i windowserver | tail -5 > "$D/pipetest-ws-crashes.txt"
fi
chmod -R a+rX /Users/Shared/meowarl-boot
