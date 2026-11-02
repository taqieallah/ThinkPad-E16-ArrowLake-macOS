#!/bin/bash
# On the laptop: collect what the touchpad / battery / audio / Wi-Fi fixes need.
#   sudo bash /Volumes/1401/xegfx-e16/hw-info.sh      -> /Volumes/1401/xegfx-e16/logs/hw-<time>/
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D=/Volumes/1401/xegfx-e16/logs/hw-$(date +%H%M%S); mkdir -p "$D"; cd "$D"
sw_vers > sw.txt; nvram boot-args > bootargs.txt 2>&1; uname -a >> sw.txt
# PCI devices with vendor/device ids
ioreg -lw0 -r -c IOPCIDevice | grep -E '^\+-o|"vendor-id"|"device-id"|"subsystem-id"|"subsystem-vendor-id"|"class-code"|"IOName"|"acpi-path"|"pcidebug"' > pci.txt
ioreg -w0 -p IODeviceTree -t > devtree.txt
ioreg -w0 -p IOService -t > services.txt
# ACPI tables (raw) for the touchpad / battery / EC
ioreg -a -lw0 -r -c AppleACPIPlatformExpert -d 1 > acpi-tables.plist
# input: I2C / HID / PS2
ioreg -lw0 -r -c IOACPIPlatformDevice | grep -E '^\+-o|"name"|"_HID"|"compatible"|"_CID"|"_UID"' > acpi-devices.txt
ioreg -lw0 -r -n VoodooI2CController 2>/dev/null > voodooi2c.txt; ioreg -lw0 -r -c VoodooI2CDeviceNub 2>/dev/null >> voodooi2c.txt
ioreg -lw0 -r -c ApplePS2Controller 2>/dev/null > ps2.txt
# battery
ioreg -lw0 -r -c AppleSmartBattery > battery.txt 2>&1; pmset -g batt >> battery.txt 2>&1
ioreg -lw0 -r -c ACPI_SMC_PlatformPlugin > smc.txt 2>&1
# audio
ioreg -lw0 -r -c IOHDACodecDevice > audio.txt 2>&1; ioreg -lw0 -r -n HDEF >> audio.txt 2>&1; ioreg -lw0 -r -c AppleHDAController >> audio.txt 2>&1
system_profiler SPAudioDataType > sp-audio.txt 2>&1
# network
system_profiler SPNetworkDataType SPAirPortDataType SPBluetoothDataType SPUSBDataType > sp-net-usb.txt 2>&1
ifconfig > ifconfig.txt 2>&1
# loaded third-party kexts and their errors
kmutil showloaded 2>/dev/null | grep -v com.apple > kexts-loaded.txt
log show --last boot --predicate 'sender CONTAINS "Voodoo" OR sender CONTAINS "Lilu" OR sender CONTAINS "AppleALC" OR sender CONTAINS "SMCBattery" OR sender CONTAINS "itlwm" OR eventMessage CONTAINS "VoodooI2C"' --style compact 2>/dev/null | tail -800 > kext-log.txt
# the OpenCore config and kext list from the EFI partition of this USB stick
E=$(diskutil list 2>/dev/null | awk '/EFI/ {print $NF}' | while read p; do diskutil info $p | grep -q 'Device Location:.*External' && echo $p; done | head -1)
[ -z "$E" ] && E=$(diskutil list external 2>/dev/null | awk '/EFI/ {print $NF}' | head -1)
if [ -n "$E" ]; then M=$(mktemp -d); mount -t msdos /dev/$E "$M" 2>/dev/null || diskutil mount -mountPoint "$M" $E >/dev/null 2>&1
  cp "$M/EFI/OC/config.plist" oc-config.plist 2>/dev/null; ls -R "$M/EFI/OC/Kexts" "$M/EFI/OC/ACPI" > oc-files.txt 2>&1
  diskutil unmount "$M" >/dev/null 2>&1; fi
sync; echo "DONE -> $D"; ls "$D"
