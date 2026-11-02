#!/bin/bash
# On the laptop: why is Wi-Fi not up?   sudo bash /Volumes/1401/xegfx-e16/wifi-diag.sh   -> logs/wifi-<time>/
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D=/Volumes/1401/xegfx-e16/logs/wifi-$(date +%H%M%S); mkdir -p "$D"; cd "$D"
kmutil showloaded 2>/dev/null | grep -i -E "itlwm|airport|80211|skywalk|corecapture" > loaded.txt
nvram boot-args > bootargs.txt 2>&1
ioreg -lw0 -r -n CNVW@14,3 > ioreg-cnvw.txt 2>&1
ioreg -lw0 -r -c AirportItlwm > ioreg-itlwm.txt 2>&1
ioreg -lw0 -r -c IO80211Controller >> ioreg-itlwm.txt 2>&1
ioreg -lw0 -r -c IO80211InfraInterface >> ioreg-itlwm.txt 2>&1
ifconfig -a > ifconfig.txt 2>&1
networksetup -listallhardwareports > ports.txt 2>&1
system_profiler SPAirPortDataType > sp-wifi.txt 2>&1
log show --last boot --style compact --predicate 'sender CONTAINS[c] "itlwm" OR sender CONTAINS[c] "Airport" OR eventMessage CONTAINS[c] "itlwm" OR eventMessage CONTAINS[c] "iwx" OR eventMessage CONTAINS[c] "AirportItlwm" OR eventMessage CONTAINS "com.zxystd"' 2>/dev/null | tail -1500 > itlwm-log.txt
log show --last boot --style compact --predicate 'process == "kernelmanagerd" OR process == "kernel" AND eventMessage CONTAINS[c] "kext"' 2>/dev/null | grep -i -E "itlwm|airport|zxystd|fail|reject|error" | tail -200 > kext-log.txt
E=/Volumes/1401/EFI/OC/config.plist; [ -f $E ] && plutil -extract Kernel.Add json -o - $E 2>/dev/null | tr ',' '\n' | grep -A3 -i airport > oc-entry.txt
ls -la /Volumes/1401/EFI/OC/Kexts/AirportItlwm.kext/Contents/MacOS/ >> oc-entry.txt 2>&1
sync; echo "DONE -> $D"; echo "--- loaded:"; cat loaded.txt; echo "--- log lines: $(wc -l < itlwm-log.txt)"; tail -5 itlwm-log.txt
