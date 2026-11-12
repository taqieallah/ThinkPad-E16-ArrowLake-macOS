#!/bin/bash
# On the Mac: XeGfx core from source (WTLIntelGfx 0.0.47 + ArrowWhatever 0008 GGTT flip slots + the HONOR fixes as
# source), then XeGfxAccel (zero-copy flip) and NVMTLDriver. Needs the laptop's kernel collection next to this script:
#   core/BootKernelExtensions.kc   (copied from the laptop AFTER its macOS update)
#   bash ~/Desktop/xe-update/core/build-core.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); UP=$(dirname "$HERE"); W=$HOME/src/xe-e16; WTL=$W/wtl; S=$HOME/src/xe-src
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export PATH=$HOME/.venvs/mesa/bin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
L=$HERE/build-core.log; : > "$L"; log() { echo "$*"; echo "$*" >> "$L"; }
KC=$HERE/BootKernelExtensions.kc
[ -f "$KC" ] || { [ -f /Volumes/1401/xegfx-e16/BootKernelExtensions.kc ] && cp /Volumes/1401/xegfx-e16/BootKernelExtensions.kc "$KC" && echo "took the laptop collection from the USB stick"; }
[ -f "$KC" ] || { echo "STOP: copy the laptop's /System/Library/KernelCollections/BootKernelExtensions.kc to $KC first"; exit 1; }
file "$KC" | grep -q "x86_64\|Mach-O" || { echo "STOP: $KC is not a Mach-O kernel collection"; exit 1; }
export KCABI_KC=$KC
grep -q "xgFlipQuery" "$WTL/shim/src/xnu/xg_kext.cpp" || { echo "STOP: 0008 is not applied to $WTL"; exit 1; }
grep -q "HONOR binary patch 0x243e5e" "$WTL/shim/src/xnu/xg_kext.cpp" || { echo "STOP: stage-loop fix missing"; exit 1; }

log ">>> sources in $S"
mkdir -p "$S"
if [ ! -d "$S/freebsd/sys/compat/linuxkpi" ]; then
  rm -rf "$S/freebsd"; git init -q "$S/freebsd"; git -C "$S/freebsd" remote add origin https://github.com/freebsd/freebsd-src.git
  git -C "$S/freebsd" config core.sparseCheckout true; echo "sys/" > "$S/freebsd/.git/info/sparse-checkout"
  git -C "$S/freebsd" fetch -q --depth 1 --filter=blob:none origin d2145e9b96448da34d3cfede24c509af6d830c92
  git -C "$S/freebsd" checkout -q FETCH_HEAD; fi
if [ ! -d "$S/drm-kmod/drivers" ]; then
  rm -rf "$S/drm-kmod"; git init -q "$S/drm-kmod"; git -C "$S/drm-kmod" remote add origin https://github.com/freebsd/drm-kmod.git
  git -C "$S/drm-kmod" fetch -q --depth 1 origin c16de0f9fa84f70b9551f69fde837a7f3a73c0e9; git -C "$S/drm-kmod" checkout -q FETCH_HEAD; fi
[ -d "$HOME/src/kcabi" ] || git clone -q https://github.com/watchthelight-labs/WTLKcAbi.git "$HOME/src/kcabi"
FW=$S/linux-firmware; mkdir -p "$FW"
if [ ! -s "$FW/mtl_guc_70.bin" ]; then
  R=$(find "$W/out" -path '*XeGfx.kext/Contents/Resources' -type d | head -1)
  if [ -n "$R" ] && [ -s "$R/mtl_guc_70.bin" ]; then cp "$R/mtl_guc_70.bin" "$R/LICENSE.i915" "$FW/" 2>/dev/null || cp "$R/mtl_guc_70.bin" "$FW/"
  else curl -fsSL -o "$FW/mtl_guc_70.bin" https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/i915/mtl_guc_70.bin
       curl -fsSL -o "$FW/LICENSE.i915" https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/LICENSE.i915; fi; fi
log "    GuC firmware $(stat -f %z "$FW/mtl_guc_70.bin") B"

log ">>> HONOR idr_preload fix (FreeBSD linux_idr.c): no sched_pin around the allocation"
python3 - "$S/freebsd/sys/compat/linuxkpi/common/src/linux_idr.c" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
if 'E16 idr_preload' not in s:
    a="idr_preload(gfp_t gfp_mask)\n{\n\tstruct linux_idr_cache *lic;\n\tstruct idr_layer *cacheval;\n\n\tsched_pin();\n"
    b="idr_preload_end(void)\n{\n\tstruct linux_idr_cache *lic;\n\n\tlic = &DPCPU_GET(linux_idr_cache);\n\tspin_unlock(&lic->lock);\n\tsched_unpin();\n"
    assert s.count(a)==1 and s.count(b)==1, "linux_idr.c is not the expected d2145e9 text"
    s=s.replace(a,a.replace("\tsched_pin();\n","\t/* E16 idr_preload: no sched_pin - malloc in a critical section panicked (HONOR 0x6edf0) */\n"))
    s=s.replace(b,b.replace("\tsched_unpin();\n","\t/* E16 idr_preload: no sched_unpin (HONOR 0x6ef36) */\n"))
    open(p,'w').write(s)
print("linux_idr.c ok")
PY

log ">>> kcabi tools read the laptop's collection"
for f in tools/kpi_split.py tools/kexport.py; do
  grep -q 'KCABI_KC' "$WTL/$f" || sed -i '' 's#kcfile.KC("/System/Library/KernelCollections/BootKernelExtensions.kc")#kcfile.KC(os.environ.get("KCABI_KC") or "/System/Library/KernelCollections/BootKernelExtensions.kc")#' "$WTL/$f"; done
mkdir -p "$WTL/out"
# link.sh checks: on the arm64 Mac kmutil only knows the Mac's own arm64 KPIs, so kpi_check rejects every
# x86 symbol; kmutil on the laptop enforces the same rule when full-install builds the aux collection.
python3 - "$WTL/tools/link.sh" <<'PY2'
import sys;p=sys.argv[1];s=open(p).read()
if 'E16 cross' not in s:
    s=s.replace('python3 ~/src/kcabi/linkcheck.py "$ROOT/out/XeGfx.kext" | tail -25',
      'python3 ~/src/kcabi/linkcheck.py "$ROOT/out/XeGfx.kext" ${KCABI_KC:+--kc "$KCABI_KC"} | tail -25')
    s=s.replace('python3 "$ROOT/tools/kpi_check.py" "$ROOT/out/XeGfx.kext" || exit 1',
      '# E16 cross: kmutil on an arm64 host cannot resolve x86_64 KPIs\nif [ "$(uname -m)" = x86_64 ]; then python3 "$ROOT/tools/kpi_check.py" "$ROOT/out/XeGfx.kext" || exit 1; else echo "kpi check skipped on $(uname -m) (kmutil on the laptop checks it)"; fi')
    s=s.replace('python3 "$ROOT/tools/shadow_check.py" "$ROOT/out/XeGfx.kext" || exit 1',
      'python3 "$ROOT/tools/shadow_check.py" "$ROOT/out/XeGfx.kext" ${KCABI_KC:+--kc "$KCABI_KC"} || exit 1')
    assert s.count('E16 cross')==1
    open(p,'w').write(s)
print("link.sh ok")
PY2

log ">>> XeGfx core (this takes a while)"
( cd "$WTL" && XEGFX_FW="$FW" bash build/build_xegfx.sh ) >> "$L" 2>&1 || { tail -40 "$L"; echo "CORE BUILD FAILED (log: $L)"; exit 1; }
K=$WTL/out/XeGfx.kext; [ -f "$K/Contents/MacOS/XeGfx" ] || { echo "STOP: no $K"; exit 1; }
grep -aq xgFlipInit "$K/Contents/MacOS/XeGfx" || { echo "STOP: built core has no xgFlipInit"; exit 1; }
rm -rf "$UP/kexts/XeGfx.kext"; ditto "$K" "$UP/kexts/XeGfx.kext"
log "    XeGfx.kext $(stat -f %z "$K/Contents/MacOS/XeGfx") B, flip slots: yes"

log ">>> XeGfxAccel (zero-copy flip) + NVMTLDriver"
export OGKM=$W/ogkm OUTROOT=$W/out/kexts
( cd "$W" && bash wtl/build/build_xegfxaccel.sh ) >> "$L" 2>&1 || { tail -30 "$L"; echo "ACCEL BUILD FAILED"; exit 1; }
rm -rf "$UP/kexts/XeGfxAccel.kext"; ditto "$W/out/kexts/XeGfxAccel/26/XeGfxAccel.kext" "$UP/kexts/XeGfxAccel.kext"
grep -aq "E16 zero-copy flip" "$UP/kexts/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel" || { echo "STOP: accel without the flip"; exit 1; }
( cd "$W" && XEGFX_DEPS=$W XEGFX_OUT=$W/out RELEASE=1 bash wtl/build/build_plugin.sh ) >> "$L" 2>&1 || { tail -30 "$L"; echo "PLUGIN BUILD FAILED"; exit 1; }
cp "$W/out/plugin/NVMTLDriver" "$UP/NVMTLDriver"; codesign -f -s - "$UP/NVMTLDriver" >> "$L" 2>&1

if [ -d /Volumes/1401/xegfx-e16 ]; then D=/Volumes/1401/xegfx-e16
  mkdir -p "$D/kexts" "$D/userland"
  for k in XeGfx XeGfxAccel; do rm -rf "$D/kexts/$k.kext"; ditto --norsrc --noextattr "$UP/kexts/$k.kext" "$D/kexts/$k.kext"; done
  cp "$UP/NVMTLDriver" "$D/NVMTLDriver"; cp "$UP/NVMTLDriver" "$D/userland/NVMTLDriver"
  cp "$HERE/full-install.sh" "$UP/xe-up.sh" "$UP/fps-check.sh" "$D/"; dot_clean "$D" 2>/dev/null || true; log "copied to the USB stick"
else log "USB not mounted: copy kexts/XeGfx.kext, kexts/XeGfxAccel.kext, NVMTLDriver, core/full-install.sh, xe-up.sh by hand"; fi
log DONE
