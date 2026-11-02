#!/bin/bash
# Switch the next boot between our XeGfx stack (off, default) and the ArcXe test (on): adds/removes arcxe=1 in
# the OpenCore boot-args on the USB stick. In ArcXe mode do NOT run xe-up.sh (it refuses anyway).
#   sudo bash /Volumes/1401/xegfx-e16/arc/arc-mode.sh on|desktop|off|status
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
C=/Volumes/1401/EFI/OC/config.plist; P=/usr/libexec/PlistBuddy
K=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
[ -f "$C" ] || { echo "no $C (is the USB stick mounted?)"; exit 1; }
cur=$($P -c "Print $K" "$C") || { echo "no boot-args in $C"; exit 1; }
base=$(printf '%s' "$cur" | tr ' ' '\n' | grep -v -E '^(arcxe|arcfb|arcaccel)=|^-xeintelfboff$' | tr '\n' ' ' | sed 's/ *$//')
case "${1:-status}" in
  on)  cp -p "$C" "$C.before-arc"; $P -c "Set $K $base arcxe=1" "$C"; echo "next boot: ArcXe test  ($($P -c "Print $K" "$C"))";;
  desktop) cp -p "$C" "$C.before-arc"; $P -c "Set $K $base arcxe=1 arcfb=1 arcaccel=1 -xeintelfboff" "$C"; echo "next boot: ArcMTL desktop  ($($P -c "Print $K" "$C"))";;
  off) $P -c "Set $K $base" "$C"; echo "next boot: normal XeGfx  ($($P -c "Print $K" "$C"))";;
  *)   echo "boot-args: $cur"; ioreg -c ArcXeService >/dev/null 2>&1 && ioreg -c ArcXeService | grep -q ArcXeService && echo "ArcXe is attached now" || echo "ArcXe not attached now";;
esac
sync
