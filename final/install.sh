#!/bin/bash
# E16 final 1.0 - driver installer (laptop).   sudo bash /Volumes/1401/xegfx-e16/final/install.sh      undo: ... install.sh --undo
# Installs, in one kernel-collection rebuild: XeGfx (core), XeGfxAccel (accelerator), XeGfxIntelFB 0.9.5 (panel + hardware
# cursor), and the NVMTLDriver Metal plugin. Everything replaced is backed up first; --undo puts the last backup back.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
BR=/Library/XeGfx-E16/final-backups; KEXTS="XeGfx XeGfxAccel XeGfxIntelFB"
PLUG=$(find /Library/GPUBundles -path '*NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver' -type f | head -1)
[ -n "$PLUG" ] || { echo "STOP: no installed NVMTLDriver bundle under /Library/GPUBundles"; exit 1; }
restore() {  # $1 backup dir
  for k in $KEXTS; do [ -d "$1/$k.kext" ] && { rm -rf "$EXT/$k.kext"; ditto "$1/$k.kext" "$EXT/$k.kext"; }; done
  [ -f "$1/NVMTLDriver" ] && cp -p "$1/NVMTLDriver" "$PLUG"
  [ -f "$1/AuxiliaryKernelExtensions.kc" ] && cp -p "$1/AuxiliaryKernelExtensions.kc" "$KC"
  nvram xeintelfb-starts=%00; }
if [ "${1:-}" = --undo ]; then
  L=$(ls -1d "$BR"/* 2>/dev/null | tail -1); [ -n "$L" ] || { echo "no backup in $BR"; exit 1; }
  restore "$L"; mv "$L" "$L.undone"; echo "restored $L - restart"; exit 0; fi
for k in $KEXTS; do [ -d "$HERE/kexts/$k.kext" ] || { echo "STOP: kexts/$k.kext missing"; exit 1; }; done
[ -f "$HERE/NVMTLDriver" ] || { echo "STOP: NVMTLDriver missing"; exit 1; }
grep -aq xgFlipInit "$HERE/kexts/XeGfx.kext/Contents/MacOS/XeGfx" || { echo "STOP: kexts/XeGfx.kext is not the E16 build"; exit 1; }
grep -aq "E16 zero-copy flip" "$HERE/kexts/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel" || { echo "STOP: kexts/XeGfxAccel.kext is not the E16 build"; exit 1; }
grep -q "0.9.5" "$HERE/kexts/XeGfxIntelFB.kext/Contents/Info.plist" || { echo "STOP: kexts/XeGfxIntelFB.kext is not 0.9.5"; exit 1; }
B=$BR/$(date +%Y%m%d-%H%M%S); mkdir -p "$B"
for k in $KEXTS; do [ -d "$EXT/$k.kext" ] && ditto "$EXT/$k.kext" "$B/$k.kext"; done
cp -p "$PLUG" "$B/NVMTLDriver"; cp -p "$KC" "$B/" 2>/dev/null; echo "backup: $B"
IDS=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 !~ /^com\.apple\./ {print $1}')
for k in $KEXTS; do
  rm -rf "$EXT/$k.kext"; ditto --norsrc --noextattr "$HERE/kexts/$k.kext" "$EXT/$k.kext"
  find "$EXT/$k.kext" -name '._*' -delete; chown -R root:wheel "$EXT/$k.kext"; chmod -R 755 "$EXT/$k.kext"
  codesign -f -s - "$EXT/$k.kext" >/dev/null 2>&1 && codesign -v "$EXT/$k.kext" || { echo "FAILED: signing $k - restoring"; restore "$B"; exit 1; }
done
NEW=$KC.final-new; rm -f "$NEW"; echo "rebuilding the kernel collection (a minute)..."
if ! kmutil create -n aux --volume-root / --allow-missing-kdk -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$B/kmutil.log" 2>&1; then
  tail -15 "$B/kmutil.log"; echo "FAILED: kmutil - restoring"; restore "$B"; exit 1; fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null)
for id in $IDS org.watchthelight.XeGfx org.watchthelight.XeGfxAccel org.watchthelight.XeGfxIntelFB; do
  printf '%s\n' "$INS" | grep -q "^$id[[:space:]]" || { echo "FAILED: $id missing from the new collection - restoring"; rm -f "$NEW"; restore "$B"; exit 1; }; done
cp "$HERE/NVMTLDriver" "$PLUG"; chown root:wheel "$PLUG"; chmod 755 "$PLUG"; codesign -f -s - "$PLUG" >/dev/null 2>&1
mv -f "$NEW" "$KC"; nvram xeintelfb-starts=%00
echo "E16 final 1.0 installed. Restart, wait 2 minutes on the desktop, then: sudo bash $HERE/xe-up.sh"
