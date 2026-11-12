#!/bin/bash
# On the laptop, after k12-install.sh and a restart:   bash /Volumes/1401/xegfx-e16/k12/k12-test.sh
# 1 normal open   2 the kernel-open path forced   3 inside a sandbox that refuses /dev/dri like Safari/Calculator do
HERE=$(cd "$(dirname "$0")" && pwd); T=$HERE/drmtest; LIB=$(dirname "$(find /Library/GPUBundles -name libdrm.2.dylib | head -1)")
[ -f "$HERE/drmtest" ] && [ -n "$LIB" ] || { echo "STOP: drmtest or the installed libdrm missing"; exit 1; }
T=/tmp/k12-drmtest; cp "$HERE/drmtest" "$T"; chmod +x "$T"
cp "$LIB/libdrm.2.dylib" /tmp/libdrm.2.dylib   # drmtest loads /tmp/libdrm.2.dylib: the installed one, copied
echo "== 1) normal";            "$T"
echo; echo "== 2) XEGFX_KOPEN=1";  XEGFX_KOPEN=1 "$T"
echo; echo "== 3) sandbox without /dev/dri"
sandbox-exec -p '(version 1)(allow default)(deny file-read* file-write* file-ioctl (subpath "/dev/dri"))' "$T"
echo; echo "== kernel log"
log show --last 2m --style compact --predicate 'eventMessage CONTAINS "XGDR open"' 2>/dev/null | tail -5
echo; echo "== Calculator check: open Calculator now, wait 5 s"; open -a Calculator; sleep 5
log show --last 15s --style compact --predicate 'eventMessage CONTAINS "/dev/dri" OR eventMessage CONTAINS "XGDR open"' 2>/dev/null | tail -8
