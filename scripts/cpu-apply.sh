#!/bin/bash
# On the laptop: WTLLegionCpuPower 0.4.1 - Arrow Lake CPU power limit (MCHBAR) + per-core HWP fix. Fan control OFF
# (Legion-only ACPI methods; this is a ThinkPad).    sudo bash /Volumes/1401/xegfx-e16/cpu-apply.sh     undo: ... --undo
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); KX=$HERE/efi-kexts; C=/Volumes/1401/EFI/OC/config.plist; P=/usr/bin/plutil
[ -f "$C" ] || { echo "STOP: $C not found"; exit 1; }
echo "XCPM mode: $(sysctl -n machdep.xcpm.mode 2>/dev/null) (needs 1)"; echo "CPU: $(sysctl -n machdep.cpu.brand_string) model $(sysctl -n machdep.cpu.model)"
idx() { local i=0 b; while b=$($P -extract Kernel.Add.$i.BundlePath raw -o - "$C" 2>/dev/null); do [ "$b" = "$1" ] && { echo $i; return 0; }; i=$((i+1)); done; return 1; }
BA() { $P -extract 'NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args' raw -o - "$C"; }
setBA() { $P -replace 'NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args' -string "$1" "$C"; }
if [ "${1:-}" = --undo ]; then i=$(idx LegionCpuPower.kext) && $P -replace Kernel.Add.$i.Enabled -bool NO "$C"; setBA "$(BA | sed 's/ -legioncpunofan//g')"; echo "LegionCpuPower off - restart"; exit 0; fi
[ "$(sysctl -n machdep.xcpm.mode 2>/dev/null)" = 1 ] || { echo "STOP: XCPM is not active (machdep.xcpm.mode != 1) - the plugin would do nothing"; exit 1; }
[ -d "$KX/LegionCpuPower.kext" ] || { echo "STOP: efi-kexts/LegionCpuPower.kext missing"; exit 1; }
B=$C.before-cpu-$(date +%m%d%H%M); cp "$C" "$B"; echo "backup: $B"
rm -rf /Volumes/1401/EFI/OC/Kexts/LegionCpuPower.kext; cp -R "$KX/LegionCpuPower.kext" /Volumes/1401/EFI/OC/Kexts/
if i=$(idx LegionCpuPower.kext); then $P -replace Kernel.Add.$i.Enabled -bool YES "$C"; $P -replace Kernel.Add.$i.MinKernel -string 25.0.0 "$C"; $P -replace Kernel.Add.$i.MaxKernel -string 25.99.99 "$C"
else L=$(idx Lilu.kext); $P -insert Kernel.Add.$((L+1)) -json '{"Arch":"x86_64","BundlePath":"LegionCpuPower.kext","Comment":"WTLLegionCpuPower 0.4.1","Enabled":true,"ExecutablePath":"Contents/MacOS/LegionCpuPower","MaxKernel":"25.99.99","MinKernel":"25.0.0","PlistPath":"Contents/Info.plist"}' "$C"; fi
case " $(BA) " in *" -legioncpunofan "*) ;; *) setBA "$(BA) -legioncpunofan";; esac
$P -lint "$C" || { echo "BROKEN plist - restoring"; cp "$B" "$C"; exit 1; }
echo "LegionCpuPower at Kernel.Add.$(idx LegionCpuPower.kext); boot-args: $(BA)"
sync; echo "DONE - restart, then check:  sysctl debug.legioncpu.status"
