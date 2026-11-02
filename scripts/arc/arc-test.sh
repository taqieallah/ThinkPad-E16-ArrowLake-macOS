#!/bin/bash
# In ArcXe mode (booted with arcxe=1): run the stage-1 probe and save everything to the USB stick.
#   sudo bash /Volumes/1401/xegfx-e16/arc/arc-test.sh
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D=/Volumes/1401/xegfx-e16/logs/arc-$(date +%H%M%S); mkdir -p "$D"
{ echo "== $(sw_vers -productVersion) $(uname -v)"; sysctl -n kern.bootargs; kmutil showloaded 2>/dev/null | grep -i -E 'arc|xegfx'; } > "$D/env.txt" 2>&1
ioreg -l -w0 -c ArcXeService > "$D/ioreg.txt" 2>&1
log show --last boot --predicate 'eventMessage CONTAINS "ArcXe"' --style compact > "$D/kernel.txt" 2>&1
echo "--- info only ---"; "$HERE/arc_probe" --info-only 2>&1 | tee "$D/probe-info.txt"
echo "--- command test (RCS0 / BCS0) ---"; "$HERE/arc_probe" 2>&1 | tee "$D/probe.txt"
log show --last 3m --predicate 'eventMessage CONTAINS "ArcXe"' --style compact > "$D/kernel-after.txt" 2>&1
sync; echo; echo "saved in $D"
