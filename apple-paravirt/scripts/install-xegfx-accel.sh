#!/bin/bash
# Install the patched XeGfxAccel.kext (the panel-present API) next to the
# existing XeGfx core / XeGfxIntelFB installation on the E16.
#
#   sudo bash scripts/install-xegfx-accel.sh /Volumes/1401/xegfx-e16/final
#   sudo bash scripts/install-xegfx-accel.sh --undo
#
# The first argument is the existing E16 "final" XeGfx package folder (the one
# with kexts/XeGfx.kext, kexts/XeGfxIntelFB.kext and install.sh). Only
# /Library/Extensions/XeGfxAccel.kext is replaced; the core kext and the
# framebuffer are left exactly as installed. The auxiliary kernel collection is
# rebuilt the same way that package's own install.sh does it, with a backup and
# automatic restore on failure.
#
# This is the *panel* patch. The bridge test (apv-up.sh) runs without it; the
# display path of apv-host only becomes active when it is installed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

EXT=/Library/Extensions
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc
KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
BR=/Library/XeGfx-E16/apv-panel-backups
NEWKEXT="$HERE/xegfx/XeGfxAccel.kext"

restore() { # $1 backup dir
    [ -d "$1/XeGfxAccel.kext" ] && { rm -rf "$EXT/XeGfxAccel.kext"; ditto "$1/XeGfxAccel.kext" "$EXT/XeGfxAccel.kext"; }
    [ -f "$1/AuxiliaryKernelExtensions.kc" ] && cp -p "$1/AuxiliaryKernelExtensions.kc" "$KC"
    echo "restored from $1"
}

if [ "${1:-}" = "--undo" ]; then
    L=$(ls -1d "$BR"/* 2>/dev/null | tail -1)
    [ -n "$L" ] || { echo "no backup in $BR"; exit 1; }
    restore "$L"; mv "$L" "$L.undone"
    echo "restart required"
    exit 0
fi

SRC="${1:-/Volumes/1401/xegfx-e16/final}"
[ -d "$SRC/kexts" ] || { echo "STOP: $SRC/kexts missing (pass the E16 final package path)"; exit 1; }
[ -d "$EXT/XeGfxAccel.kext" ] || { echo "STOP: /Library/Extensions/XeGfxAccel.kext is not installed"; exit 1; }
[ -d "$EXT/XeGfx.kext" ] || { echo "STOP: XeGfx core is not installed"; exit 1; }
[ -d "$NEWKEXT" ] || { echo "STOP: $NEWKEXT missing (package is incomplete)"; exit 1; }
grep -aq "XG_PANEL" "$NEWKEXT/Contents/MacOS/XeGfxAccel" || {
    echo "STOP: the packaged XeGfxAccel has no panel ABI marker; rebuild it first"; exit 1; }

B="$BR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$B"
ditto "$EXT/XeGfxAccel.kext" "$B/XeGfxAccel.kext"
cp -p "$KC" "$B/" 2>/dev/null
echo "backup: $B"

rm -rf "$EXT/XeGfxAccel.kext"
ditto --norsrc --noextattr "$NEWKEXT" "$EXT/XeGfxAccel.kext"
find "$EXT/XeGfxAccel.kext" -name '._*' -delete
chown -R root:wheel "$EXT/XeGfxAccel.kext"; chmod -R 755 "$EXT/XeGfxAccel.kext"
codesign -f -s - "$EXT/XeGfxAccel.kext" >/dev/null 2>&1 && codesign -v "$EXT/XeGfxAccel.kext" || {
    echo "FAILED: signing - restoring"; restore "$B"; exit 1; }

echo "rebuilding the auxiliary kernel collection (about a minute)..."
N="$KC.apvpanel-new"; rm -f "$N"
if ! kmutil create -n aux --volume-root / --allow-missing-kdk -B "$KB" -S "$KS" \
        --repository "$EXT" -A "$N" -z > "$B/kmutil.log" 2>&1; then
    tail -20 "$B/kmutil.log"; echo "FAILED: kmutil - restoring"; restore "$B"; rm -f "$N"; exit 1
fi
INS=$(kmutil inspect -a x86_64 -A "$N" 2>/dev/null)
for id in org.watchthelight.XeGfx org.watchthelight.XeGfxAccel; do
    printf '%s\n' "$INS" | grep -q "^$id[[:space:]]" || {
        echo "FAILED: $id missing from the new collection - restoring"; restore "$B"; rm -f "$N"; exit 1; }
done
mv -f "$N" "$KC"
echo "Patched XeGfxAccel installed. Restart, then run: sudo bash $SRC/xe-up.sh"
echo "Undo: sudo bash $0 --undo    (then restart)"
