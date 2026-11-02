#!/bin/bash
# On the laptop: touchpad (VoodooI2C on Arrow Lake I2C), battery (SMCBatteryManager + ECEnabler), sound (AppleALC +
# SimpleHDA, layout 11). Backs config.plist up first.      sudo bash /Volumes/1401/xegfx-e16/efi-apply.sh
#   undo:  sudo bash /Volumes/1401/xegfx-e16/efi-apply.sh --undo
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); KX=$HERE/efi-kexts
OC=""; for c in /Volumes/1401/EFI/OC /Volumes/EFI/EFI/OC; do [ -f "$c/config.plist" ] && { OC=$c; break; }; done
if [ -z "$OC" ]; then for p in $(diskutil list | awk '/EFI/ {print $NF}'); do diskutil mount $p >/dev/null 2>&1; done
  for c in /Volumes/*/EFI/OC; do [ -f "$c/config.plist" ] && grep -q AMFIPass "$c/config.plist" && { OC=$c; break; }; done; fi
[ -n "$OC" ] || { echo "STOP: OpenCore config.plist not found"; exit 1; }
C=$OC/config.plist; P=/usr/bin/plutil; echo "OpenCore: $OC"
if [ "${1:-}" = --undo ]; then B=$(ls -t "$C".before-hw-* 2>/dev/null | head -1); [ -n "$B" ] && cp "$B" "$C" && echo "restored $B" || echo "no backup"; exit 0; fi
B=$C.before-hw-$(date +%m%d%H%M); cp "$C" "$B"; echo "backup: $B"
for k in ECEnabler AppleALC SimpleHDA SMCBatteryManager; do [ -d "$KX/$k.kext" ] || { echo "STOP: $KX/$k.kext missing"; exit 1; }
  rm -rf "$OC/Kexts/$k.kext"; cp -R "$KX/$k.kext" "$OC/Kexts/"; done
idx() { local i=0 b; while b=$($P -extract Kernel.Add.$i.BundlePath raw -o - "$C" 2>/dev/null); do [ "$b" = "$1" ] && { echo $i; return 0; }; i=$((i+1)); done; return 1; }
entry() { printf '{"Arch":"Any","BundlePath":"%s.kext","Comment":"%s","Enabled":true,"ExecutablePath":"Contents/MacOS/%s","MaxKernel":"","MinKernel":"","PlistPath":"Contents/Info.plist"}' "$1" "$1" "$1"; }
on() { local i; i=$(idx "$1") && { $P -replace Kernel.Add.$i.Enabled -bool YES "$C"; echo "  on:  $1"; } || echo "  (not in config: $1)"; }
off() { local i; i=$(idx "$1") && { $P -replace Kernel.Add.$i.Enabled -bool NO "$C"; echo "  off: $1"; }; }
# kexts: Lilu, ECEnabler, AppleALC, SimpleHDA right after Lilu; SMCBatteryManager after VirtualSMC
L=$(idx Lilu.kext) || { echo "STOP: no Lilu in config"; cp "$B" "$C"; exit 1; }
for k in SimpleHDA AppleALC ECEnabler; do i=$(idx $k.kext) && $P -remove Kernel.Add.$i "$C"; done
$P -insert Kernel.Add.$((L+1)) -json "$(entry SimpleHDA)" "$C"; $P -insert Kernel.Add.$((L+1)) -json "$(entry AppleALC)" "$C"; $P -insert Kernel.Add.$((L+1)) -json "$(entry ECEnabler)" "$C"
echo "  added: ECEnabler, AppleALC, SimpleHDA after Lilu"
if ! idx SMCBatteryManager.kext >/dev/null; then V=$(idx VirtualSMC.kext); $P -insert Kernel.Add.$((V+1)) -json "$(entry SMCBatteryManager)" "$C"; echo "  added: SMCBatteryManager"; else on SMCBatteryManager.kext; fi
for k in VoodooI2C.kext/Contents/PlugIns/VoodooI2CServices.kext VoodooI2C.kext/Contents/PlugIns/VoodooGPIO.kext VoodooI2C.kext/Contents/PlugIns/VoodooInput.kext VoodooI2C.kext VoodooI2CHID.kext; do on $k; done
off VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext
# touchpad: Arrow Lake's I2C controller (8086:7778) is not in VoodooI2C's list -> present it as Tiger Lake's (a0e8)
$P -remove 'DeviceProperties.Add.PciRoot(0x0)/Pci(0x15,0x0)' "$C" 2>/dev/null
$P -insert 'DeviceProperties.Add.PciRoot(0x0)/Pci(0x15,0x0)' -json '{}' "$C"
$P -insert 'DeviceProperties.Add.PciRoot(0x0)/Pci(0x15,0x0).device-id' -data 6KAAAA== "$C"
# sound: layout-id 11 (Realtek ALC257 on ThinkPads); try others with boot-arg alcid=N
$P -remove 'DeviceProperties.Add.PciRoot(0x0)/Pci(0x1F,0x3)' "$C" 2>/dev/null
$P -insert 'DeviceProperties.Add.PciRoot(0x0)/Pci(0x1F,0x3)' -json '{}' "$C"
$P -insert 'DeviceProperties.Add.PciRoot(0x0)/Pci(0x1F,0x3).layout-id' -data CwAAAA== "$C"
echo "  DeviceProperties: I2C0 device-id a0e8, HDAS layout-id 11"
$P -lint "$C" || { echo "BROKEN plist - restoring backup"; cp "$B" "$C"; exit 1; }
echo "kexts in config:"; i=0; while b=$($P -extract Kernel.Add.$i.BundlePath raw -o - "$C" 2>/dev/null); do printf '  %2d %-5s %s\n' $i "$($P -extract Kernel.Add.$i.Enabled raw -o - "$C")" "$b"; i=$((i+1)); done
sync; echo "DONE - restart. If it does not boot: pick the USB again, and in OpenCore boot the old config is at $B"
