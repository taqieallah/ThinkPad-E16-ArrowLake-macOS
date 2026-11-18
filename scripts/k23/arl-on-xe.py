#!/usr/bin/env python3
"""arl-on-xe.py <gpu-src> [sdk]: after MeowXE3's setup-nmxgpu-wcl.sh, makes NMXGPU drive Arrow Lake H (8086:7D51, 7DD1:
the ThinkPad E16's Core Ultra 7 255H) with Linux 6.14's xe instead of i915.

Why xe: MeowXE3's display bridge needs its scan-out buffer in stolen memory (one physical run, GGTT-mapped); only xe has
that path (0053, xe_bo_dumb_create), and it applies from graphics 12.70 (Meteor Lake / Arrow Lake) up, where stolen
memory is reached through BAR2. 6.14 xe lists Arrow Lake H as INTEL_ARL_H_IDS with mtl_desc but only probes it when
forced; i915 lists the same ids and probes them by default. So:
  1. xkpi/override/xe/nmx_xe_module.c: 7d51,7dd1 appended to NMX_XE_FORCE_PROBE.
  2. drm-kmod i915_pci.c: INTEL_ARL_IDS -> INTEL_ARL_U_IDS + INTEL_ARL_S_IDS (Arrow Lake H left out), so the two
     drivers never claim the same device.
  3. intel_display_device.c: MeowXE3's Wildcat Lake safe display (PSR, FBC, DC5/DC6 off) also on display 14.
  4. with [sdk] (an SDK path, or a name such as macosx26.5): the build scripts use it instead of the default SDK.
Idempotent; exits non-zero if a target text is missing.
"""
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1]).expanduser()
sdk = sys.argv[2] if len(sys.argv) > 2 else ""
IDS = ["7d51", "7dd1"]
fail = 0

m = src / "xkpi/override/xe/nmx_xe_module.c"
s = m.read_text()
r = re.compile(r'#define NMX_XE_FORCE_PROBE "([^"]*)"')
hit = r.search(s)
if not hit:
    print(f"MISSING: NMX_XE_FORCE_PROBE in {m}"); fail = 1
else:
    ids = [i for i in hit.group(1).split(",") if i]
    add = [i for i in IDS if i not in ids]
    if add:
        note = "/* E16 k23: Arrow Lake H (6.14 INTEL_ARL_H_IDS, mtl_desc) forced onto xe; i915 no longer lists it */\n"
        s = s[:hit.start()] + note + '#define NMX_XE_FORCE_PROBE "' + ",".join(ids + add) + '"' + s[hit.end():]
        m.write_text(s)
    print("xe force_probe:", ",".join(ids + add))

p = src / "kpi/drm-kmod/drivers/gpu/drm/i915/i915_pci.c"
s = p.read_text()
old = "\tINTEL_ARL_IDS(INTEL_VGA_DEVICE, &mtl_info),\n"
new = ("\t/* E16 k23: Arrow Lake H (7D51, 7DD1) is xe's here */\n"
       "\tINTEL_ARL_U_IDS(INTEL_VGA_DEVICE, &mtl_info),\n"
       "\tINTEL_ARL_S_IDS(INTEL_VGA_DEVICE, &mtl_info),\n")
if new in s:
    print("i915: Arrow Lake H already left out")
elif s.count(old) == 1:
    p.write_text(s.replace(old, new)); print("i915: Arrow Lake H left out (ARL-U and ARL-S kept)")
else:
    print(f"MISSING: INTEL_ARL_IDS line in {p}"); fail = 1

# 3. MeowXE3 (0052) keeps PSR, FBC and DC5/DC6 off on Wildcat Lake's display 30.02 only. Arrow Lake H (display 14)
#    ran with all three on: with flips the whole Mac froze within minutes (no log, no panic), without flips the panel
#    kept a stale picture and refreshed only a strip under the menu bar (PSR2 selective update). Same safe set here.
d = src / "kpi/drm-kmod/drivers/gpu/drm/i915/display/intel_display_device.c"
s = d.read_text()
old3 = "if (NMX_WCL_SAFE_DISPLAY && DISPLAY_VERx100(display) == 3002) {"
new3 = "if (NMX_WCL_SAFE_DISPLAY && (DISPLAY_VERx100(display) == 3002 || DISPLAY_VER(display) == 14)) { /* E16 k23: + Arrow Lake H */"
msg_old, msg_new = '"WCL bring-up: PSR %d, FBC %d, DC %d\\n"', '"WCL/ARL bring-up: PSR %d, FBC %d, DC %d\\n"'
if new3 in s:
    print("display: PSR/FBC/DC off on Arrow Lake already")
elif s.count(old3) == 1:
    s = s.replace(old3, new3)
    if s.count(msg_old) == 1: s = s.replace(msg_old, msg_new)
    d.write_text(s); print("display: PSR, FBC, DC5/DC6 off on Arrow Lake H (display 14) as on Wildcat Lake")
else:
    print(f"MISSING: WCL safe-display block in {d}"); fail = 1

if sdk:
    n = 0
    for f in list((src / "xkpi").glob("*.sh")) + list((src / "xkpi/kext").glob("*.sh")):
        t = f.read_text()
        # a path (/.../MacOSX26.5.sdk) is used as it is; a name (macosx26.5) through xcrun
        u = t.replace("$(xcrun --sdk macosx --show-sdk-path)", sdk if sdk.startswith("/") else f"$(xcrun --sdk {sdk} --show-sdk-path)")
        if u != t:
            f.write_text(u); n += 1
    print(f"SDK {sdk} in {n} build scripts")

sys.exit(fail)
