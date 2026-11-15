#!/bin/bash
# Install the test kext into a (copy of a) test EFI folder and print the
# OpenCore changes. Never touches the working EFI unless you point it at it.
#
#   bash scripts/install-efi.sh /Volumes/EFI          # copy + verify + print
#   bash scripts/install-efi.sh /Volumes/EFI --edit   # also add the Kernel->Add entry
#
# Boot arguments needed in the OpenCore config (NVRAM -> boot-args) or NVRAM:
#   reimspci=12
# The kext does nothing at boot in that mode; it waits for the daemon.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: bash $0 /Volumes/EFI [--edit]" >&2
    exit 2
fi
efi="${1%/}"
edit=0
[[ ${2:-} == "--edit" ]] && edit=1

if [[ ! -d "$efi/OC/Kexts" ]]; then
    echo "Not an OpenCore EFI folder: $efi/OC/Kexts is missing" >&2
    exit 1
fi

bundle="$efi/OC/Kexts/ReimsPCIProbe.kext"
if [[ -e "$bundle" ]]; then
    echo "Replacing existing $bundle"
    rm -rf "$bundle"
fi
cp -R "$here/kext/ReimsPCIProbe.kext" "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
# No developer tools on the ThinkPad: validate with base-system tools only.
binary="$bundle/Contents/MacOS/ReimsPCIProbe"
[ -x "$binary" ] || { echo "STOP: $binary missing or not executable" >&2; exit 1; }
file "$binary" | grep -q x86_64 || { echo "STOP: $binary is not x86_64" >&2; exit 1; }
echo "Copied kext to $bundle (x86_64 verified)"
echo
echo "Add this entry under Kernel -> Add in config.plist (OpenCore):"
cat <<'ENTRY'
  <dict>
      <key>Arch</key><string>x86_64</string>
      <key>BundlePath</key><string>ReimsPCIProbe.kext</string>
      <key>Comment</key><string>Reims AppleParavirtGPU bridge 0.2.0</string>
      <key>Enabled</key><true/>
      <key>ExecutablePath</key><string>Contents/MacOS/ReimsPCIProbe</string>
      <key>MaxKernel</key><string>25.99.99</string>
      <key>MinKernel</key><string>25.0.0</string>
      <key>PlistPath</key><string>Contents/Info.plist</string>
  </dict>
ENTRY
echo
echo "And set the boot argument:"
echo "  NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> boot-args = \"... reimspci=12\""
echo "  (that is the same place the existing XeGfx boot arguments live)"
echo
echo "Validate the config with the ocvalidate that matches your OpenCore version."
echo "Keep the working EFI untouched as the rollback path."

if [[ $edit -eq 1 ]]; then
    plist="$efi/OC/config.plist"
    if [[ ! -f "$plist" ]]; then
        echo "No $plist; skipping --edit" >&2
        exit 0
    fi
    backup="$plist.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$plist" "$backup"
    echo "Backup: $backup"
    if /usr/libexec/PlistBuddy -c "Print :Kernel:Add" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Add :Kernel:Add: dict" "$plist" >/dev/null 2>&1 || true
        idx=$(/usr/libexec/PlistBuddy -c "Print :Kernel:Add" "$plist" | grep -c '^    Dict' || true)
        /usr/libexec/PlistBuddy \
            -c "Add :Kernel:Add:$idx:Arch string x86_64" \
            -c "Add :Kernel:Add:$idx:BundlePath string ReimsPCIProbe.kext" \
            -c "Add :Kernel:Add:$idx:Comment string Reims AppleParavirtGPU bridge 0.2.0" \
            -c "Add :Kernel:Add:$idx:Enabled bool true" \
            -c "Add :Kernel:Add:$idx:ExecutablePath string Contents/MacOS/ReimsPCIProbe" \
            -c "Add :Kernel:Add:$idx:MaxKernel string 25.99.99" \
            -c "Add :Kernel:Add:$idx:MinKernel string 25.0.0" \
            -c "Add :Kernel:Add:$idx:PlistPath string Contents/Info.plist" \
            "$plist"
        plutil -lint "$plist"
        echo "Added the Kernel->Add entry. Review it in the OpenCore config editor,"
        echo "then run the matching ocvalidate before booting."
    else
        echo "Kernel:Add not found in the plist; add the entry manually." >&2
    fi
fi
