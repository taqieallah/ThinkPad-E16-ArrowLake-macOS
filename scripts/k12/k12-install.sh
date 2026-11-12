#!/bin/bash
# On the laptop:   sudo bash /Volumes/1401/xegfx-e16/k12/k12-install.sh        undo: ... k12-install.sh --undo
# Installs the K12 kexts + plugin (through ../full-install.sh, which keeps its own backup) and the K12 libdrm.
HERE=$(cd "$(dirname "$0")" && pwd); UP=$(dirname "$HERE"); [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
B=/Library/XeGfx-E16/k12-libdrm-backup
if [ "${1:-}" = --undo-libdrm ]; then
  [ -f "$B/list" ] || { echo "no libdrm backup"; exit 1; }
  while IFS= read -r p; do cp -p "$B/$(echo "$p" | tr / _)" "$p.k12undo" && mv -f "$p.k12undo" "$p" && echo "restored $p"; done < "$B/list"; exit 0; fi
if [ "${1:-}" = --undo ]; then
  [ -d "$B" ] || { echo "no libdrm backup"; exit 1; }
  while IFS= read -r p; do cp -p "$B/$(echo "$p" | tr / _)" "$p.k12undo" && mv -f "$p.k12undo" "$p"; done < "$B/list"
  bash "$UP/full-install.sh" --undo; exit $?; fi
[ -f "$HERE/libdrm.2.dylib" ] || { echo "STOP: k12/libdrm.2.dylib missing"; exit 1; }
[ "${1:-}" = --libdrm-only ] || grep -aq xgDrmOpen "$UP/kexts/XeGfx.kext/Contents/MacOS/XeGfx" || { echo "STOP: $UP/kexts/XeGfx.kext is not the K12 build"; exit 1; }
[ "${1:-}" = --libdrm-only ] || grep -aq "XGDR open" "$UP/kexts/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel" || { echo "STOP: $UP/kexts/XeGfxAccel.kext is not the K12 build"; exit 1; }
LIBS=$(find /Library/GPUBundles -name libdrm.2.dylib -type f 2>/dev/null)
[ -n "$LIBS" ] || { echo "STOP: no libdrm.2.dylib under /Library/GPUBundles"; exit 1; }
mkdir -p "$B"; : > "$B/list.new"
for p in $LIBS; do
  [ -f "$B/$(echo "$p" | tr / _)" ] || cp -p "$p" "$B/$(echo "$p" | tr / _)"
  echo "$p" >> "$B/list.new"
  # beside, then renamed into place: a cp over a mapped dylib kills the next process that loads it
  ID=$(otool -D "$p" | tail -1)
  cp "$HERE/libdrm.2.dylib" "$p.k12new"; install_name_tool -id "$ID" "$p.k12new" 2>/dev/null
  codesign -f -s - "$p.k12new" >/dev/null 2>&1; chown root:wheel "$p.k12new"; chmod 755 "$p.k12new"
  mv -f "$p.k12new" "$p"; echo "libdrm -> $p"
done
mv -f "$B/list.new" "$B/list"
[ "${1:-}" = --libdrm-only ] && { echo "libdrm replaced (kexts untouched) - log out and in, or restart"; exit 0; }
bash "$UP/full-install.sh" || { echo "STOP: full-install.sh failed"; exit 1; }
echo "K12 installed - restart, run xe-up as usual, then: bash $HERE/k12-test.sh"
