#!/bin/bash
# On the Mac, with the USB stick in:   bash ~/Desktop/xe-update/k15/cpu-perf.sh          undo:  ... cpu-perf.sh --undo
# K15: let the Core Ultra 7 255H clock up. Turns LegionCpuPower on in the stick's OpenCore config with ONLY its HWP part
# (per-core HWP requests + EPP 0 = performance). Its Legion-specific parts stay off by boot argument: fan (Legion EC),
# power limit (MCHBAR) and scheduler bias - those touched hardware a ThinkPad does not have.
set -euo pipefail
C=/Volumes/1401/EFI/OC/config.plist; B=/Volumes/1401/EFI/OC/config.plist.pre-k15; PB=/usr/libexec/PlistBuddy
[ -f "$C" ] || { echo "STOP: $C not found - is the USB stick in?"; exit 1; }
FLAGS="-legioncpunofan -legioncpunopl -legioncpunosched"
NV=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
if [ "${1:-}" = --undo ]; then [ -f "$B" ] || { echo "no backup $B"; exit 1; }; cp "$B" "$C"; echo "config.plist restored (LegionCpuPower off)"; exit 0; fi
[ -f "$B" ] || cp "$C" "$B"
[ -d /Volumes/1401/EFI/OC/Kexts/LegionCpuPower.kext ] || { echo "STOP: LegionCpuPower.kext is not on the stick"; exit 1; }
i=0; idx=-1
while p=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C" 2>/dev/null); do [ "$p" = LegionCpuPower.kext ] && idx=$i; i=$((i+1)); done
[ $idx -ge 0 ] || { echo "STOP: LegionCpuPower.kext has no Kernel/Add entry"; exit 1; }
$PB -c "Set :Kernel:Add:$idx:Enabled true" "$C"
BA=$($PB -c "Print $NV" "$C")
for f in $FLAGS; do case " $BA " in *" $f "*) ;; *) BA="$BA $f";; esac; done
$PB -c "Set $NV $BA" "$C"
plutil -lint "$C" >/dev/null || { cp "$B" "$C"; echo "STOP: config broke - restored"; exit 1; }
echo "LegionCpuPower ON (entry $idx), boot-args: $BA"
echo "Boot the laptop from the stick. If anything misbehaves: plug the stick into the Mac and run cpu-perf.sh --undo."
echo "After boot:  sysctl debug.legioncpu.status"
