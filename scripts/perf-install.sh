#!/bin/bash
# On the laptop: install the faster plugin + translator built by build-perf.sh.   sudo bash /Volumes/1401/xegfx-e16/perf-install.sh
#   undo: sudo bash /Volumes/1401/xegfx-e16/perf-install.sh --undo
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(find /Library/GPUBundles -path '*NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver' -type f | head -1)
X=$(find /Library/GPUBundles -name libnvmtl_translate.dylib -type f | head -1)
[ -n "$T" ] && [ -n "$X" ] || { echo "STOP: installed plugin/translator not found"; exit 1; }
if [ "${1:-}" = --undo ]; then for f in "$T" "$X"; do [ -f "$f.before-perf" ] && cp "$f.before-perf" "$f" && codesign -f -s - "$f" 2>/dev/null && echo "restored $f"; done; exit 0; fi
for f in NVMTLDriver libnvmtl_translate.dylib; do [ -f "$HERE/$f" ] || { echo "STOP: $f not next to this script"; exit 1; }; done
[ -f "$T.before-perf" ] || cp -p "$T" "$T.before-perf"; [ -f "$X.before-perf" ] || cp -p "$X" "$X.before-perf"
cp "$HERE/NVMTLDriver" "$T"; cp "$HERE/libnvmtl_translate.dylib" "$X"
for f in "$T" "$X"; do chown root:wheel "$f"; chmod 755 "$f"; codesign -f -s - "$f" 2>/dev/null; done
# shaders translated by the old translator are dropped once (a new translator must not read the old one's output)
find /private/var/folders -maxdepth 5 -type d \( -name 'spvcache' -o -name 'nvmtl-*' \) -path '*nvmtl*' 2>/dev/null | while read d; do rm -rf "$d"; done
echo "installed: $T"; echo "installed: $X"; echo "pipeline cache in plugin: $(grep -ac 'pcache: ' "$T")"
echo "now restart, log in, run xe-up.sh. The FIRST session re-translates every shader (slow); from the second it is cached."
