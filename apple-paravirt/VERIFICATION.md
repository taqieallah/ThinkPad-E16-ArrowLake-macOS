# Verification — 0.3.0

Every check was run in the build workspace on the MacBook Air (Apple M5, macOS 27.2.1, Xcode 21,
Rosetta 2 available). The ThinkPad E16 was not connected. The raw log is `VERIFICATION.log`
(produced by `src/tooling/run-verification.sh`, the same script that lives in this package).

## 1. Apple image identity

```
sha256 apv/com.apple.driver.AppleParavirtGPU                    14985840a5d1f7b2859b25b21413860aa0f6de66bf845f505a777ae8a174d51c
sha256 /Volumes/1401/xegfx-e16/diag-25G241/…AppleParavirtGPU    14985840a5d1f7b2859b25b21413860aa0f6de66bf845f505a777ae8a174d51c
dwarfdump --uuid                                               0CAE9E29-BC33-315D-82A7-A7D30E9B971E (x86_64)
```

The audited image is byte-identical to the driver extracted from the E16. RESULT: **PASS**.

## 2. Patch plan against the real Mach-O

```
python3 tooling/verify-sites.py
  site 0 version-pair               __TEXT+0x02cdc span 7 bar 0x1034 kind=version_pair in setupVersion (+0x54)
  site 1 version-fallback-write     __TEXT+0x02df0 span 7 bar 0x1034 kind=write_imm
  site 2 stamp-bitmap               __TEXT+0x02edf span 7 bar 0x1018 kind=read32
  site 3 display-bitmap             __TEXT+0x02f06 span 5 bar 0x1014 kind=read32
  site 4 display-port-count         __TEXT+0x010aa span 7 bar 0x122c kind=read32
  site 5 fault-branch               __TEXT+0x02f20 span 6 bar 0x102c kind=read_branch
  site 6 fifo-disable               __TEXT+0x0301e span 6 bar 0x1000 kind=write_imm
  cell  ----  writeFifo cursor poll __TEXT+0x02b84 (unpatched, shared page)
PASS: 7 patched sites and 1 shared-cell reads verified against <uuid> (__TEXT 0x18000 bytes)
```

Checks: UUID + Mach-O type; exact original bytes; site start and span end on instruction
boundaries (llvm-objdump); continuation rules (branch sites: one tail target is `offset+span`,
both targets are instruction boundaries); span 5–16 bytes so `E8 rel32` fits; generated header in
sync with `sites.json`. RESULT: **PASS**.

## 3. Stubs executed for real

```
stub simulator: 7 sites
PASS: 7 site stubs execute with the expected register and flag contract
```

Per site: dispatcher arguments; read result in the exact destination register (`r12d`, `r14d`,
`esi`, `r9d`); the reproduced `testl` flags; the **fault branch stub** takes the nonzero target for a
nonzero fault and the zero target for zero; every other GPR restored; return address dropped;
patch = `E8 rel32` + NOPs with the rel32 recomputing to the stub; out-of-range rel32 refused.
RESULT: **PASS**.

## 4. Kext build

```
cd kext && bash build.sh ~/Downloads/ReimsPCIProbe/MacKernelSDK
MH_MAGIC_64  X86_64  KEXTBUNDLE  NOUNDEFS DYLDLINK TWOLEVEL
```

`otool -l` shows `__TEXT,__apvstubs` (0x700 bytes, 64-aligned); `nm` shows `_e16_apv_dispatch`
and `gStubArea`; the Info.plist is 0.3.0. RESULT: **PASS**.

## 5. Kext linkage on 25G241

```
kcabi linkcheck build/ReimsPCIProbe.kext --kc /Volumes/1401/xegfx-e16/diag-25G241/BootKernelExtensions.kc \
       --baseline <reference 0.1.10 kext>
  com.apple.iokit.IOPCIFamily  45 ok
  com.apple.kernel            347 ok
  not exported, but the baseline lacks them too: 9   (the IOPCIDevice _RESERVED… kxld slots)
link check ok
```

RESULT: **PASS** (link), load untested.

## 6. Host daemon

```
cd host && bash build.sh                 # builds apv-host with the panel pipeline
arch -x86_64 ./apv-host --no-arm --seconds 1
  host: Reims device created (registry id 0x0, 1 display port(s))
  host: self-check version=0x6 display_port_count=1 (expect 0x6 and 1)
  host: teardown complete: mmio=0 irq=0 maps=0 map_failures=0
```

Real Reims device on the Air's Metal device through Rosetta 2; the MMIO wrappers round-trip the
version handshake. `--display` fails closed here (no `NMXAccel` service on this Mac) and the run
continues. RESULT: **PASS**.

Real-Reims protocol evidence (prototype, `docs/REIMS-HOST-REPORT.md`): 13/13 register sequence;
`0x1034` 6→6; `0x122c`→1; doorbell with a `Nop` command raises `raise_interrupt(0)` on
`reims-vgpu.fifo`, `0x1018` reads 1 then 0; dynamic memory route maps `gpa 0x40000000` (root
page) and `gpa 0x40100000` (FIFO); mixing a static map with the callbacks is refused with
`RVG_ERR_MEMORY_CONFLICT = 5`.

## 7. XeGfxAccel panel patch

```
cd xegfx && bash build-xegfx-accel.sh
26  XeGfxAccel 606895556ec24fd2dd2c44519a5099ff 296584 B
sha256 0114f3f2ef433360e88a8747c6d631bd6d7d074a60718023f6e4bf4fe04c8f5a
codesign --verify --strict   ok
lipo -verify_arch x86_64     ok
marker "XG_PANEL ABI 1"      present
```

* Undefined-symbol diff against the installed E16 `XeGfxAccel.kext`: **empty** (no new imports,
  so the patched accelerator is drop-in compatible with the installed XeGfx core).
* kcabi linkcheck against the target 25G241 `BootKernelExtensions.kc` with the installed kext as
  baseline: `link check ok`.
* The patch is `xegfx/xegfx-panel.patch` (223 lines, header + nvrm-accel.cpp only); no XeGfx core,
  no framebuffer and no NMIntelFB changes. RESULT: **PASS** (build/link), runtime untested.

## 8. Package integrity

```
plutil -lint kext/ReimsPCIProbe.kext/Contents/Info.plist                     OK
bash -n scripts/*.sh                                                        OK
lipo -verify_arch x86_64 host/apv-host host/lib/libreims_vgpu.dylib tools/metal-registry
lipo -verify_arch x86_64 xegfx/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel    OK
codesign --verify --strict host/apv-host host/lib/libreims_vgpu.dylib tools/metal-registry
marker "XG_PANEL ABI 1" in xegfx/XeGfxAccel.kext                            present
xegfx/PANEL-ABI.md and xegfx/xegfx-panel.patch present                      OK
```

The shipped `E16-APV-Live-0.3.0.zip` was unzipped in a clean directory and its `host/apv-host
--no-arm` ran there with the expected output before this report was written.

## 9. Not verified here (the E16 step)

| item | needs |
|---|---|
| kext load / patch application in the loaded kernel text | the E16 |
| `findApvImage` walking back from the map caller | the E16 |
| physical page → daemon mapping | the E16 |
| IRQ0 → Apple event source → `signalStamps` | the E16 |
| synthetic MSI capability path through `configureDevice` | the E16 |
| patched XeGfxAccel install + panel-present end-to-end | the E16 |
| the daemon's decode → IOSurface → PLANE_SURF → panel chain | the E16 |
