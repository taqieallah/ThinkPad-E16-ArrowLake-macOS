#!/bin/bash
# On the laptop: Intel BE201 Wi-Fi (AirportBZ by change-48, Tahoe build - EXPERIMENTAL, never run on Tahoe before).
#   sudo bash /Volumes/1401/xegfx-e16/wifi-apply.sh          undo: sudo bash /Volumes/1401/xegfx-e16/wifi-apply.sh --undo
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); KX=$HERE/efi-kexts
OC=""; for c in /Volumes/1401/EFI/OC /Volumes/EFI/EFI/OC; do [ -f "$c/config.plist" ] && { OC=$c; break; }; done
if [ -z "$OC" ]; then for p in $(diskutil list | awk '/EFI/ {print $NF}'); do diskutil mount $p >/dev/null 2>&1; done
  for c in /Volumes/*/EFI/OC; do [ -f "$c/config.plist" ] && grep -q AMFIPass "$c/config.plist" && { OC=$c; break; }; done; fi
[ -n "$OC" ] || { echo "STOP: OpenCore config.plist not found"; exit 1; }
C=$OC/config.plist; P=/usr/bin/plutil; echo "OpenCore: $OC"
idx() { local i=0 b; while b=$($P -extract Kernel.Add.$i.BundlePath raw -o - "$C" 2>/dev/null); do [ "$b" = "$1" ] && { echo $i; return 0; }; i=$((i+1)); done; return 1; }
if [ "${1:-}" = --undo ]; then i=$(idx AirportItlwm.kext) && $P -replace Kernel.Add.$i.Enabled -bool NO "$C" && echo "AirportItlwm disabled - restart"; exit 0; fi
[ -f "$KX/AirportItlwm.kext/Contents/MacOS/AirportItlwm" ] || { echo "STOP: efi-kexts/AirportItlwm.kext missing"; exit 1; }
B=$C.before-wifi-$(date +%m%d%H%M); cp "$C" "$B"; echo "backup: $B"
rm -rf "$OC/Kexts/AirportItlwm.kext" "$OC/Kexts/itlwm.kext.off"; cp -R "$KX/AirportItlwm.kext" "$OC/Kexts/"
for k in itlwm.kext AirportItlwm.kext; do i=$(idx $k) && $P -remove Kernel.Add.$i "$C"; done
$P -insert Kernel.Add -json '{"Arch":"x86_64","BundlePath":"AirportItlwm.kext","Comment":"AirportBZ BE201 Tahoe (E16 build)","Enabled":true,"ExecutablePath":"Contents/MacOS/AirportItlwm","MaxKernel":"25.99.99","MinKernel":"25.0.0","PlistPath":"Contents/Info.plist"}' -append "$C" 2>/dev/null \
 || { n=0; while $P -extract Kernel.Add.$n.BundlePath raw -o - "$C" >/dev/null 2>&1; do n=$((n+1)); done
      $P -insert Kernel.Add.$n -json '{"Arch":"x86_64","BundlePath":"AirportItlwm.kext","Comment":"AirportBZ BE201 Tahoe (E16 build)","Enabled":true,"ExecutablePath":"Contents/MacOS/AirportItlwm","MaxKernel":"25.99.99","MinKernel":"25.0.0","PlistPath":"Contents/Info.plist"}' "$C"; }
# an SSDT that hides the CNVi Wi-Fi would stop it
i=0; while a=$($P -extract ACPI.Add.$i.Path raw -o - "$C" 2>/dev/null); do case "$a" in *CNVW*|*Disable_Network*) $P -replace ACPI.Add.$i.Enabled -bool NO "$C"; echo "  off: $a";; esac; i=$((i+1)); done
$P -lint "$C" || { echo "BROKEN plist - restoring"; cp "$B" "$C"; exit 1; }
echo "AirportItlwm at Kernel.Add.$(idx AirportItlwm.kext), enabled $($P -extract Kernel.Add.$(idx AirportItlwm.kext).Enabled raw -o - "$C")"
sync; echo "DONE - restart. Wi-Fi: System Settings > Wi-Fi (WPA2 networks; WPA3-only networks cannot be joined)"
