#!/bin/bash
# On the ThinkPad E16, booted with "MeowXE3: start once without driver" (or any boot WITHOUT the GPU driver):
#   sudo bash /Volumes/1401/xegfx-e16/cleanup/e16-clean-laptop.sh            # shows what it would take out
#   sudo bash /Volumes/1401/xegfx-e16/cleanup/e16-clean-laptop.sh --apply    # takes it out
# Takes every experiment of the E16 work off macOS: MeowXE3 / NullMoth (kext, Metal plug-in, firmware, caches, NVRAM),
# the k23 diagnostics (bootcap), the old XeGfx stack and its helpers, the Reims / AppleParavirt pieces, LegionCpuPower.
# Nothing is deleted: everything is MOVED to ~/Desktop/e16-removed-<time>/ (delete that folder yourself when happy).
# OpenCore (config.plist on the stick) is a separate step: e16-clean-efi.py, run on the Mac M5.
# Needs no Command Line Tools (no python): bash, mv, find, nvram, kmutil, launchctl only.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
APPLY=0; [ "${1:-}" = --apply ] && APPLY=1
U=${SUDO_USER:-$(stat -f %Su /dev/console)}; H=$(dscl . -read /Users/"$U" NFSHomeDirectory | awk '{print $2}')
T="$H/Desktop/e16-removed-$(date +%m%d-%H%M%S)"
case " $(nvram boot-args 2>/dev/null | cut -f2-) " in
  *" nmxintel=1 "*) case " $(nvram boot-args | cut -f2-) " in *" -nvoff "*) ;; *)
    echo "STOP: the GPU driver is running (nmxintel=1 without -nvoff). Boot 'MeowXE3: start once without driver' first."; exit 1;; esac;;
esac
n=0
take() {  # take <path>: move it into $T, keeping its full path under there
  local p="$1"; [ -e "$p" ] || [ -L "$p" ] || return 0
  n=$((n+1)); echo "  $p"
  [ $APPLY = 1 ] || return 0
  mkdir -p "$T$(dirname "$p")" && mv "$p" "$T$p" || echo "    !! could not move $p"
}
[ $APPLY = 1 ] && echo "moving to $T" || echo "DRY RUN (nothing changes; add --apply)"

echo "== launchd jobs"
for d in /Library/LaunchDaemons /Library/LaunchAgents "$H/Library/LaunchAgents"; do
  for f in "$d"/*; do [ -f "$f" ] || continue
    case "$(basename "$f")" in *meowarl*|*meowxe3*|*MeowXE3*|*nullmoth*|*NullMoth*|*nmx*|*xegfx*|*XeGfx*|*e16*|*apv*|*reims*|*legion*)
      [ $APPLY = 1 ] && launchctl bootout system "$f" 2>/dev/null; take "$f";; esac; done; done

echo "== kexts in /Library/Extensions"
for k in /Library/Extensions/*.kext; do [ -e "$k" ] || continue
  case "$(basename "$k")" in MeowXE3*|NMX*|NullMoth*|NVRM*|XeGfx*|Xg*|NMIntelFB*|ReimsPCIProbe*|Apv*|AppleParavirt*|LegionCpuPower*|E16*|ArcMTL*)
    take "$k";; esac; done

echo "== Metal / OpenGL plug-ins, firmware, support files"
for p in /Library/GPUBundles/NVMTLDriver.bundle /Library/GPUBundles/NVKZinkGLDriver.bundle /Library/GPUBundles/nvmtl \
         /Library/GPUBundles/nvmtl-allow.txt /Library/GPUBundles/nvmtl-allow.txt.bak /Library/GPUBundles/nvrm610.conf \
         /Library/GPUBundles/XeMTLDriver.bundle /Library/GPUBundles/ArcMTLDriver.bundle \
         /Library/NullMoth "/Library/Application Support/MeowARL" "/Library/Application Support/MeowXE3" \
         "/Library/Application Support/XeGfx" "/Library/Application Support/E16" /usr/local/bin/apv-host /usr/local/bin/xe-up.sh; do
  take "$p"; done
[ -d /Library/GPUBundles ] && [ -z "$(ls -A /Library/GPUBundles 2>/dev/null)" ] && echo "  (/Library/GPUBundles is empty now)"

echo "== /Users/Shared leftovers (installer copies, logs, boot captures)"
for p in /Users/Shared/MeowARL-run /Users/Shared/meowarl-boot /Users/Shared/meowxe3-replaced /Users/Shared/ws-prefs-backup \
         /Users/Shared/MeowXE3-install.log /Users/Shared/nmx-flight.log /Users/Shared/nmx-accel.log /Users/Shared/xegfx* /Users/Shared/k2*; do
  for q in $p; do take "$q"; done; done

echo "== NVMTL shader caches (per app)"
while IFS= read -r d; do take "$d"; done < <(find /private/var/folders "$H/Library/Caches" /Library/Caches -type d -name nvmtl -prune 2>/dev/null)

echo "== NVRAM variables the experiments wrote"
for v in $(nvram -p 2>/dev/null | cut -f1 | grep -E '^(nullmoth-|nmx|e16cr-|xegfx|reims|apv)'); do
  n=$((n+1)); echo "  nvram $v"; [ $APPLY = 1 ] && nvram -d "$v"; done
echo "  (boot-args and nullmoth-fbflags come from OpenCore's config.plist: e16-clean-efi.py fixes them there)"

echo "== result: $n item(s)"
if [ $APPLY = 1 ]; then
  chown -R "$U" "$T" 2>/dev/null
  echo "== rebuilding the auxiliary kernel collection without the removed kexts"
  kmutil install --update-all 2>&1 | tail -3 || true
  echo "moved to $T"
  echo "NEXT: on the Mac M5 run e16-clean-efi.py on the stick's config.plist, then restart normally."
else echo "nothing changed; run again with --apply"; fi
