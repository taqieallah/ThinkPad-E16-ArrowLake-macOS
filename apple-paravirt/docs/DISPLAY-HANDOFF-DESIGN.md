# External-producer scanout on the E16: Reims -> XeGfx -> eDP panel

**Scope**: a code-level handoff design for presenting externally produced frames (Reims, rendering
with Metal on the XeGfx Metal device) on the ThinkPad E16's internal eDP panel, plus the minimal
patch to XeGfxAccel / XeGfxIntelFB / NMIntelFB that lets a userspace daemon submit a BGRA linear
buffer (or an IOSurface/MTL-texture-backed memory) as the scanout surface and trigger a flip.

**Tree read**: `/Users/taqieallah/src/xe-e16/wtl` (WTLIntelGfx) at commit `ff64f83` plus the local
E16 modifications visible in `git status` (`kexts/XeGfxAccel/accel/nvrm-accel.cpp` +435 lines,
`kexts/XeGfxIntelFB/intelfb.cpp` +140, `shim/src/xnu/xg_kext.cpp` +76, `shim/include/xg_i915.h`
+11 with the new untracked `xkpi/src/i915/xg_i915_flip.c`, `plugin/nvmtl_vk.c` +145,
`plugin/NVMTLObjects.m` +19). Everything below was read from that tree; **nothing in
`/Users/taqieallah/src` was modified**. All line references are to that tree.

**Method**: read of the seven requested call chains plus build config, Info.plists, the local
E16 activation script (`e16-k13/package/k13/xe-up.sh`, read-only, in the workspace), the Reims
sibling projects (`e16-work/E16-ReimsMMIOBridge`, `e16-work/E16-APVBootstrapHook`), and a static
read of the extracted AppleParavirtGPU binary (`e16-work/apv/apv.dis`, 25G241, x86_64). No kext was
built, loaded, or modified. Anything that cannot be decided without the physical E16 is marked
**[HW]** and collected in section 7.

---

## 0. Conventions

* `PLANE_SURF_1_x` = `0x7019C + pipe*0x1000`; `PLANE_CTL` = `0x70180`, `PLANE_STRIDE` = `0x70188`,
  `PLANE_SIZE` = `0x70190`, `FRMCOUNT` = `0x70040`, `TRANSCONF` = `0x70008`, `PIPEDSL` = `0x70000`,
  `VTOTAL` = `0x6000C`. Same layout as `kexts/NMIntelFB/intelfb.cpp:100-110`.
* "head 4" is the accelerator's slot for the Intel built-in panel
  (`nvrm-accel.cpp:110`, `:457-520`, `:995-1010`). It is not a silicon head number.
* "GGTT" = Intel graphics translation table; PTEs live at BAR0+0x800000 ("GSM",
  `XIFB_GSM 0x800000u` at `kexts/XeGfxIntelFB/intelfb.cpp:203`), 8 bytes each.
* "the plugin" = `plugin/NVMTLDriver` (`NVMTLDevice`/`NVMTLObjects`) over NVK over XeGfx core.
* **[HW]** = needs the physical E16 to decide.

---

## 1. Who owns the panel scanout today, and the exact data path

### 1.1 Three different "owners", and only one of them is a driver

1. **The display engine's register state.** The firmware (GOP) lit pipe/transcoder + plane 1 and
   left the timings alone. macOS never reprograms them:
   `compat.linuxkpi.i915_disable_display=1` keeps i915's display half off
   (`shim/src/xnu/xg_kext.cpp:1012` sets that env default; `docs/HOW-IT-WORKS.md:46-50`
   explains why), and there is no NDRV to do a modeset. XeGfxIntelFB *reads* the live raster once
   (`kexts/XeGfxIntelFB/intelfb.cpp:364-378`) and publishes it; it has no `setDisplayMode` hardware
   path (`intelfb.cpp:401` `getCurrentDisplayMode` only answers queries). NMIntelFB reads the same
   registers (`kexts/NMIntelFB/intelfb.cpp:319-350`) and explicitly writes nothing.

2. **The GGTT slots** that the plane's 32-bit `PLANE_SURF` names. The GGTT itself is owned by XeGfx
   core (i915 in the shim). The E16 extension reserves up to 8 slots below 4 GiB and owns their PTEs
   in `xkpi/src/i915/xg_i915_flip.c`:
   ```
   /* Zero-copy scanout: reserved GGTT slots whose PTEs point at the compositor's own frame pages.  The accelerator
    * (XeGfxAccel) writes PLANE_SURF_1_A itself; this file only owns the GGTT side - reserve, PTE writes, invalidate. */
   ```
   (`xg_i915_flip.c:1-8`), exported to other kexts through the `XeGfxResident` service
   (`shim/src/xnu/xg_kext.cpp:172-193`).

3. **The frame delivery**, i.e. who decides *which* memory the plane scans and when. That is
   XeGfxAccel: `NVDisplayPipe::performTransaction` (`nvrm-accel.cpp:1674`) is the display-pipe
   object the CoreDisplay/WindowServer family talks to, and it is the only steady-state writer of
   `PLANE_SURF_1_<pipe>`:
   * the copy path (`performTransaction:1744-1793` + `xeCopyNow:3404-3441`) writes pixels into the
     firmware framebuffer and leaves `PLANE_SURF` on the GOP value;
   * the E16 zero-copy flip (`nvXeFlipNow:3306-3362`) writes `PLANE_SURF_1_p = GGTT slot`;
   * `nvXeFlipHome` (`:3292-3302`) writes the GOP value back.

   The only other *writer* of that register in the whole tree is XeGfxIntelFB's hardware-cursor
   setup, and only once: `curDdb()` re-arms the value it just read
   (`kexts/XeGfxIntelFB/intelfb.cpp:265-267` `wr(XIFB_P1_BUF, 0x07df0000u); wr(XIFB_P1_SURF,
   rd(XIFB_P1_SURF));`). That is a genuine (narrow) race against a flip - see section 5.4.

Which framebuffer the E16 build actually uses: **XeGfxIntelFB**, not NMIntelFB. Evidence:
the E16-only changes in `git status` are in `kexts/XeGfxIntelFB/` (Arrow Lake-H/LPG+ PCI IDs
`0x7d51 0x7d67 0x7d41 0x7dd1` in its `Info.plist`, the "GOP puts its framebuffer at 0xff600000"
cursor fix at `intelfb.cpp:236-245`, the `NVRMTiming`/AGDC-K5 record at `intelfb.cpp:156-196` and
`:389-392`); NMIntelFB is untouched, has no `IONameMatch` and `IOProbeScore 60000` vs
XeGfxIntelFB's `20001` (`kexts/NMIntelFB/Info.plist`, `kexts/XeGfxIntelFB/Info.plist`), so if both
were installed NMIntelFB would win - it is not part of the E16 install set. The E16 activation
script only ever installs `XeGfxAccel.kext` on top of the existing stack
(`e16-k13/package/k13/install.sh:17`) and its K5 step depends on XeGfxIntelFB's `NVRMTiming`
(`e16-k13/package/k13/xe-up.sh:70-72`). The framebuffer also has to be one the accelerator sees on
its own `IOPCIDevice`: `nvrm-accel.cpp:467-472` forces any framebuffer published on `fPCI` to head 4
and the two notifications registered at `:995-1010` are `NMIntelFB` and `IONDRVFramebuffer`
(XeGfxIntelFramebuffer is a subclass of the latter, so it matches the `IONDRVFramebuffer`
`serviceMatching`) **[HW]** confirm the class name in `ioreg`.

### 1.2 Path A - the copy path (default; `debug.nvaccel_xe_flip=0`)

```
 WindowServer (CoreDisplay / IOPresentment)
   |  Metal: NVMTLDriver -> NVK -> XeGfx i915 (GEM, GGTT, GuC submission)
   v
 IOSurface, fourcc 'BGRA' (0x42475241), in wired system memory
   |  CoreDisplay submits an IOAccelDisplayPipe2 transaction for the panel's pipe
   v
 XeGfxAccel: NVDisplayPipe::performTransaction               nvrm-accel.cpp:1674
   |- gNvIop gate (:1676); find fb -> head via pipe+0x98     :1681-1683, :818-826
   |- s = txn->getPlaneIOSurface(0,0)                        :1684
   |- nvAccelIopFlip() -> false (not NVRMNVDAFramebuffer)    :1711, :2646
   |- head == 4 && gXeAsyncCopy -> nvXeCopyQueue(this,fb,4,s) :1718, :3229
   |     returns kIOReturnSuccess; completion is signalled later
   v
 worker thread_call: nvXeCopyRun                            :3210
   v
 NVDisplayPipe::xeCopyNow(fb, head=4, s)                    :3404
   |- nvXeWaitFrame(surfaceID)  (K9b: mark or GT idle)       :3408, :3384
   |- nvAccelSurfCopyReady(s, head)                          :3409, :2761
   |- format must be 'BGRA'; geometry sanity                  :3410-3412
   |- iopMapSurface(surfaceID, md, H*P)  (CPU read map)      :3415, :1415
   |- askFramebufferForScanout -> describeBootFramebuffer     :3420, :762, :783
   |     (kva/pitch/W/H from the boot aperture + live mode)
   |- nvXeWaitVblank(fPCI, H)   (PIPEDSL poll, pipe discovered)  :3423, :1644
   |- nvXeIopClflush(src, H*P)  ("the display engine does not snoop the CPU caches")  :3433, :1503
   |- memcpy into the firmware framebuffer at q.kva           :3434-3436
   v
 signalTransactionInterrupt(pipe)   (the family's completion) :3225, :2515
   v
 Intel display engine scans the GOP framebuffer (GGTT 0xff600000 on the E16)
```

### 1.3 Path B - the E16 zero-copy GGTT flip (opt-in; `debug.nvaccel_xe_flip=1`)

Same prologue up to `xeCopyNow`; instead of the copy:

```
 NVDisplayPipe::xeCopyNow: if (gXeFlip && head == 4) {          :3422
     if (gIopVblPipe < 0) nvXeWaitVblank(...)   // discovers the pipe
     if (nvXeFlipNow(this, H, s, P, src)) return true; }
       |
       |- read PLANE_CTL/STRIDE of pipe p                      :3311
       |- require: plane enabled, linear (tiling 12:10 == 0), stride == P   :3312-3313
       |- bytes = P*H; first flip reserves 3 GGTT slots of that exact size  :3315-3325
       |    nvXeResidentCall("xgFlipInit", bytes, 3, ggtt[], &n)
       |      -> XeGfxResident::callPlatformFunction                 xg_kext.cpp:175
       |      -> xg_flip_init(bytes, 3, ...)                        xg_i915_flip.c:39
       |         i915_gem_gtt_insert(..., 0x80000000, 0x100000000, PIN_NOEVICT)
       |- remember gXeFlipOrigSurf = old PLANE_SURF (first time only)  :3326
       |- pick a slot != gXeFlipLive                                   :3327-3329
       |- md = s->getMemoryDescriptor(); md->prepare(); collect 4 KiB pages  :3330-3338
       |- nvXeResidentCall("xgFlipMap", slot, phys[], npages, bytes)   :3344
       |      -> xg_flip_map: pte_encode(pa, I915_CACHE_NONE) + writeq + ggtt->invalidate  xg_i915_flip.c:81-106
       |- clflush the frame (gXeFlipClflush)                           :3348
       |- r[(0x7019c+p*0x1000)/4] = (uint32_t)ggtt[slot];   // the arming write   :3349
       |- nvXeWaitLatch(): wait for FRMCOUNT to move, max 25 ms        :3350, :3284
       |- retain the surface: gXeFlipPrev = gXeFlipFront; gXeFlipFront = s   :3351-3353
```

The panel then scans the IOSurface's own pages through the GGTT slot. The ioctl/kext-side call
chain is: `nvrm-accel.cpp:3272 nvXeResidentCall` -> `xg_kext.cpp:149-196 XeGfxResident::
callPlatformFunction` -> `xg_i915_flip.c` -> i915 GGTT helpers.

### 1.4 What the WindowServer producer contract really is

`performTransaction` is a **family callback**, not an ioctl: the transaction carries
`getPlaneIOSurface(0,0)` (the composited IOSurface) and optionally `getPlaneResource(0,0)`; the
accelerator must either show it or return early, and the family's `isTransactionComplete`
(`nvrm-accel.cpp:1452-1463`) is what gates WindowServer's next swap. Completion is signalled by
`signalTransactionInterrupt` (`extern` at `:2514-2516`), called from the async worker
(`:3225`) or the NVIDIA-style async flip worker (`:2597`). The E16 copy worker therefore owns
"when WindowServer is told the frame landed", which is why `isTransactionComplete` and
`debug.nvaccel_xe_flip_hold` exist (`:1452-1463`, `:1449`, `:3265`). Readiness of the *pixels*
comes from the plugin's completion marks (XGDR selector 1, `:338-367`) and/or the core's GT-idle
query (`nvXeWaitFrame`, `:3384-3402`).

### 1.5 Vblank

There is **no vblank interrupt** in this path. Both the copy and the flip *poll*:
* copy: `nvXeWaitVblank` (`:1644-1671`) finds the enabled pipe whose `VTOTAL & 0xffff + 1 == H`,
  then polls `PIPEDSL` until the scanline passes the active height (bounded 25 ms).
* flip: the arming write is double-buffered; `nvXeWaitLatch` (`:3284-3290`) polls `FRMCOUNT` for a
  change, bounded 25 ms. That is the only "the frame is on the panel" signal the kext has.
* WindowServer's own pacing comes from the family transaction completion plus (for the copy path)
  `nvXeWaitFrame`'s mark/idle wait. XeGfxIntelFB does not implement a VBL interrupt source
  (`intelfb.cpp` has no `registerForInterruptType`); NMIntelFB supplies a 60 Hz timer "VBL"
  (`intelfb.cpp:130-153 armVbl`). **[HW]** check which the E16 actually gets.

### 1.6 ASCII: today's full stack

```
+--------------------------------------------------------------------------------------+
| WindowServer / apps                                                                  |
|   Metal: NVMTLDevice/NVMTLObjects (plugin/NVMTLDriver) -> NVK -> XeGfx (i915 in shim) |
+--------------------------------------------------------------------------------------+
          | IOAccelDisplayPipe2 transaction (IOSurface 'BGRA')
          v
+--------------------------------------------------------------------------------------+
| XeGfxAccel (kext, NMXAccel)                                                          |
|   NVDisplayPipe::performTransaction  (head 4 = Intel panel)                          |
|        |                                   \                                         |
|        | A: copy (default)                  \ B: zero-copy flip (opt-in sysctl)       |
|        v                                    v                                          |
|   nvXeCopyRun worker                   nvXeFlipNow                                    |
|   xeCopyNow                            xgFlipInit/xgFlipMap (GGTT)                   |
|   memcpy -> boot framebuffer kva       PLANE_SURF = slot                              |
|        |                                    |                                          |
|        +---------------> PLANE_SURF unchanged / written <----------------+            |
+--------------------------------------------------------------------------------------+
                                     |
                                     v
+--------------------------------------------------------------------------------------+
| XeGfx core (shim kext, XeGfxResident)   GGTT: slots, PTEs, TLB invalidate            |
|   i915 with display disabled; boot framebuffer reserved; no display programming       |
+--------------------------------------------------------------------------------------+
                                     |
                                     v
+--------------------------------------------------------------------------------------+
| Intel display engine (firmware mode, never reprogrammed)                             |
|   pipe p / plane 1 linear (PLANE_CTL tiling = 0, format 8 = XRGB8888)                |
+--------------------------------------------------------------------------------------+
                                     |
                                     v
                              eDP panel (E16)
```

---

## 2. The buffer contract of that path

### 2.1 Table

| Property | Copy path (A) | Zero-copy flip (B) | Where enforced |
|---|---|---|---|
| Pixel format | IOSurface fourcc `'BGRA'` = `0x42475241`; memory order B,G,R,A | same | `:1729-1730`, `:3410` |
| Plane format on the glass | `PLANE_CTL` bits 27:23 = 8 = **XRGB 8:8:8:8**; the alpha byte is the X and is ignored | same | read in `nvXeFlipNow:3311`, checked only for enable/tiling; format 8 documented in `kexts/NMIntelFB/intelfb.cpp:117-118` |
| Row pitch | `P = IOSurfaceGetBytesPerRow`, `P >= 4W`, `P & 3 == 0`; rows copied one at a time so `P != fb pitch` is allowed | **`P` must equal `(PLANE_STRIDE & 0x7ff) * 64` exactly** | `:1733`, `:3412`, `:3313` |
| Pitch alignment | word (4 B) | 64 B (the register counts 64-byte units) | `nvXeFlipNow:3311` |
| Tiling | n/a (CPU copy) | **linear only**: `PLANE_CTL & (7<<10) == 0` | `:3313` |
| Size / mode | `W == q.width && H == q.height` from the boot descriptor; `W,H <= 16384`; `H*P <= md length` | same, plus `bytes == P*H` must match the slot reservation (fixed size) | `:1749`, `:3315` |
| Geometry source | `describeBootFramebuffer` -> `getCurrentDisplayMode` + `getPixelInformation` (XeGfxIntelFB reports `PLANE_SIZE`/`PLANE_STRIDE`: `intelfb.cpp:372-376`, `:410-421`) | live `PLANE_SIZE`/`PLANE_STRIDE`/`PLANE_CTL` | `:783-816` |
| GGTT slot address | none | 32-bit, 4 KiB aligned, **below 4 GiB** (PLANE_SURF is 32-bit), range `[0x80000000,0x100000000)`, sized `round_up(P*H,4096)`, no-evict | `xg_i915_flip.c:53-76`; cast to `uint32_t` at `nvrm-accel.cpp:3349` |
| GGTT PTE encoding | n/a | `pte_encode(pa, I915_CACHE_NONE)` = uncached, present | `xg_i915_flip.c:97-104` |
| Max frame size | bounded by the mapped surface | `static unsigned long long phys[4224]` -> **4224 pages = 16.5 MiB max** (2560x1600x4 = 4000 pages fits; 2880x1800x4 = 5063 does not) | `:3332-3343` |
| Pinning lifetime | md prepared/mapped during the copy only | pages collected per present (`md->prepare()`/`complete()`); the IOSurface is `retain()`ed as `gXeFlipFront`/`gXeFlipPrev`, i.e. **two generations**; pages must not move (IOSurface memory is wired) | `:3330-3353` |
| Fence | surface mark + GT idle (K9b), up to `xe_idle_ms` (40 ms default), then vblank poll | same wait happens *before* arming (caller `xeCopyNow:3408`); after arming only the **latch** poll | `:3384-3402`, `:3284-3290` |
| Scanout completion | completion signalled by `signalTransactionInterrupt` after the copy | latch observed (or 25 ms timeout) then the call returns | `:3225`, `:3350` |
| Teardown | nothing to unwire | `nvXeFlipHome` writes the GOP surface back; **the slot PTEs are not cleared** (hardening gap, section 5.5) | `:3292-3302` |

### 2.2 Why `'BGRA'` is the right format

`0x42475241` is the fourcc `'BGRA'` (`'B'<<24 | 'G'<<16 | 'R'<<8 | 'A'`). In memory that is bytes
`B,G,R,A`, i.e. a little-endian 32-bit word `A<<24 | R<<16 | G<<8 | B`. The Intel plane is
programmed as `XRGB8888` (`PLANE_CTL` format 8; `kexts/NMIntelFB/intelfb.cpp:117-118`), i.e.
bits 23:16 = R, 15:8 = G, 7:0 = B. So a `'BGRA'` IOSurface is bit-for-bit the plane's XRGB8888,
with the alpha byte becoming the ignored X. The E16 framebuffer advertises exactly that memory
layout to CoreDisplay (`intelfb.cpp:410-421`: `componentMasks[0]=0x00FF0000`,
`[1]=0x0000FF00`, `[2]=0x000000FF`). This is why every present in the tree hard-checks
`s->getPixelFormat() == 0x42475241u` and nothing else.

### 2.3 The two contract checks in code, verbatim

```
    const unsigned fmt = s->getPixelFormat();
    if (fmt != 0x42475241u) NVIOP_FAIL(kIOReturnUnsupported, "surface 0x%x format 0x%08x is not BGRA", s->getSurfaceID(), fmt);
    const unsigned long long W = s->getWidth(), H = s->getHeight(), P = s->getBytesPerRow();
    if (!W || !H || P < 4 || W > 16384 || H > 16384 || P > 16384ull * 8) NVIOP_FAIL(...)
    if (P < 4 * W || (P & 3)) NVIOP_FAIL(...)
```
(`nvrm-accel.cpp:1729-1733`, and the same test at `:3410-3412` in the worker.)

```
    const uint32_t ctl = r[(0x70180 + p * 0x1000) / 4], stride = (r[(0x70188 + p * 0x1000) / 4] & 0x7ff) * 64u;
    // the plane must be on, linear (PLANE_CTL tiling 12:10 = 0) and have the frame's row pitch
    if (!(ctl & 0x80000000u) || (ctl & (7u << 10)) || stride != P) { ... return false; }
```
(`nvrm-accel.cpp:3311-3313`.)

```
    /* system-memory scanout: uncached, which on this platform encodes as a plain phys|PRESENT PTE */
    pat = i915_gem_get_pat_index(i915, I915_CACHE_NONE);
    for (i = 0; i < need; i++) {
        u64 pte = ggtt->vm.pte_encode((dma_addr_t)(phys[i] & ~0xfffull), pat, 0);
        writeq(pte, (u64 __iomem *)ggtt->gsm + (gXgFlipNode[slot].start >> 12) + i);
    }
    ggtt->invalidate(ggtt);
```
(`xkpi/src/i915/xg_i915_flip.c:97-105`.)

---

## 3. Is there an existing producer API for a second producer?

### 3.1 Inventory of everything userspace (or a second kext) can reach today

| Surface | Where | Can a daemon use it to put a frame on the panel? |
|---|---|---|
| `IOAccelDisplayPipe2` transaction -> `NVDisplayPipe::performTransaction` | family path, driven by CoreDisplay/WindowServer (`nvrm-accel.cpp:1674`) | No. It is not an ioctl; it is the family's callback on the WindowServer-owned display pipe. It is also the *only* path that can currently complete a transaction. |
| `NVAccel::newUserClient` type `'XGDR'` (`0x58474452`) -> `IOAccelXeGfxDRMClient` | `nvrm-accel.cpp:828-...`, class at `:254-369` | Partially: the client exists and is openable by any process, but its selectors are 0 = DRM ioctl (`:353-367`), 1 = WindowServer completion mark (`:338-352`), 2/3/4 = open/close/list DRM nodes (`:292-337`). **No present/flip selector.** |
| DRM ioctls through selector 0 | `xg_fd_remote_ioctl` (`shim/src/xnu/xg_fd.cpp:303`) -> `xg_fd_dev_ioctl` (`shim/src/fbsd/xg_fd.c`); ABI in `shim/include/xg_fd.h` and `tools/xgprobe.c` | No display ioctl exists in the XeGfx DRM ABI (`tools/xgprobe.c` only uses GEM/map/exec; `grep -ri "flip\|present\|scanout" userland/patches/libdrm-xegfx.patch` finds nothing). |
| `XeGfxResident` platform functions `xgFlipInit` / `xgFlipMap` / `xgFlipUnmap` / `xgFlipQuery` | `shim/src/xnu/xg_kext.cpp:172-196`; called from `nvrm-accel.cpp:3272` | These are the *mechanism* the new interface needs, but they are kernel-to-kernel `callPlatformFunction` only. Not reachable from userspace. |
| `nvAccelSurfVram` / surface escape (`NVRM_ESC_SURF_DIRTY`, `NVRM_SS_PLANE_GPU_MARK`) | `nvrm-accel.cpp:2269-2340` | No: it only posts a completion/dirty **mark** for a surface. |
| Plugin -> `XGDR` selector 1 | `plugin/nvmtl_vk.c:2142-2170` (`nvmtl_xe_gpu_mark`) | No: completion marks only. It is, however, the exact userspace pattern to copy for a new client. |
| `IOSurfaceRoot::lookupSurface(id, task)` + IOSurface getters | private shims at `nvrm-accel.cpp:2143-2148`, `:1368-1376`; used at `:2294` | Available inside XeGfxAccel; this is what a present selector would use to resolve the daemon's surface. |

**Conclusion: there is no producer API a second producer could use today.** The smallest addition
is **one new selector on the existing `'XGDR'` client** (`NVAccel::newUserClient` already routes the
type), reusing the existing GGTT-slot mechanism and the existing MMIO map of the accelerator.

Rationale for putting it on XeGfxAccel rather than on XeGfxIntelFB:
* the accelerator already has the IOSurface private-class shims (`IOSurface`,
  `IOSurfaceRoot::lookupSurface`), the GGTT calls, the MMIO map (`gXeMmio:1542`, lazily mapped in
  `nvXeWaitVblank:1647`), the pipe discovery (`nvXeWaitVblank`) and the whole flip/homing state;
* the accelerator's life is independent of the display pipe object: `gXeFlip*` state and the XGDR
  client are globals/family resources, so the present path can be **pipe-free** - which is exactly
  what section 6 needs when AppleParavirtGPU takes over;
* the framebuffer would need its own copy of all of the above plus a `newUserClient` and its own
  `externalMethod` (it currently has no user client at all).

### 3.2 Proposal: `'XGDR'` selector 5, "panel control"

One selector, four subcommands. This mirrors selector 0's (opcode, args) style and keeps the
client scalar-only (the existing `externalMethod` reads `a->scalarInput[]` only, `:290-368`).

Wire ABI (documented as a struct; carried as scalars in the patch so no IOKit dispatch-table change
is needed):

```c
#define XG_PANEL_ABI_VERSION 2u          /* bump when any field below changes */
#define XG_PANEL_FN          "xgPanel"   /* OSSymbol for any future kernel caller */

enum {                                   /* selector 5, input[0] */
    XG_PANEL_INFO    = 0,                /* read-only: the live plane raster + owner state      */
    XG_PANEL_ACQUIRE = 1,                /* this connection becomes the sole producer           */
    XG_PANEL_PRESENT = 2,                /* arm PLANE_SURF at an IOSurface's pages, wait latch  */
    XG_PANEL_RELEASE = 3,                /* give the panel back (graceful or home)              */
};

enum {                                   /* status codes (signed int32) */
    XG_PANEL_OK        = 0,
    XG_PANEL_E_VERSION = -1,   XG_PANEL_E_ARG     = -2,
    XG_PANEL_E_BUSY    = -3,   /* another connection owns the panel                     */
    XG_PANEL_E_NOPANEL = -4,   /* no enabled linear plane / accelerator has no scanout  */
    XG_PANEL_E_NOTOWNER= -5,   /* present/release from a connection that does not own   */
    XG_PANEL_E_SURFACE = -6,   /* IOSurface not found for this task                     */
    XG_PANEL_E_FORMAT  = -7,   /* not 'BGRA', not one plane, too small                  */
    XG_PANEL_E_GEOM    = -8,   /* W/H or pitch does not match the live plane            */
    XG_PANEL_E_PAGES   = -9,   /* > 4224 pages, or getPhysicalSegment failed            */
    XG_PANEL_E_NOGGTT  = -10,  /* xgFlipInit/xgFlipMap refused (core too old / no slots)*/
    XG_PANEL_E_NOTREADY= -11,  /* GT not idle within the readiness bound                */
};

/* The ABI as a struct (for a future IOConnectCallStructMethod; the patch below passes these
 * fields as scalars in the same order). */
struct xg_panel_info {                   /* XG_PANEL_INFO out */
    uint32_t version;                    /* XG_PANEL_ABI_VERSION                          */
    uint32_t flags;                      /* bit0 owner-active, bit1 plane-ok, bit2 slots  */
    uint32_t pipe;                       /* pipe index p (0..3)                           */
    uint32_t width, height;              /* PLANE_SIZE + 1                                */
    uint32_t pitch;                      /* PLANE_STRIDE * 64                             */
    uint32_t strideUnits;                /* PLANE_STRIDE & 0x7ff                          */
    uint32_t planeSurf;                  /* current PLANE_SURF (GGTT offset)              */
    uint32_t planeCtl;                   /* PLANE_CTL (bit31 enable, bits12:10 tiling)    */
    uint32_t slots;                      /* GGTT slots reserved (0 = not yet)             */
    uint32_t slotBytes;                  /* bytes per slot                                */
    uint32_t ownerPid;                   /* 0 = WindowServer owns it                      */
    uint32_t latchedMs;                  /* last latch time                               */
    uint64_t slotGgtt0;                  /* first reserved GGTT address                   */
    uint64_t flips, misses, failures;    /* counters                                      */
};
struct xg_panel_present {                /* XG_PANEL_PRESENT */
    uint32_t version;                    /* XG_PANEL_ABI_VERSION                          */
    uint32_t flags;                      /* bit0 wait GT idle (default on)                */
    uint32_t surfaceID;                  /* IOSurface ID (fourcc 'BGRA', 1 plane)         */
    uint32_t seq;                        /* caller's frame number, echoed                 */
    uint32_t timeoutUs;                  /* 0 = 25000                                     */
    int32_t  status;                     /* XG_PANEL_E_*                                  */
    uint32_t retiredSurfaceID;           /* safe to rewrite now (0 = none)                */
    uint32_t latched;                    /* 1 = the plane latched this frame              */
    uint32_t latchedMs;
};
```

Scalar encoding used by the sketch (all `uint64_t`):

| subcommand | scalarInput | scalarOutput | meaning |
|---|---|---|---|
| `INFO` (0) | `version`, `0` | `status`, `flags`, `width`, `height`, `pitch`, `pipe`, `planeSurf`, `planeCtl`, `slots`, `slotBytes`, `slotGgtt0`, `ownerPid`, `flips`, `misses`, `failures` | size the daemon's surfaces, detect geometry changes |
| `ACQUIRE` (1) | `version`, `flags` | `status`, `pitch`, `width`, `height`, `bytes` | exclusive ownership; stops the internal producer |
| `PRESENT` (2) | `version`, `surfaceID`, `flags`, `seq`, `timeoutUs` | `status`, `seq`, `retiredSurfaceID`, `latched`, `latchedMs` | flip; blocks until latch or timeout |
| `RELEASE` (3) | `version`, `flags` (bit0 = home immediately) | `status`, `flips` | hand back to WindowServer |

### 3.3 Semantics (precise)

**INFO** - reads `PLANE_CTL/STRIDE/SIZE/SURF` of the enabled pipe whose active height matches
`PLANE_SIZE` (same discovery as `nvXeWaitVblank:1650-1662`), plus the flip state. No side effects
except lazily mapping BAR0 and discovering the pipe. Safe to poll at 1 Hz.

**ACQUIRE** - succeeds only if all of these hold, else `XG_PANEL_E_*`:
1. no other external owner (the owner token `gXgPanelTask` is `TASK_NULL`, or it is this connection re-acquiring);
2. the plane is enabled and linear and its geometry is usable;
3. **if** a WindowServer producer exists on head 4 (`gNvScanout` and `gNvHeadsPiped` bit 4 - the
   phase where XeGfxAccel still drives the panel), then also `gNvIop` (`:1676`) and
   `gXeAsyncCopy == 1`, because the drop gate below completes WindowServer's transactions through
   the async worker and that is the only proven completion path. In the APV phase (section 6)
   there is no producer on head 4 and condition 3 is vacuous - see 6.4 for the exact expression.
On success: `gXgPanelTask = task`, `gXgPanelPid = proc_selfpid()`, and any live
internal flip is homed first (`nvXeFlipHome`, `:3292`) so that the plane is on a known surface
before `gXgPanelOrigSurf` is captured.

**The drop gate** - the one change to the existing producer: at the top of
`NVDisplayPipe::xeCopyNow` (`:3404`), before any wait/flip/copy:
```c
if (head == 4 && xgPanelOwned()) return true;    // frame consumed, transaction completed by the worker
```
This is deliberately placed in the *worker*, not in `performTransaction`, because
`nvXeCopyRun` already releases the surface and calls `signalTransactionInterrupt`
(`:3210-3228`). So while the daemon owns the panel, WindowServer's frames are queued,
dropped and completed exactly as today - WindowServer never stalls or times out, and the
panel is never touched by the internal path. If `gXeAsyncCopy` were 0 (inline copy), ACQUIRE
refuses rather than risk a transaction that returns success without completion.

**PRESENT** - the body of `nvXeFlipNow` (`:3306-3362`), refactored so it does not need a
`NVDisplayPipe`/`IOService*`/head (see section 8). Steps:
1. `lookupSurface(gNVSVRoot, surfaceID, ownerTask)` (`:2143-2144`, `:2294` pattern);
2. validate: `getPixelFormat() == 0x42475241`, one plane, `W/H == plane W/H`,
   `P == planeStride*64`, `P >= 4W`, `H*P <= md->getLength()`, pages `<= 4224`;
3. resolve pages (`md->prepare()` / `getPhysicalSegment(..., kIOMemoryMapperNone)` /
   `complete()`, exactly as `:3330-3338`);
4. if `flags & WAIT_IDLE`: poll `xgFlipQuery` for GT idle (bounded by `timeoutUs`, default 25 ms)
   - this is the in-kernel fence available with no new ABI: it means every request that could
   have written the surface has completed (the K9 ordering point, `:3384-3402`);
5. `xgFlipInit(bytes, 3, ...)` once (fixed slot size; a geometry change forces RELEASE+ACQUIRE),
   then `xgFlipMap(slot, phys, npages, bytes)`;
6. clflush the frame through a cached read-only map of the surface (3-entry ring) when
   `gXeFlipClflush`;
7. arm `PLANE_SURF_1_p = (uint32_t)ggtt[slot]`, wait `FRMCOUNT` change (`nvXeWaitLatch`);
8. rotate the retained surfaces: the surface three presents ago is retired and its ID is
   returned. The daemon may only rewrite a surface after it has seen that ID (or after
   `RELEASE`). Two surfaces are retained by the kext (`:3351-3353`), so a 3-deep daemon ring is
   the safe minimum.

**RELEASE** - two modes:
* graceful (default): clears `gXgPanelTask` and releases the retained surfaces, but **leave
  `PLANE_SURF` pointing at the last external frame**. The next internal transaction repaints the
  panel (its first action is `nvXeFlipHome`/`home` + copy or a fresh arm), so the panel never
  flashes the boot console image, and a daemon crash leaves the last frame on screen instead of a
  black or boot-console panel.
* `flags & 1` (home): restore `PLANE_SURF = gXgPanelOrigSurf` (captured at ACQUIRE) and latch wait
  (`:3292-3302`), then `xgFlipUnmap` every slot. Used for deterministic teardown/tests.

Either way the GGTT slots stay reserved until the plane no longer scans them; the sketch unlinks
PTEs on home and defers `xg_flip_unmap` until after the latch.

### 3.4 How it avoids racing the WindowServer producer - the three concrete rules

1. **Single-owner token, bound to the connection.** `gXgPanelTask` is set only by ACQUIRE, held
   for the lifetime of the `XGDR` client connection, and cleared by RELEASE, `clientClose`,
   `clientDied` and `free()` (`:283-290` already has the closeAll hook; add `xgPanelKill`). A second
   connection's ACQUIRE gets `XG_PANEL_E_BUSY`. So there can never be two external producers.
2. **The internal producer is gated at the only place it arms the plane.** `xeCopyNow` returns
   immediately in external mode; therefore neither the copy (which only writes the framebuffer)
   nor `nvXeFlipNow` (which writes `PLANE_SURF`) runs. WindowServer keeps submitting; its frames
   are consumed and completed.
3. **The plane register is only touched under the panel lock, and the lock is also taken by
   home/release.** `nvXeFlipHome`/`nvXeFlipNow` are already serialized in practice by
   `performTransaction` per pipe; the new path adds `gXgPanelLock` (IOLock) around
   acquire/present/release/home so a release cannot race a present. The remaining race is
   XeGfxIntelFB's one-shot `curDdb` (section 5.4) and is handled by disabling the hw cursor while
   an external producer is active (or boot-arg `-xeintelfbnohwc`).

There is no "shared present queue" mode and none is needed: on this hardware the panel has one
framebuffer and one accelerator, and cross-producer interleaving would tear. The alternative
("WindowServer frames between daemon frames") is not worth the complexity.

### 3.5 Why not a new `IOUserClient` on XeGfxIntelFB

It is a viable second option and the report keeps it as a fallback, but it needs: its own
`newUserClient`/`externalMethod`, its own IOSurface private-class shims and `IOSurfaceRoot`
lookup, its own copy of the GGTT calls and MMIO map, its own retention ring, and it would be
destroyed/recreated if the framebuffer is torn down for a WindowServer restart or if APV's
framebuffer takes the display. The accelerator has all of that already and survives those events.

---

## 4. How the daemon hands over the Reims output

### 4.1 The two candidate routes, judged against the code

**Route (b) - an IOSurface on the XeGfx Metal device.** This is the realistic one.

* Only IOSurface-backed textures are usable here. A plain
  `[device newTextureWithDescriptor:]` allocates a private NVK image
  (`plugin/NVMTLDevice.m:908-956`, `nvmtl_vk_image_create_typed`) and returns a texture whose
  memory is not associated with anything the display path can name. The IOSurface entry point
  `-newTextureWithDescriptor:iosurface:plane:` (`:1045-1053`) goes through
  `nvmtl_surface_image_create` (`:990-1043`), which binds the surface's own memory
  (`nvmtl_vk_surface_share_on()` / `nvmtl_vk_surface_host_on()`, `:993`, `:1015`). So the daemon
  must create **IOSurface-backed** textures - which is exactly what route (b) needs.
  The entry point is `-newTextureWithDescriptor:iosurface:plane:`, and the per-surface texture cache
  (`nvmtlNewSurfaceTexture:...`, `plugin/NVMTLDevice.m:1053-1070`) reuses one texture per
  (surfaceID, plane, size, format). `copyIOSurfaceSharedTextureProperties:` (`:1833-1855`) computes
  the IOSurface properties for a texture descriptor with `IOSurfaceAlignProperty`, so a daemon can
  create the IOSurface itself with the panel's pitch and hand the same descriptor to Metal.
* For a non-NVIDIA accelerator the plugin renders **into the surface's own pages** when host
  import is available: `nvmtl_vk_surface_host_on()` returns true only for `vendor != 0x10de`
  (`plugin/nvmtl_vk.c:6741-6751`) and the texture is imported as a VkBuffer over the IOSurface's
  mapping (`nvmtl_vk_surface_host_import`, `:6752-6770`, called from
  `plugin/NVMTLObjects.m:1296-1305`). The GPU therefore writes the same memory the Intel plane
  will scan - zero copy.
* If host import is unavailable, the plugin falls back to an eager CPU copy-out after every GPU
  write into the surface (`nvmtlSurfaceOutDirtied:` -> `nvmtl_vk_image_read` into
  `IOSurfaceGetBaseAddressOfPlane`, `plugin/NVMTLObjects.m:1383-1425`), which also ends with the
  pixels in the surface's pages. Slower, but the contract is unchanged.
* `nvmtl_gpu_headless()` (`plugin/nvmtl_vk.c:2097-2105`) forces `surface_share_on()` off for
  AMD/Intel, i.e. there is no "VRAM copy that must be paged off" on this device. That removes the
  one big coherency hazard that would otherwise exist (route (b) would then have to force a
  page-off before the flip, as the NVIDIA path does via `nvAccelSurfScanoutSync:2737` and
  `nvAccelSurfVram:2269`).
* The kext can already flip *arbitrary IOSurface pages*: that is literally what `nvXeFlipNow`
  does (`:3330-3353`), and the accelerator already resolves IOSurfaces by ID with
  `IOSurfaceRoot::lookupSurface(id, task)` (`:2143-2144`, `:2294`).

**Route (a) - copy into a pinned buffer that the kext flips.** Feasible but strictly worse:
* It costs a full-frame copy per frame. The existing copy path measures this:
  `debug.nvaccel_iop_copy_us` / `_max` (`:1480`, `:3197`) - **[HW]** read the numbers, but at
  2560x1600 that is 16.4 MB/frame, and the E16 code comments already treat the copy as the slow
  path it is trying to leave behind (`:3254-3258`).
* It needs a second buffer ring *plus* the GGTT mapping, and either the kext allocates the buffer
  (`IOBufferMemoryDescriptor`, as the hw cursor does at `intelfb.cpp:248`) and copies into it from
  the IOSurface, or the daemon hands a Mach address range and the kext builds an
  `IOMemoryDescriptor::withAddressRange` - in which case it is not really a copy, but the kext
  must keep that descriptor prepared for as long as the slot is scanned (pinning lifetime becomes
  an explicit kext responsibility, unlike the IOSurface route where the surface's own wiring does
  it). This is the one variant worth keeping if the Metal plugin turns out not to support
  rendering into a daemon-created IOSurface.
* No advantage in validation or teardown.

**Verdict**: implement (b). Keep (a) as a fallback behind the same present ABI: a `surfaceID` of 0
plus a daemon-registered buffer is future work, and the ABI's `flags` field has room for it.

### 4.2 What the daemon must supply, and what the kext must validate

Daemon side (userspace, no kext change):

1. `XG_PANEL_INFO` -> `{width, height, pitch}` of the live plane. **The daemon must not guess the
   pitch**: it has to equal `PLANE_STRIDE * 64`.
2. Create **3** IOSurfaces: `kIOSurfaceWidth/Height`, `kIOSurfaceBytesPerElement 4`,
   `kIOSurfaceBytesPerRow = pitch`, `kIOSurfaceAllocSize = pitch*height`,
   `kIOSurfacePixelFormat = 'BGRA'` (0x42475241), single plane, not compressed.
3. One `MTLTextureDescriptor` (2D, `BGRA8Unorm`, `usage = renderTarget | shaderRead`) per surface,
   `[device newTextureWithDescriptor:d iosurface:surf plane:0]` on the **XeGfx Metal device**
   (the `NVMTLDriver` device; `MTLCopyAllDevices` lists it while the XeGfxAccel user client /
   accelerator is loaded).
4. Render the Reims frame into it, commit, and **guarantee completion** before PRESENT:
   `waitUntilCompleted` on the command buffer, or an `MTLSharedEvent` signalled at the end plus a
   wait, or `IOSurfaceLock(surf, kIOSurfaceLockReadOnly)`/`Unlock` after the command buffer
   completes (which is also what flushes the CPU caches on the copy-out path). The kext cannot see
   Reims' GPU work otherwise; `flags & WAIT_IDLE` (GT idle) is only a safety net, not a
   per-frame fence.
5. `XG_PANEL_ACQUIRE`; then per frame `XG_PANEL_PRESENT{surfaceID, seq}`; reuse a surface only
   after it has been returned as `retiredSurfaceID`; on exit `XG_PANEL_RELEASE`.

Kext side - validation is the union of what the code already does plus ownership:

| Check | Code to reuse |
|---|---|
| surface exists **in the calling task** | `IOSurfaceRoot::lookupSurface(root, id, task)` (`:2294`) |
| format `'BGRA'`, one plane | `:3412`; add `IOSurfaceGetPlaneCount == 1` |
| `W/H == PLANE_SIZE+1`, `P == (PLANE_STRIDE&0x7ff)*64`, `P >= 4W`, `P & 3 == 0` | `:3311-3313`, `:3412` |
| plane enabled + linear | `:3313` |
| `md != null`, `md->getLength() >= P*H`, `md->prepare(kIODirectionNone)` ok | `:3330` |
| page list complete, `<= 4224` pages, each 4K-aligned | `:3331-3343` |
| slot map succeeded (`xgFlipMap`) | `:3344` |
| the caller owns the panel (ACQUIRE) | new |
| the surface is not being presented by another connection | new (owner token) |

Pinning: the kext `retain()`s the IOSurface (front + previous) exactly as the internal flip does
(`:3351-3353`), so the pages stay alive across the two frames the slot can still be scanned. It
does **not** own the surface's contents and must never write to them. The daemon must not free the
surface, change its geometry, or write it while it is front/previous.

### 4.3 How IOSurface coherency works out on this device

Three cases, all ending with the frame in the surface's pages:

1. *host import on* (default for Intel, `:6741-6751`): the GPU writes the pages directly. The GPU
   sees them through the buffer's GGTT mapping; the display engine reads the same physical memory.
   The kext's `clflush` before arming (`:3348`) is the belt-and-braces for any CPU-cache alias.
2. *host import off*: the plugin copies out with `vkCmdCopyImageToBuffer` into, or with
   `nvmtl_vk_image_read` to, the surface's mapping, then `IOSurfaceUnlock` moves the seed and
   flushes. The daemon must have waited for the command buffer.
3. *route (a) fallback*: the kext or the daemon copies; the producer is responsible for the flush
   (kext does `nvXeIopClflush`).

**[HW]** verify which of 1/2 is active on the E16 (the plugin logs
`"item 7: IOSurface textures ..."`, `"vk: IOSurface copies go straight to the surface's pages"`,
`"surface-out -> dirty, no copy"`).

---

## 5. Failure and teardown semantics

### 5.1 Matrix

| Event | What happens today | What must happen in external mode |
|---|---|---|
| Daemon exits / crashes | n/a | `clientClose`/`clientDied` -> `xgPanelKill(task)`: graceful RELEASE (owner cleared, retained surfaces released, plane left on the daemon's last frame), then `performTransaction`'s internal path resumes on WindowServer's next frame. No kext unload, no reset. |
| Daemon hangs mid-PRESENT | n/a | PRESENT is bounded: the GT-idle wait by `timeoutUs`, the latch wait by 25 ms. It cannot hold the panel lock forever; RELEASE from `clientDied` waits for the lock at most one present. **[HW]** confirm `clientDied` fires for a SIGKILLed daemon before its task dies (it does for IOKit clients in practice). |
| Second daemon tries ACQUIRE | n/a | `XG_PANEL_E_BUSY`; existing provider unaffected. |
| GPU (GT) reset / hang | The internal flip path does not handle it; `xgFlipQuery` returns `-ENODEV` if i915 is gone | PRESENT's idle query fails -> refuse and (on 3 consecutive failures) auto-RELEASE(home) so the plane stops scanning memory whose pages the daemon may free. The GGTT PTEs are not lost by a GT reset in the display engine's view, but a full reset may scratch GGTT - the next PRESENT re-maps before arming, so it self-heals; the panel may show garbage for one frame. A reset *while* the external frame is scanned cannot be detected without a notification hook (XeGfx core has none) - see 7.14. |
| WindowServer restart | The family re-creates the display pipe; `NVDisplayPipe::free` homes the plane if a flip was live (`:1405-1411`) | The external present path is pipe-free, so it survives. The owner token keeps WindowServer's frames dropped. WindowServer's accelerator connection is recreated; no re-registration of the panel is needed for the daemon. **[HW]** verify a `launchctl kickstart -k system/com.apple.WindowServer` leaves the daemon's frame on the panel. |
| Panel modeset | None exists (no NDRV, i915 display off) | N/A. If `PLANE_SIZE/STRIDE` ever change, PRESENT's geometry check fails; the daemon must re-INFO and re-create its surfaces (RELEASE/ACQUIRE because slot size is fixed). |
| Display sleep / lid close | Not handled anywhere; the firmware mode is re-adopted at boot only | On wake, re-read the plane registers; if `PLANE_CTL` is off or different, refuse and home. The daemon must treat every resume as a geometry change until INFO proves otherwise. **[HW]** test sleep/wake - the whole E16 stack is currently untested there. |
| `debug.nvaccel_xe_flip` toggled while external | n/a | External mode does not depend on it: PRESENT uses the same primitives but its own state, and the drop gate runs before the internal flip branch. Toggling it affects only the internal path. |
| kext unload | XeGfxAccel `stop` (`:1117-1120`) calls `IOGraphicsAccelerator2::stop`; XeGfx core refuses to unload after stage 1 (`xg_kext.cpp:_stop`) | The user client is terminated first, so `clientClose` releases the panel. Do not unload the accelerator with an external owner that cannot be reached; the plane would keep scanning that surface's pages until the next reboot or repaint. |

### 5.2 Safe rollback path

1. Daemon: `XG_PANEL_RELEASE{flags=home}` (or just exit and let `clientDied` do graceful).
2. Kext: under `gXgPanelLock`: restore `PLANE_SURF` to `gXgPanelOrigSurf` (wait latch),
   `xgFlipUnmap(slot, bytes)` for every reserved slot, release `gXgFlip*` surfaces, clear
   owner token. `gXeFlipLive = ~0` so the internal path's first frame does a normal
   arm/copy.
3. WindowServer: nothing to do - its next `performTransaction` now reaches the internal worker,
   which (with `gXeFlip`) arms a fresh slot or copies, exactly as before the handoff.
4. If the daemon is gone and WindowServer has no frames (static desktop), the panel keeps the
   last external or internal frame; it will not go black because the plane always points at
   valid, retained memory.

### 5.3 Teardown ordering constraints (why the order matters)

* `PLANE_SURF` must be re-pointed **before** the slot's PTEs are unmapped or the surfaces are
  released; otherwise the display engine scans freed pages (visible corruption or a hung
  display). Hence: home -> latch wait -> unmap -> release.
* `gXeFlipOrigSurf` is captured on the first arm (`:3326`). If the internal flip was live at
  ACQUIRE time, the "original" surface is already a slot, not the boot framebuffer. RELEASE(home)
  must therefore home to the *current* boot-framebuffer value, which means the new path should keep
  its own `gXgPanelOrigSurf` captured at ACQUIRE - not reuse `gXeFlipOrigSurf`. This is a
  correctness detail for the patch.
* The daemon must be told which surface is retired *before* the kext can release it; the present
  return value is that handshake. If the daemon exits without consuming it, `clientDied` releases
  everything and the surfaces die with the process (the kext's retains are the only thing keeping
  them alive, so it must drop them before the task's IOSurface is reaped - it does, in `free()`).

### 5.4 The two narrow races that remain (and the cheap mitigations)

1. **XeGfxIntelFB's one-shot cursor DDB update.** `curDdb()` re-writes `PLANE_SURF` with the value
   it read (`intelfb.cpp:265-267`) and waits two frames. If a PRESENT arms between that read and
   write, the plane goes back to the old surface until the next arm. Mitigation: run the daemon
   with `-xeintelfbnohwc` (already honoured at `intelfb.cpp:236`) or set a property from the
   accelerator so `setCursorImage` skips `curDdb` while an external owner is set (6 lines, see 8.3).
   Probability is low (one call at the first cursor image after login), but it is a permanent
   clobber if it lands.
2. **The internal path's own home between ACQUIRE and the first PRESENT.** Between ACQUIRE and
   PRESENT no frame is armed; if the internal path had a live flip, `nvXeFlipHome` could run from
   `xeCopyNow` - but `xeCopyNow` returns at the drop gate before reaching it, so no. Confirm by
   watching `debug.nvaccel_xe_flip_home`: it should stay constant while the panel is owned.

### 5.5 Hardening gaps in the existing flip code that the new path inherits

1. `nvXeFlipHome` does **not** call `xgFlipUnmap`, so after a home the GGTT slots' PTEs still point
   at pages that the released IOSurface may give back (`:3292-3302`). Harmless while the plane is
   homed, but a stale PTE is a latent write-after-free if anything ever arms that slot without
   re-mapping. The new RELEASE must unmap.
2. `static unsigned long long phys[4224]` (`:3332`) is a global, not a per-call stack buffer: it
   is not reentrant. Today only the single copy worker uses it; the external path must take
   `gXgPanelLock` around page collection (or move it into the call frame - it is 33 KB of stack,
   better to allocate a per-owner array).
3. Slot size is fixed once reserved (`:3315-3317` refuses a different size). Fine for a fixed panel,
   but a geometry change requires `xgFlipUnmap` + release + re-init.
4. `gXeFlipGgtt[8]` / `XG_FLIP_MAX_SLOTS 8` (`shim/include/xg_i915.h:57`) - the daemon needs 3;
   no growth needed.
5. The IOMMU/PTE encoding uses `I915_CACHE_NONE`; if the daemon's surface were later put in
   "VRAM" (the family's fake vidmem) the pages still work, but the frame must be the system-memory
   copy the plugin wrote - which is what the IOSurface is.

---

## 6. What breaks when AppleParavirtGPU takes over Metal from XeGfx's Metal driver

### 6.1 What the APV kext actually is (static read of the 25G241 x86_64 binary)

Extracted image: `e16-work/apv/com.apple.driver.AppleParavirtGPU`, disassembly
`e16-work/apv/apv.dis` (23469 lines). It is not just a Metal device - it carries a complete
IOAcceleratorFamily2 display path:

| Object | Evidence |
|---|---|
| `AppleParavirtAccelerator` (IOGraphicsAccelerator2) | class/meta-class symbols, `apv.dis` |
| `AppleParavirtDisplayMachine` / `AppleParavirtDisplayPipe` / `AppleParavirtDisplayPipeFence` | symbols; `AppleParavirtDisplayPipe::submitTransaction(IOAccelDisplayPipeTransaction2*)` @ `0x148a3e24`, `::validateTransaction` @ `0x148a3a9c`, `::isTransactionComplete` @ `0x148a4324` |
| `AppleParavirtFramebuffer` (IOFramebuffer) | `::setupMMIO` @ `0x1489d602`, `::getApertureRange(int)` @ `0x1489dc2c`, `::getFramebufferMemoryDescriptor` @ `0x1489dc5e`, `::setDisplayPipe(AppleParavirtDisplayPipe*,uint)` |
| its own Metal plugin (separate gpusw bundle) | string `com.apple.gpusw.AppleParavirtGPU` |
| paravirtual device protocol | `AppleParavirtChannel`, `AppleParavirtCommandQueue/Allocator`, `AppleParavirtPageTable`, `AppleParavirtShared(UserClient)`, `AppleParavirtResourceHeap*`, `AppleParavirtSegmentResourceList`, `AppleParavirtVidMemory`, `AppleParavirtSysMemory` |
| it matches QEMU's `apple-gfx-pci` (vendor/device `106b:eeee`, BAR0 16 KiB, BAR2 EFI framebuffer window) | `k20-fake-pci/README-EN.md` (Reims device model), `E16-ReimsMMIOBridge/host/README.md` |

`submitTransaction` does **not** copy pixels: it allocates a FIFO command
(`AppleParavirtCommandAllocator::getCommandBytes(0x24)` = 36 bytes, `apv.dis:14474-14560`) and
writes the display id, the **scanout surface's device address**, and its pitch into it
(`movl %eax,(%r14); movl %ecx,0x4(%r14); movl %r15d,0x8(%r14)` at `0x148a3f37..0x148a3f3e`). The
host (Reims) is therefore told *which guest memory to scan out* - the host is the authority on the
display surface in the APV architecture.

### 6.2 Two topologies

```
T1 (not the goal): XeGfxIntelFB keeps the panel, APV adds a second Metal device
  WindowServer's display = Intel panel -> its accelerator is XeGfxAccel -> WindowServer composites
  on XeGfx's Metal device. APV's Metal device exists for apps only, and APV's own display pipe has
  nothing to drive. The desktop reaches the panel through the *existing* internal path; Reims is
  not in the picture. Nothing in this report is used.

T2 (the goal): APV is WindowServer's display + Metal, Reims produces the frames,
    XeGfx owns the eDP plane

  WindowServer/apps --- Metal (APV gpusw bundle) ---> AppleParavirtGPU   (guest driver)
          ^                                                  |
          | IOAccelDisplayPipe2 transaction                  | 36-byte display FIFO command
          | (APV's own paravirtual framebuffer)              | (display id, surface addr, pitch)
          |                                                  v
  XeGfxAccel ('XGDR' sel 5) <--- present(surfaceID, seq) --- Reims daemon
          |                        +--- IOSurface 'BGRA' ---- (renders with Metal on
          | PLANE_SURF = GGTT slot                            the XeGfx Metal device)
          v
  Intel display engine  (firmware raster, untouched)
          |
          v
      eDP panel
```

T1 is what you get "for free" and it defeats the purpose; the project's plan (statements in
`e16-work/E16-ReimsMMIOBridge/README.md`: "Display output must be handed to the existing XeGfx panel
owner in coordination with its normal flip producer") is T2. In T2 WindowServer's display is the
APV paravirtual one, so **no CoreDisplay transactions reach XeGfxAccel at all** and the panel's
Intel plane is driven only by the new present path.

### 6.3 What breaks, what holds, what must be re-pointed

| Item | After APV takeover | Action |
|---|---|---|
| `NVDisplayPipe::performTransaction` on head 4 | **never called** (the display pipe belongs to APV). No internal producer, no `nvaccel_iop_ok_h4`, no vblank/copy worker traffic. | Nothing to do *if* the accelerator has no head 4. If a stale configuration does register head 4 (`debug.nvaccelfb=3`), the drop gate from 3.3 keeps it from touching the plane. |
| `isTransactionComplete`, `nvXeCopyQueue`, K9b (`nvSurfWaitReady`, `xgFlipQuery`) | **dead**: the K9b readiness is fed by the plugin's WindowServer-only marks (`nvSurfGpuEscape` refuses any process not named `WindowServer`, `nvrm-accel.cpp:2260-2268`) and by "WindowServer did not wait for this composite". | The producer's fence moves to the **daemon**: Reims must wait for its own Metal command buffer before PRESENT (and may use `flags & WAIT_IDLE` -> `xgFlipQuery` as an in-kernel safety net, unchanged code). |
| display mode / pitch authority | APV's framebuffer gets its modes from the **host** (`AppleParavirtFramebuffer` + display port count at BAR0+0x122c; the Reims README's table says control start reads it). Reims therefore chooses the guest's mode. | Reims must advertise **exactly the E16 raster**: `W/H = PLANE_SIZE+1`, pitch = `PLANE_STRIDE*64`, refresh from the transcoder timing. Read them from the new `XG_PANEL_INFO` (extend it with HTotal/VTotal/pixel clock from `0x60000/0x6000C`, or reuse XeGfxIntelFB's published `NVRMTiming`) **[HW]**. Otherwise the present's geometry check refuses and nothing shows. |
| panel framebuffer in IOKit | APV's `AppleParavirtFramebuffer` publishes a display; XeGfxIntelFB may still publish one on the Intel device -> WindowServer sees **two displays**. | In T2, either disable XeGfxIntelFB (`-xeintelfboff` boot-arg, `intelfb.cpp:329`) or accept it as a second, unused display. The daemon does not need it - but then the panel's EDID/timing source for Reims must come from the selector/plists instead of XeGfxIntelFB's AUX read **[HW]**. NMIntelFB likewise must not be installed. |
| XeGfx Metal device availability | stays: the NMX_XEGFX branch never withholds `MetalPluginName` (`fbm == nullptr`, `nvrm-accel.cpp:995-1010`), and the accelerator starts as long as `nmxgpu-claimed` is set (`accel/xe/Info.plist`). | None. Reims keeps rendering on it; apps too. |
| hardware cursor on the Intel pipe | If XeGfxIntelFB is disabled, nobody programs `CUR_CTL/CUR_BASE` (`intelfb.cpp:286-313`); the plane's cursor state is whatever the GOP left (off). If one wants a cursor, XeGfxIntelFB must stay loaded, or Reims must composite it into the frame. | Decide per topology; if XeGfxIntelFB stays, keep `-xeintelfbnohwc` while the daemon owns the panel (5.4). |
| the plane itself | untouched by APV: APV cannot program Intel's display engine. `PLANE_SURF/CTL/STRIDE/SIZE` remain as the firmware left them (XeGfxIntelFB only *reads* them). | The present path is the only writer - which is what we want. |
| the transaction completion APV needs | APV's `AppleParavirtDisplayPipe` completes transactions through its own fence (`AppleParavirtDisplayPipeFence`), resolved by the host's interrupt/acknowledgement. | Reims must complete APV's display transactions after its present latched (or immediately), so WindowServer never stalls. That is Reims' device-protocol job, not the kext's. |
| the 36-byte display command's surface address | refers to APV-allocated guest memory (the driver's resource heap), which the host would have to map. `E16-ReimsMMIOBridge/README.md` lists "pinned guest memory mappings for Apple-allocated pages" as still missing. | **Avoid it**: Reims renders into its **own** IOSurface (route (b)) and presents that; the guest surface named in the command is acknowledged but not scanned. APV's guest display pipe only needs its fence. **[HW]** confirm the APV driver tolerates this (no CRC/consistency check). |
| `debug.nvaccelfb` / `debug.nvaccel_iop` activation sequence | The current `xe-up.sh` enables `fb=3` + `iop=1` so WindowServer's transactions reach XeGfxAccel. In T2 that must **not** run. | The daemon's activation is just: load XeGfx + XeGfxAccel (Metal + Reims), do **not** set `nvaccelfb`/`nvaccel_iop`, then ACQUIRE (which must work without a registered head - see the correction below). |

### 6.4 Correction to the ACQUIRE gate for T2

Section 3.3 lists the producer-safety part of ACQUIRE (`gNvIop` + `gXeAsyncCopy`). Those exist only
to make the drop gate safe when a WindowServer producer is present. In T2 there is no producer, so
the gate must be conditional:

```c
bool internalProducer = gNvScanout && (gNvHeadsPiped & (1u << 4));   // a display pipe on the panel
if (internalProducer && !(gNvIop && gXeAsyncCopy)) return XG_PANEL_E_BUSY;  // cannot safely gate it
```

and the drop gate itself stays as in 3.3 (harmless when no transactions arrive). This is the only
change between the "XeGfx Metal is the producer" phase and the APV phase for the present path
itself - which is the point of putting it in the accelerator, pipe-free.

### 6.5 What still holds, summarised

Everything about the *panel* side is producer-agnostic and survives APV:
the plane must stay linear and XRGB8888 with the firmware raster; `PLANE_SURF` is a 32-bit GGTT
offset; slots are reserved below 4 GiB with uncached PTEs; a frame must be `'BGRA'` with
pitch == `PLANE_STRIDE*64`; a flip is one arm + a `FRMCOUNT` latch wait; ownership is a token; the
teardown is home -> unmap -> release. Only the *producer identity, its fence, and the mode
authority* change.

---

## 7. Uncertainties to verify on the physical E16

Each item: what is unknown, why it matters, the exact command/experiment. Run them on the E16 with
the current stack up (the activation script has completed, desktop visible), or in a throwaway boot
with a recovery EFI. `sudo` is required for reads that the daemon would also need.

**Check the installed accelerator's sysctl set first**: the K13 package and the current read tree do
not expose the same names (the K13 binary has `debug.nvaccel_xe_mark_only`, the read tree has
`debug.nvaccel_xe_k9`/`xe_idle_ms` and no `mark_only`). `sysctl -a | grep -E 'nvaccel|nmxaccel'`
lists what the loaded build actually answers; where a command below names a sysctl that returns
ENOENT, use the nearest equivalent from that list.

### 7.1 Which framebuffer really owns the panel, and at which head
`kmutil showloaded | grep -E 'XeGfxIntelFB|NMIntelFB|XeGfxAccel|XeGfx \('`
`ioreg -l -w0 -c IOFramebuffer | grep -E 'IOClass|IOFBDependentIndex|IOFBDependentID|NVRMTiming'`
`sysctl debug.nvaccel_heads_published debug.nvaccel_heads_registered debug.nvaccel_heads_piped`
Expect `16 16 16` (only bit 4 set) if XeGfxIntelFB is the panel. Anything else changes the
report's head assumption.

### 7.2 The live plane raster: W, H, pitch, stride units, format, tiling
`log show --last boot --predicate 'process == "kernel"' | grep -E 'scanout geometry for accel|NVRMTiming|EDID [0-9]+ B|refresh measured'`
`ioreg -l -w0 -c IOFramebuffer | grep -A2 -E 'NVRMTiming|IOFBDetailedTimings'`
`sysctl -w debug.nvaccel_mmio_addr=0x70180; sysctl -b debug.nvaccel_mmio_win | od -An -tx4 -v`
(the last prints 64 dwords from 0x70180: CTL, STRIDE, POS, SIZE, SURF ...; it needs `gXeMmio`
mapped, i.e. at least one copy/flip must have run, otherwise the mmio read returns ENOENT).
Record: enable bit, tiling bits 12:10, format bits 27:23, stride*64, W/H.
This decides whether the panel is 1920x1200 or 2560x1600 and whether the daemon's `P*h` fits the
`phys[4224]` page cap (16.5 MiB).

### 7.3 The GOP/boot surface and its GGTT entry (the rollback target)
`ioreg -r -n XeGfxResident -l -w0 | grep -E 'plane-surf-1-a|ggtt-pte-surf|boot-fb-size|pipe-a-lit|transconf-a|plane-ctl-1-a|plane-stride-1-a|plane-size-1-a'`
(these are `XeGfxProbe`/`XeGfxPost` properties set in `xg_kext.cpp:300-322`, `:375-390`).
Confirm `PLANE_SURF` reads a GGTT value around `0xff600000` (the E16 GOP base per
`intelfb.cpp:236-240`) and that `ggtt-pte-surf` still matches after i915 ran (stage 4's
`xg_display_check` already does this and fails the stage otherwise).

### 7.4 The GGTT slots the flip reserves, and that they do not collide
After a few flips:
`log show --last 5m --predicate 'process == "kernel"' | grep 'E16 zero-copy flip'`
(prints `N GGTT slots x bytes (first 0x...)`, `nvrm-accel.cpp:3324`).
Then compare `first` and `first + slots*bytes` against: the boot framebuffer's GGTT
(section 7.3) and the hardware-cursor pages at `0xfffa0000..0xfffac000`
(`XIFB_CUR_GGTT`, `intelfb.cpp:204`). **Requirement**: the slot range must not overlap either.
Also `sysctl debug.nvaccel_xe_flip_miss debug.nvaccel_xe_flip_fail` must stay 0 during this.

### 7.5 Whether the zero-copy flip is what the E16 runs today (vs the copy path)
`sysctl debug.nvaccel_xe_flip debug.nvaccel_xe_flips debug.nvaccel_xe_flip_miss debug.nvaccel_xe_flip_fail debug.nvaccel_xe_flip_home debug.nvaccel_xe_copy_queued debug.nvaccel_xe_copy_done debug.nvaccel_xe_copy_us debug.nvaccel_xe_copy_us_max`
Grow `debug.nvaccel_xe_flips` (64-bit counters; the read sysctl is READ-ONLY and the counters are
not zeroed). On a static desktop the counters freeze; move the mouse / scroll to make frames.
This is the baseline the external producer must match.

### 7.6 Copy cost (for the route (a) decision)
`sysctl debug.nvaccel_iop_copy_us debug.nvaccel_iop_copy_us_max debug.nvaccel_iop_vbl_wait_us debug.nvaccel_iop_vbl_hit debug.nvaccel_iop_vbl_miss`
With the flip off (`sysctl -w debug.nvaccel_xe_flip=0`), these are the per-frame copy costs at the
real W/H. Compare with the 6.9 ms frame period at 144 Hz / 16.7 ms at 60 Hz.

### 7.7 The plugin's IOSurface path on this device (route (b) viability)
`log show --last 5m --predicate 'process == "kernel"' | grep -E 'item 7: IOSurface textures|vk: IOSurface copies|surface host import|surface-out -> dirty|G13 surface-out'`
`sysctl -w debug.nvaccel_svdiag=5` then provoke a composite; `log show --last 1m | grep -iE 'surfvram|surfshare|surface'`
The decisive line is `vk: IOSurface copies go straight to the surface's pages` (GPU writes the
pages) vs `stage through a buffer` (CPU copy-out). Either is usable; the first is zero-copy, the
second needs a completion wait before PRESENT.

### 7.8 That a *userspace-created* IOSurface can be looked up by the kext for the daemon's task
Throwaway probe (compile locally into this study dir, run on the E16, no signature needed if run
from Terminal as the user): create an IOSurface (`'BGRA'`, W/H/pitch from 7.2), then call
`IOServiceOpen` on `NMXAccel` type `0x58474452` and a selector-5 `INFO` (before and after the
patch). Before the patch, INFO must return an error, not crash - proves the client plumbing.
After the patch, INFO must return the panel geometry and ACQUIRE must succeed with the daemon's
own task. Also verify the *negative* case: presenting WindowServer's surface ID from a *different*
task must fail with `XG_PANEL_E_SURFACE` (this decides whether the daemon can ever flip
WindowServer's surface directly, or must own the surface - section 6.3's "avoid it" row).

### 7.9 The exact latch latency of a PRESENT
After the patch: `sysctl debug.nvaccel_xe_flips` delta, plus the `latchedMs` returned per PRESENT,
plus `debug.nvaccel_iop_vbl_wait_us`. A present that regularly hits the 25 ms bound means the
plane is not latching (e.g. the write is not on the armed pipe, or PSR holds the panel).

### 7.10 Whether the accelerator's user client survives a WindowServer restart
`sysctl debug.nvaccel_xe_flips` (with the daemon presenting), then
`launchctl kickstart -k system/com.apple.WindowServer`, then watch the panel and the counter.
Also `log show --last 2m | grep -E 'XGDR|NMXAccel'`. Expected: PID changes, IXGDR connections
recreated, the panel keeps the daemon's last frame, flips keep incrementing.

### 7.11 Daemon crash / kill -9 teardown
With the daemon presenting a solid colour: `kill -9 <pid>`, then
`sysctl -w debug.nvaccel_mmio_addr=0x7019c; sysctl -b debug.nvaccel_mmio_win | od -An -tx4`
(the first dword is `PLANE_SURF`). Expected with the default graceful RELEASE: `PLANE_SURF` is
unchanged (still the slot) and the last frame stays; with `RELEASE{home}` it returns to
`gXgPanelOrigSurf`. Then `log show --last 1m | grep -iE 'xgPanel|XGDR'` for the auto-release line.

### 7.12 Sleep/wake and lid close
`pmset sleepnow` (or close the lid), wake, then re-run 7.2/7.3/7.5.
Questions: does the plane survive D3? Are `PLANE_SURF/CTL` still what they were? Do the GGTT PTEs
survive (does i915 restore the GGTT on resume)? Does the flip path still latch? This is currently
**untested for the whole E16 stack** - the report assumes sleep is hostile and RELEASE/ACQUIRE
after wake is mandatory **[HW]**.

### 7.13 GPU reset / hang recovery
There is no safe reset injection. Closest probes: `sysctl debug.xegfx_gt_freq` (read GT
state), and the GT health check `sysctl -w debug.xegfx_stage=4` (fails if wedged). If a hang is
induced (e.g. the existing wedge experiments), record whether the panel keeps scanning and whether
`xgFlipQuery` still answers (it has no sysctl; the kernel logs `"E16 K9b: core has no
xgFlipQuery"` once when the core refuses it). Needed to decide the auto-RELEASE rule in 5.1.

### 7.14 The window in which XeGfxIntelFB re-arms `PLANE_SURF` (the cursor race)
Boot with `-xeintelfbnohwc` vs without; with the daemon presenting, set the cursor image (move the
mouse to trigger a new cursor if the OS does) and check `debug.nvaccel_mmio_win` for `PLANE_SURF`
reverting to the boot FB. `log show --last boot | grep 'hw cursor'` shows whether `curDdb` ran.
If the race is real, the 6-line guard in 8.3 is required, not optional.

### 7.15 The APV takeover itself (T2)
`kmutil showloaded | grep -i paravirt`
`ioreg -l -w0 | grep -i -A3 AppleParavirt` (framebuffer/accelerator/display pipe objects)
`ioreg -c IOFramebuffer` count before/after enabling the fake `106b:eeee` device: 1 vs 2 displays.
`log show --last boot --predicate 'eventMessage CONTAINS[c] "Paravirt" OR process == "WindowServer"' | grep -iE 'display|accel|metal'`
Then a tiny Metal probe: enumerate `MTLCopyAllDevices()` and print each device's name/registry ID
so we know which device WindowServer/apps see; and `ioreg -l -w0 -c IOAccelerator | grep -E 'IOClass|MetalPluginName|IOGPUClass'`.
Questions: does WindowServer pick the APV display as the built-in/main display? Does it keep the
Intel one as a second display? Does macOS mirror by copying (display transmitter), and does that
path go through XeGfxAccel's `performTransaction` again (which would fight the daemon)?

### 7.16 The APV mode/EDID the host must advertise
From the daemon side: dump the APV display command(s) it decodes (the 0x24-byte command with
display id, surface address, pitch) and the mode the guest asks for; compare its pitch with the
Intel plane's `PLANE_STRIDE*64` from 7.2. Then check `ioreg -l -w0 | grep -i -A30 AppleParavirtFramebuffer`
for the published mode list/refresh. Mismatch -> the present geometry check refuses; the daemon
must choose its surface pitch from `XG_PANEL_INFO`, not from the APV mode.

### 7.17 APV display transaction completion timing
Measure how long APV's `isTransactionComplete` takes to go true after `submitTransaction`
(`AppleParavirtDisplayPipeFence`). If Reims completes it only after the Intel plane latches,
WindowServer's frame period = present latency; if it must complete earlier, the daemon needs a
second buffer and to complete the fence on submit. Instrument on the Reims side
(`E16-ReimsMMIOBridge/host`), not in Apple's kext.

### 7.18 `printf`-level evidence that frames really reach the glass
Use the existing capture tools rather than eyes only:
`sysctl -w debug.nvaccel_iop_cap_arm=1 debug.nvaccel_iop_cap_x=100 debug.nvaccel_iop_cap_y=100`
then `sysctl -b debug.nvaccel_iop_capbuf > /tmp/cap.raw` and view it as 384x384 BGRA. For the
external producer, the same capture is only produced by the copy path today
(`nvXeIopCapture`, `:1508-1518`); adding the same capture to the present path (3 lines) is the
cheapest way to prove pixels without a camera **[HW]**.

### 7.19 Whether the daemon can be non-root
The XGDR client is opened by any task that can `IOServiceOpen` `NMXAccel`; the DRM node open
(selector 2) needs device permissions, but present does not use DRM. `IOSurface` creation and
`MTLTexture` creation are unprivileged. Expected: the daemon needs root only for the Reims
device/BAR plumbing, not for the present. Verify by running the probe as a normal user: INFO and
ACQUIRE/PRESENT should work if the panel is already in external mode (or fail cleanly with
`E_BUSY`), and the probe must not need entitlements.

### 7.20 Whether `nvaccel_xe_flip` and the external path can be enabled at the same time
Set `debug.nvaccel_xe_flip=1`, then ACQUIRE and present. Expected: `xe_flips` stops growing,
`xe_flip_home` stays constant, no `flip MISS` log storm. This is the "drop gate" test in 3.3.

---

## 8. Patch sketch (unified diff text, **not applied**, not compiled)

Minimal change set: **one new header + four hunks in `nvrm-accel.cpp` + two small hunks in
`kexts/XeGfxIntelFB/intelfb.cpp`. No change to XeGfx core (`xg_i915_flip.c`, `xg_kext.cpp`) and no
change to NMIntelFB.** The core already exposes everything the path needs
(`xgFlipInit`/`xgFlipMap`/`xgFlipUnmap`/`xgFlipQuery`).

Line numbers are those of the read tree and the hunks are written so they *should* apply with
`patch -p1`; they have not been built. Anything marked `/* ... */` is elided unchanged code.

### 8.1 New file: `kexts/XeGfxAccel/xg_panel_abi.h`

The daemon carries a byte-identical copy. This is the "argument struct" of the interface.

```c
/* XeGfx external-producer panel ABI (E16 K14).  One producer at a time: a connection ACQUIREs the
 * panel, PRESENTs IOSurfaces ('BGRA', pitch == PLANE_STRIDE*64, panel W/H), RELEASEs it. */
#pragma once
#include <stdint.h>

#define XG_PANEL_ABI_VERSION 2u
#define XG_PANEL_USERCLIENT_TYPE 0x58474452u   /* 'XGDR' on NMXAccel, selector 5 */
#define XG_PANEL_SELECTOR 5

enum {                          /* scalarInput[0] / struct cmd */
    XG_PANEL_INFO    = 0,
    XG_PANEL_ACQUIRE = 1,
    XG_PANEL_PRESENT = 2,
    XG_PANEL_RELEASE = 3,
};

enum {                          /* status */
    XG_PANEL_OK         = 0,
    XG_PANEL_E_VERSION  = -1,
    XG_PANEL_E_ARG      = -2,
    XG_PANEL_E_BUSY     = -3,
    XG_PANEL_E_NOPANEL  = -4,
    XG_PANEL_E_NOTOWNER = -5,
    XG_PANEL_E_SURFACE  = -6,
    XG_PANEL_E_FORMAT   = -7,
    XG_PANEL_E_GEOM     = -8,
    XG_PANEL_E_PAGES    = -9,
    XG_PANEL_E_NOGGTT   = -10,
    XG_PANEL_E_NOTREADY = -11,
};

enum {                          /* PRESENT flags */
    XG_PANEL_F_WAIT_IDLE  = 1u << 0,   /* wait for GT idle before arming (default on)      */
    XG_PANEL_F_NO_CLFLUSH = 1u << 1,   /* the producer already flushed the frame           */
};
enum {                          /* ACQUIRE flags / RELEASE flags share bit 0 */
    XG_PANEL_F_REL_HOME   = 1u << 0,   /* RELEASE: point the plane home immediately        */
};

struct xg_panel_info {
    uint32_t version, flags;        /* flags: 1 owner-active, 2 plane-ok, 4 slots-reserved */
    uint32_t pipe, width, height, pitch, strideUnits;
    uint32_t planeSurf, planeCtl;
    uint32_t slots, slotBytes, ownerPid, latchedMs;
    uint32_t htotal, vtotal, pclkHz; /* for the host's synthesized APV mode (section 6)   */
    uint64_t slotGgtt0;
    uint64_t flips, misses, failures;
};
struct xg_panel_present {
    uint32_t version, flags, surfaceID, seq;
    uint32_t timeoutUs, retiredSurfaceID, latched, latchedMs;
    int32_t  status;
};
```

Scalar encoding (what the sketch implements, matching `externalMethod`'s scalar-only style):

```
INFO    in : ver, cmd
        out: status, flags, width, height, pitch, pipe, planeSurf, planeCtl,
             slots, slotBytes, slotGgtt0, ownerPid, flips, misses, failures
ACQUIRE in : ver, cmd, flags
        out: status, width, height, pitch, bytes
PRESENT in : ver, cmd, surfaceID, flags, seq, timeoutUs
        out: status, seq, retiredSurfaceID, latched, latchedMs
RELEASE in : ver, cmd, flags
        out: status, flips
```

### 8.2 `kexts/XeGfxAccel/accel/nvrm-accel.cpp`

Hunk 1 - include and forward declaration (near the other forward declarations, `:42-47`):

```diff
@@ -40,6 +40,10 @@
 static bool               nvAccelFlipTo(IOAccelResource2 *res);
 static bool               nvAccelCopyToScanout(IOAccelResource2 *res);
 void                      nvAccelSwapProbe(IOAccelResource2 *a1, IOAccelResource2 *a2);
 bool                      nvAccelResHasContent(IOAccelResource2 *res);
 static void               nvAccelWriteStamp(int index, unsigned int value);
+#ifdef NMX_XEGFX
+struct IOExternalMethodArguments;
+static IOReturn           xgPanelControl(struct IOExternalMethodArguments *a, task_t task);
+static void               xgPanelKill(task_t task);
+#endif
```

Hunk 2 - the IOSurface shim needs one accessor and the class needs the task/owner plumbing
(`:1368-1376` and `:254-290`):

```diff
@@ class IOSurface
     unsigned long long  getHeight() const;
     unsigned long long  getBytesPerRow() const;
     unsigned int        getPixelFormat() const;
     unsigned int        getSurfaceID() const;
+    unsigned int        getPlaneCount() const;      /* IOSurface::getPlaneCount() */
 };
@@ class IOAccelXeGfxDRMClient
     IOLock *fOpenLock = nullptr;
     int     fOpenMinor[kXgMaxOpen] = {};
     int     fOpenPid[kXgMaxOpen] = {};
+    task_t  fOwnerTask = TASK_NULL;   /* this connection's task, for IOSurfaceRoot::lookupSurface */
...
     bool initWithTask(task_t t, void *sid, UInt32 type) APPLE_KEXT_OVERRIDE {
         if (!IOUserClient::initWithTask(t, sid, type)) return false;
+        if (t != TASK_NULL) { task_reference(t); fOwnerTask = t; }
         fOpenLock = IOLockAlloc();
         return fOpenLock != nullptr;
     }
     void free() APPLE_KEXT_OVERRIDE {
         closeAll();
+        xgPanelKill(fOwnerTask);
+        if (fOwnerTask != TASK_NULL) { task_deallocate(fOwnerTask); fOwnerTask = TASK_NULL; }
         if (fOpenLock) { IOLockFree(fOpenLock); fOpenLock = nullptr; }
         IOUserClient::free();
     }
     IOReturn clientClose() APPLE_KEXT_OVERRIDE { closeAll(); terminate(); return kIOReturnSuccess; }
     IOReturn externalMethod(uint32_t sel, IOExternalMethodArguments *a, IOExternalMethodDispatch *,
                             OSObject *, void *) APPLE_KEXT_OVERRIDE {
+#ifdef NMX_XEGFX
+        // E16 K14: the external producer's panel control (info / acquire / present / release)
+        if (sel == 5) return xgPanelControl(a, fOwnerTask);
+#endif
         // selector 2 (kind 0 card / 1 render, DRM minor) -> (instance minor, errno)
```

Hunk 3 - extract the MMIO mapping so the pipe-free path can map BAR0 without a vblank call
(`:1644-1652`):

```diff
@@ static bool nvXeWaitVblank(IOPCIDevice *pci, unsigned h)
 {
     if (!pci) return false;
-    if (!gXeMmio) gXeMmio = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0, kIOMapInhibitCache);
-    if (!gXeMmio || gXeMmio->getLength() < 0x80000) return false;
-    volatile uint32_t *r = (volatile uint32_t *)gXeMmio->getVirtualAddress();
+    volatile uint32_t *r = nvXeMapMmio(pci);
+    if (!r) return false;
     int p = gIopVblPipe;
```
with, inserted just before it:

```c
+/* BAR0 once, for the display registers.  nvXeWaitVblank used to be the only caller; the external
+ * producer's present path maps the same window without needing a pipe. */
+static volatile uint32_t *nvXeMapMmio(IOPCIDevice *pci)
+{
+    if (!gXeMmio && pci) gXeMmio = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0, kIOMapInhibitCache);
+    if (!gXeMmio || gXeMmio->getLength() < 0x80000) return nullptr;
+    return (volatile uint32_t *)gXeMmio->getVirtualAddress();
+}
```

Hunk 4 - **the core of the patch**: refactor `nvXeFlipNow` so its body is pipe-free, then add the
panel state machine. Insert after `nvXeFlipNow` (`:3362`) and before the K9b section.

```diff
@@ static bool nvXeFlipNow(NVDisplayPipe *pipe, unsigned h, IOSurface *s, unsigned long long P, const volatile unsigned int *src)
-static bool nvXeFlipNow(NVDisplayPipe *pipe, unsigned h, IOSurface *s, unsigned long long P, const volatile unsigned int *src)
+static bool nvXeFlipArm(unsigned h, IOSurface *s, unsigned long long P, const volatile unsigned int *src)
 {
     volatile uint32_t *r = nvXeRegs();
     const int p = gIopVblPipe;
@@
     gXeFlipLive = slot; gXeFlipNext = slot + 1;
     OSAddAtomic64(1, latched ? &gCntXeFlips : &gCntXeFlipFail);
-    (void)pipe;
     return true;
 }
+/* the internal producer's entry: the pipe was discovered by nvXeWaitVblank before the call */
+static bool nvXeFlipNow(NVDisplayPipe *pipe, unsigned h, IOSurface *s, unsigned long long P, const volatile unsigned int *src)
+{ (void)pipe; return nvXeFlipArm(h, s, P, src); }
+
+// ---- E16 K14: external producer (Reims) panel ownership and present --------------------------
+// One connection at a time owns the Intel plane.  While it does, NVDisplayPipe::xeCopyNow returns
+// at once (the async worker completes WindowServer's transaction without touching the panel), so
+// there is exactly one writer of PLANE_SURF.  The present itself is nvXeFlipArm with the surface
+// resolved from an IOSurface ID in the caller's task and its pages pinned by retention.
+enum { kXgPanelRing = 3, kXgPanelMaxPages = 4224 };
+struct XgPanelSurf { IOSurface *s; IOMemoryMap *map; };
+static task_t  gXgPanelTask = TASK_NULL;
+static int     gXgPanelPid, gXgPanelPipe = -1, gXgPanelLatchedMs;
+static IOLock *gXgPanelLock;
+static XgPanelSurf gXgPanelRing[kXgPanelRing];
+static unsigned gXgPanelNext;
+static uint32_t gXgPanelOrigSurf;
+static unsigned gXgPanelSlots, gXgPanelNextSlot, gXgPanelLive = ~0u;
+static unsigned long long gXgPanelBytes, gXgPanelGgtt[XG_FLIP_MAX_SLOTS], *gXgPanelPhys;
+static SInt64 gXgPanelFlips, gXgPanelMiss, gXgPanelFail;
+
+static IOLock *xgPanelLock(void)
+{
+    if (!gXgPanelLock) { IOLock *l = IOLockAlloc();
+        if (l && !OSCompareAndSwapPtr(nullptr, l, (void *volatile *)&gXgPanelLock)) IOLockFree(l); }
+    return gXgPanelLock;
+}
+static bool xgPanelOwned(void) { return gXgPanelTask != TASK_NULL; }
+/* XeGfxIntelFB reads this to skip its one-shot cursor-DDB PLANE_SURF re-arm (see intelfb.cpp hunk) */
+static void xgPanelPublishOwner(bool on)
+{
+    if (!NVAccel::gAccel) return;
+    if (on) NVAccel::gAccel->setProperty("XeGfxPanelExternal", kOSBooleanTrue);
+    else    NVAccel::gAccel->removeProperty("XeGfxPanelExternal");
+}
+static IOSurface *xgPanelLookup(task_t task, uint32_t sid)
+{
+    if (!sid || task == TASK_NULL) return nullptr;
+    if (!gNVSVRoot) {                      /* same lookup nvAccelSurfVram does, :2294 */
+        OSDictionary *m = IOService::serviceMatching("IOSurfaceRoot");
+        if (m) { gNVSVRoot = IOService::waitForMatchingService(m, 5ULL * 1000 * 1000 * 1000); m->release(); }
+        if (!gNVSVRoot) return nullptr;
+    }
+    return (IOSurface *)_ZN13IOSurfaceRoot13lookupSurfaceEjP4task(gNVSVRoot, sid, task);
+}
+/* the plane the producer is allowed to own: first enabled transcoder whose plane is linear and on */
+static int xgPanelFindPipe(volatile uint32_t *r)
+{
+    if (gXgPanelPipe >= 0) return gXgPanelPipe;
+    for (int p = 0; p < 4; p++) {
+        const uint32_t conf = r[(0x70008 + p * 0x1000) / 4], ctl = r[(0x70180 + p * 0x1000) / 4];
+        const uint32_t size = r[(0x70190 + p * 0x1000) / 4], stride = r[(0x70188 + p * 0x1000) / 4] & 0x7ff;
+        if ((conf & 0x80000000u) && (ctl & 0x80000000u) && !(ctl & (7u << 10)) && size && stride)
+            return gXgPanelPipe = p;
+    }
+    return -1;
+}
+static int xgPanelValidate(IOSurface *s, unsigned W, unsigned H, unsigned P)
+{
+    if (s->getPixelFormat() != 0x42475241u || s->getPlaneCount() != 1) return XG_PANEL_E_FORMAT;
+    if ((unsigned)s->getWidth() != W || (unsigned)s->getHeight() != H) return XG_PANEL_E_GEOM;
+    if ((unsigned)s->getBytesPerRow() != P) return XG_PANEL_E_GEOM;   /* 64-byte units on the plane */
+    return XG_PANEL_OK;
+}
+/* the frame's own pages -> the slot's PTEs; the same steps as the internal flip, but the surface is
+ * resolved from the caller and its mapping is cached for the clflush. */
+static int xgPanelMap(task_t task, uint32_t sid, bool clflush, volatile unsigned int **srcOut)
+{
+    NVAccel *a = NVAccel::gAccel;
+    volatile uint32_t *r = a ? nvXeMapMmio(a->fPCI) : nullptr;
+    const int p = r ? xgPanelFindPipe(r) : -1;
+    if (!r || p < 0) return XG_PANEL_E_NOPANEL;
+    const uint32_t ctl = r[(0x70180 + p * 0x1000) / 4];
+    const unsigned W = (r[(0x70190 + p * 0x1000) / 4] & 0xffff) + 1;
+    const unsigned H = ((r[(0x70190 + p * 0x1000) / 4] >> 16) & 0xffff) + 1;
+    const unsigned P = (r[(0x70188 + p * 0x1000) / 4] & 0x7ff) * 64u;
+    if (!(ctl & 0x80000000u) || (ctl & (7u << 10)) || !W || !H || !P) return XG_PANEL_E_NOPANEL;
+    IOSurface *s = xgPanelLookup(task, sid);
+    if (!s) return XG_PANEL_E_SURFACE;
+    int rc = xgPanelValidate(s, W, H, P);
+    if (rc) { ((OSObject *)s)->release(); return rc; }
+    const unsigned long long bytes = (unsigned long long)P * H;
+    IOMemoryDescriptor *md = s->getMemoryDescriptor();
+    if (!md || md->getLength() < bytes || md->prepare(kIODirectionNone) != kIOReturnSuccess) {
+        ((OSObject *)s)->release(); return XG_PANEL_E_FORMAT;
+    }
+    const unsigned need = (unsigned)((bytes + 4095ull) >> 12);
+    if (need > kXgPanelMaxPages) { md->complete(kIODirectionNone); ((OSObject *)s)->release(); return XG_PANEL_E_PAGES; }
+    unsigned npages = 0; IOByteCount off = 0;
+    while (off < (IOByteCount)bytes && npages < need) {
+        IOByteCount segLen = 0;
+        addr64_t pa = md->getPhysicalSegment(off, &segLen, kIOMemoryMapperNone);
+        if (!pa || !segLen) break;
+        for (IOByteCount q = 0; q < segLen && npages < need && off + q < (IOByteCount)bytes; q += 4096)
+            gXgPanelPhys[npages++] = ((unsigned long long)pa + q) & ~0xfffull;
+        off += segLen;
+    }
+    md->complete(kIODirectionNone);
+    if (npages < need) { ((OSObject *)s)->release(); return XG_PANEL_E_PAGES; }
+    /* the clflush needs a CPU view; cache one per ring entry, like iopMapSurface does for the copy */
+    if (clflush && srcOut) {
+        unsigned i = gXgPanelNext % kXgPanelRing;
+        if (gXgPanelRing[i].map) { gXgPanelRing[i].map->release(); gXgPanelRing[i].map = nullptr; }
+        gXgPanelRing[i].map = md->map(kIOMapReadOnly);
+        *srcOut = gXgPanelRing[i].map ? (volatile unsigned int *)gXgPanelRing[i].map->getVirtualAddress() : nullptr;
+    }
+    if (!gXgPanelSlots || gXgPanelBytes != bytes) {
+        if (gXgPanelSlots) { ((OSObject *)s)->release(); return XG_PANEL_E_GEOM; }  /* fixed slot size */
+        unsigned n = 0;
+        if (nvXeResidentCall("xgFlipInit", (void *)(uintptr_t)bytes, (void *)(uintptr_t)3, gXgPanelGgtt, &n) != kIOReturnSuccess || !n) {
+            gXgPanelFail++; ((OSObject *)s)->release(); return XG_PANEL_E_NOGGTT;
+        }
+        gXgPanelSlots = n; gXgPanelBytes = bytes; gXgPanelNextSlot = 0;
+        ALOG("iop: panel producer: %u GGTT slots x %llu bytes (first 0x%llx)", n, bytes, gXgPanelGgtt[0]);
+    }
+    unsigned slot = gXgPanelNextSlot % gXgPanelSlots;
+    for (unsigned i = 0; i < gXgPanelSlots; i++) { slot = (gXgPanelNextSlot + i) % gXgPanelSlots; if (slot != gXgPanelLive) break; }
+    if (slot == gXgPanelLive) { ((OSObject *)s)->release(); return XG_PANEL_E_BUSY; }
+    if (nvXeResidentCall("xgFlipMap", (void *)(uintptr_t)slot, gXgPanelPhys,
+                         (void *)(uintptr_t)npages, (void *)(uintptr_t)bytes) != kIOReturnSuccess) {
+        gXgPanelFail++; ((OSObject *)s)->release(); return XG_PANEL_E_NOGGTT;
+    }
+    if (clflush && srcOut && *srcOut) nvXeIopClflush(*srcOut, (size_t)bytes);
+    const uint64_t t0 = mach_absolute_time();
+    r[(0x7019c + p * 0x1000) / 4] = (uint32_t)gXgPanelGgtt[slot];
+    const bool latched = nvXeWaitLatch(r, p);
+    gXgPanelLatchedMs = (int)(nvXeUs(t0) / 1000);
+    /* ring rotation: hand the oldest surface back as retired */
+    unsigned ri = gXgPanelNext % kXgPanelRing;
+    uint32_t retired = 0;
+    if (gXgPanelRing[ri].s) { retired = gXgPanelRing[ri].s->getSurfaceID(); ((OSObject *)gXgPanelRing[ri].s)->release(); }
+    (void)retired;                    /* the real code returns it as scalarOutput[2] */
+    gXgPanelRing[ri].s = s; ((OSObject *)s)->retain();       /* the caller's reference stays with it */
+    gXgPanelNext++;
+    gXgPanelLive = slot; gXgPanelNextSlot = slot + 1;
+    OSAddAtomic64(1, latched ? &gXgPanelFlips : &gXgPanelFail);
+    return latched ? XG_PANEL_OK : XG_PANEL_E_NOTREADY;      /* the retired id is packed in the caller */
+}
+static int xgPanelAcquire(task_t task, uint32_t flags)
+{
+    NVAccel *a = NVAccel::gAccel;
+    volatile uint32_t *r = a ? nvXeMapMmio(a->fPCI) : nullptr;
+    const int p = r ? xgPanelFindPipe(r) : -1;
+    if (!r || p < 0) return XG_PANEL_E_NOPANEL;
+    /* if WindowServer's producer is live it must be safely droppable: the worker completes its
+     * transactions, which needs the async path; without it, refuse rather than stall WindowServer */
+    const bool internal = gNvScanout && (gNvHeadsPiped & (1u << 4));
+    if (internal && (!gNvIop || !gXeAsyncCopy)) return XG_PANEL_E_BUSY;
+    IOLock *l = xgPanelLock(); if (!l) return XG_PANEL_E_ARG;
+    IOLockLock(l);
+    if (gXgPanelTask != TASK_NULL && gXgPanelTask != task) { IOLockUnlock(l); return XG_PANEL_E_BUSY; }
+    if (nvXeFlipIsLive()) nvXeFlipHome();                    /* settle any internal flip first */
+    gXgPanelOrigSurf = r[(0x7019c + p * 0x1000) / 4];        /* home target captured HERE, not gXeFlipOrigSurf */
+    if (!gXgPanelPhys) gXgPanelPhys = (unsigned long long *)IOMalloc(kXgPanelMaxPages * sizeof(unsigned long long));
+    if (!gXgPanelPhys) { IOLockUnlock(l); return XG_PANEL_E_ARG; }
+    gXgPanelTask = task; gXgPanelPid = proc_selfpid(); gXgPanelPipe = p;
+    IOLockUnlock(l);
+    xgPanelPublishOwner(true);
+    ALOG("iop: panel producer ACQUIRED by pid %d: pipe %c, %u x %u pitch %u (orig SURF 0x%x)",
+         gXgPanelPid, 'A' + p, (r[(0x70190 + p * 0x1000) / 4] & 0xffff) + 1,
+         ((r[(0x70190 + p * 0x1000) / 4] >> 16) & 0xffff) + 1, (r[(0x70188 + p * 0x1000) / 4] & 0x7ff) * 64u, gXgPanelOrigSurf);
+    return XG_PANEL_OK;
+}
+static int xgPanelRelease(bool home)
+{
+    IOLock *l = xgPanelLock(); if (!l) return XG_PANEL_E_ARG;
+    IOLockLock(l);
+    if (gXgPanelTask == TASK_NULL) { IOLockUnlock(l); return XG_PANEL_OK; }
+    for (unsigned i = 0; i < kXgPanelRing; i++) {
+        if (gXgPanelRing[i].map) { gXgPanelRing[i].map->release(); gXgPanelRing[i].map = nullptr; }
+        if (gXgPanelRing[i].s) { ((OSObject *)gXgPanelRing[i].s)->release(); gXgPanelRing[i].s = nullptr; }
+    }
+    if (home) {
+        volatile uint32_t *r = nvXeRegs();
+        const int p = gXgPanelPipe;
+        if (r && p >= 0 && gXgPanelOrigSurf) {
+            r[(0x7019c + p * 0x1000) / 4] = gXgPanelOrigSurf;
+            (void)nvXeWaitLatch(r, p);
+            for (unsigned i = 0; i < gXgPanelSlots; i++)
+                (void)nvXeResidentCall("xgFlipUnmap", (void *)(uintptr_t)i, (void *)(uintptr_t)gXgPanelBytes, nullptr, nullptr);
+            gXgPanelLive = ~0u;
+        }
+    }
+    ALOG("iop: panel producer RELEASED (pid %d, %lld flips)", gXgPanelPid, (long long)gXgPanelFlips);
+    gXgPanelTask = TASK_NULL; gXgPanelPid = 0; gXgPanelPipe = -1;
+    IOLockUnlock(l);
+    xgPanelPublishOwner(false);
+    return XG_PANEL_OK;
+}
+static void xgPanelKill(task_t task)
+{
+    if (task != TASK_NULL && gXgPanelTask == task) (void)xgPanelRelease(false);   /* graceful: keep the last frame */
+}
+static IOReturn xgPanelControl(IOExternalMethodArguments *a, task_t task)
+{
+    if (!a || !a->scalarInput || !a->scalarOutput || a->scalarInputCount < 1 ||
+        a->scalarInputCount > 8 || a->scalarOutputCount < 1 || a->scalarOutputCount > 16)
+        return kIOReturnBadArgument;
+    const uint64_t *in = a->scalarInput; uint64_t *out = a->scalarOutput;
+    const uint32_t cmd = (uint32_t)in[0];
+    const uint32_t ver = a->scalarInputCount > 1 ? (uint32_t)in[1] : XG_PANEL_ABI_VERSION;
+    if (ver != XG_PANEL_ABI_VERSION) { out[0] = (uint64_t)(int64_t)XG_PANEL_E_VERSION; return kIOReturnSuccess; }
+    NVAccel *acc = NVAccel::gAccel;
+    volatile uint32_t *r = acc ? nvXeMapMmio(acc->fPCI) : nullptr;
+    if (cmd == XG_PANEL_INFO) {
+        const int p = r ? xgPanelFindPipe(r) : -1;
+        int32_t st = (r && p >= 0) ? XG_PANEL_OK : XG_PANEL_E_NOPANEL;
+        out[0] = (uint64_t)(int64_t)st;
+        if (st == XG_PANEL_OK && a->scalarOutputCount >= 15) {
+            const uint32_t ctl = r[(0x70180 + p * 0x1000) / 4], su = r[(0x70188 + p * 0x1000) / 4] & 0x7ff;
+            out[1]  = (xgPanelOwned() ? 1u : 0u) | 2u | (gXgPanelSlots ? 4u : 0u);
+            out[2]  = (r[(0x70190 + p * 0x1000) / 4] & 0xffff) + 1;
+            out[3]  = ((r[(0x70190 + p * 0x1000) / 4] >> 16) & 0xffff) + 1;
+            out[4]  = su * 64u;  out[5] = p;  out[6] = r[(0x7019c + p * 0x1000) / 4];  out[7] = ctl;
+            out[8]  = gXgPanelSlots; out[9] = gXgPanelBytes; out[10] = gXgPanelGgtt[0];
+            out[11] = gXgPanelPid; out[12] = (uint64_t)gXgPanelFlips;
+            out[13] = (uint64_t)gXgPanelMiss; out[14] = (uint64_t)gXgPanelFail;
+        }
+        return kIOReturnSuccess;
+    }
+    if (cmd == XG_PANEL_ACQUIRE) {
+        const int32_t st = xgPanelAcquire(task, a->scalarInputCount > 2 ? (uint32_t)in[2] : 0);
+        out[0] = (uint64_t)(int64_t)st;
+        if (st == XG_PANEL_OK && r && gXgPanelPipe >= 0 && a->scalarOutputCount >= 5) {
+            out[1] = (r[(0x70190 + gXgPanelPipe * 0x1000) / 4] & 0xffff) + 1;
+            out[2] = ((r[(0x70190 + gXgPanelPipe * 0x1000) / 4] >> 16) & 0xffff) + 1;
+            out[3] = (r[(0x70188 + gXgPanelPipe * 0x1000) / 4] & 0x7ff) * 64u;
+            out[4] = (uint64_t)out[1] * out[3];
+        }
+        return kIOReturnSuccess;
+    }
+    IOLock *l = xgPanelLock();
+    if (l) IOLockLock(l);
+    if (cmd == XG_PANEL_PRESENT) {
+        if (gXgPanelTask != task) { out[0] = (uint64_t)(int64_t)XG_PANEL_E_NOTOWNER; if (l) IOLockUnlock(l); return kIOReturnSuccess; }
+        volatile unsigned int *src = nullptr;
+        const uint32_t sid = a->scalarInputCount > 2 ? (uint32_t)in[2] : 0, fl = a->scalarInputCount > 3 ? (uint32_t)in[3] : 0;
+        const int32_t st = xgPanelMap(task, sid, !(fl & XG_PANEL_F_NO_CLFLUSH), &src);
+        out[0] = (uint64_t)(int64_t)st;
+        if (a->scalarOutputCount >= 5) { out[1] = a->scalarInputCount > 4 ? in[4] : 0; out[2] = 0;
+                                          out[3] = st == XG_PANEL_OK; out[4] = (uint64_t)gXgPanelLatchedMs; }
+        if (l) IOLockUnlock(l);
+        return kIOReturnSuccess;
+    }
+    if (cmd == XG_PANEL_RELEASE) {
+        if (l) IOLockUnlock(l);   /* xgPanelRelease takes it */
+        const int32_t st = xgPanelRelease(a->scalarInputCount > 2 && (in[2] & XG_PANEL_F_REL_HOME));
+        out[0] = (uint64_t)(int64_t)st;
+        if (a->scalarOutputCount >= 2) out[1] = (uint64_t)gXgPanelFlips;
+        return kIOReturnSuccess;
+    }
+    if (l) IOLockUnlock(l);
+    out[0] = (uint64_t)(int64_t)XG_PANEL_E_ARG;
+    return kIOReturnSuccess;
+}
```

(The sketch elides the exact "retired surface ID" plumbing and the GT-idle wait to keep the diff
readable; both are 5-10 lines each, patterned on `:3351-3353` and `:3394-3400`. `gXgPanelLatchedMs`
must be computed with a `mach_absolute_time()` pair around `nvXeWaitLatch`.)

Hunk 5 - **the drop gate**, the only change to the existing producer (`xeCopyNow`, `:3404`):

```diff
@@ bool NVDisplayPipe::xeCopyNow(IOService *fb, unsigned head, IOSurface *s)
 {
     NVAccel *a = NVAccel::gAccel;
     if (!a || !fb || !s) return false;
+#ifdef NMX_XEGFX
+    // E16 K14: an external producer owns the Intel plane.  Drop this frame and return success: the
+    // caller (nvXeCopyRun) releases the surface and signals the transaction's completion, so
+    // WindowServer never stalls and the internal flip/copy never arms the plane.
+    if (head == 4 && xgPanelOwned()) return true;
+#endif
     nvXeWaitFrame(s->getSurfaceID());   // K9b: surface mark OR GT idle, bounded
```

Two lines of context require `xgPanelOwned()` to be visible before `:3404`; the declaration must
move up with the other forward declarations in Hunk 1
(`static bool xgPanelOwned(void);`), which the sketch assumes.

### 8.3 `kexts/XeGfxIntelFB/intelfb.cpp` (hardening: the one-shot cursor DDB re-arm)

```diff
@@ class XeGfxIntelFramebuffer : public IONDRVFramebuffer {
     uint32_t fW = 0, fH = 0, fRowBytes = 0;
     uint32_t fTiming[13] = {}; bool fTimingValid = false;   // 0.9.4: NVRMTiming words, also the detailed timing
+    IOService *fGPU = nullptr;   // E16 K14: XeGfxAccel publishes panel-ownership here
...
+    // A Reims flip owns PLANE_SURF while XeGfxAccel says so; curDdb() re-arms the value it read and
+    // would clobber that flip.  Skip the DDB update then (the cursor stays off, which is what the
+    // external producer wants anyway).
+    bool panelExternal() const { return fGPU && fGPU->getProperty("XeGfxPanelExternal") == kOSBooleanTrue; }
@@ IOReturn setCursorImage(void *img) override {
-        if (!fCurReady) return IONDRVFramebuffer::setCursorImage(img);
+        if (!fCurReady || panelExternal()) return IONDRVFramebuffer::setCursorImage(img);
@@ bool start(IOService *provider) override {
     xifbGuardCount();
+    fGPU = provider;
```

Note: if the external producer is expected to be permanent (the APV topology), the simpler and
equally valid choice is to boot with `-xeintelfbnohwc` (already supported at `intelfb.cpp:236`) and
skip this hunk. The hunk exists because the "WindowServer via XeGfx Metal + daemon present"
transitional phase has the cursor live.

### 8.4 `kexts/NMIntelFB/intelfb.cpp` - **no change on the E16**

NMIntelFB is not installed on the E16 (section 1.1), and if it were, the present path is identical:
it publishes a CPU-only scanout (`r.phys = 0`, `r.kva = fSurfMap`,
`kexts/NMIntelFB/intelfb.cpp:493-505`), `NVDisplayPipe::initFramebufferResource` correctly refuses
to build a vidmem over it (`nvrm-accel.cpp:1152-1162`), and the plane registers it reads are the
same ones the present path uses. The only reason to touch it would be a machine whose panel is
owned by a *different* GPU from XeGfxAccel, which is not this project.

### 8.5 What the patch deliberately does not do

* No change to XeGfx core: no new GGTT ABI, no slot resize at runtime (a geometry change does
  RELEASE/ACQUIRE). Slots are the existing `xgFlipInit(Map|Unmap)`.
* No change to the WindowServer producer's *contract*: while the external producer owns the panel,
  WindowServer's frames are consumed and completed, not shown. There is no interleaving mode.
* No modeset: the plane's `W/H/pitch/tiling` stay the firmware's; the producer adapts to them.
* No new user client type: selector 5 on the existing `'XGDR'` client.
* No kernel-side fence object: PRESENT/latch + `retiredSurfaceID` is the whole fence; GT-idle is
  optional belt-and-braces.

---

## 9. Evidence index (file:line in `/Users/taqieallah/src/xe-e16/wtl`)

| Evidence | Where |
|---|---|
| WindowServer producer entry point | `kexts/XeGfxAccel/accel/nvrm-accel.cpp:1674` (`performTransaction`) |
| head-4 dispatch into the copy worker | `nvrm-accel.cpp:1718` |
| copy target / boot framebuffer descriptor | `nvrm-accel.cpp:762-780`, `:783-816`, target used at `:1744-1753` |
| copy loop + vblank + clflush | `nvrm-accel.cpp:1756-1768`, `:3431-3436` |
| worker and completion signalling | `nvrm-accel.cpp:3199-3228`, `:2515`, `:2597` |
| zero-copy flip | `nvrm-accel.cpp:3306-3362` (ARM at `:3349`, latch `:3350`) |
| flip home / capture of the original surface | `nvrm-accel.cpp:3292-3302`, `:3326` |
| plane validation (enable/linear/stride) | `nvrm-accel.cpp:3311-3313` |
| `'BGRA'` format checks | `nvrm-accel.cpp:1729-1733`, `:3410-3412` |
| page collection / retention | `nvrm-accel.cpp:3330-3353` |
| vblank poll + pipe discovery | `nvrm-accel.cpp:1644-1671` |
| clflush | `nvrm-accel.cpp:1503-1507` |
| MMIO map + read-only register window sysctl | `nvrm-accel.cpp:1542-1553` |
| `XeGfxResident` calls (`xgFlipInit/Map/Unmap/Query`) | `kexts/XeGfxAccel/accel/nvrm-accel.cpp:3272`, `shim/src/xnu/xg_kext.cpp:172-196` |
| GGTT slot reservation/PTE writes/unmap | `xkpi/src/i915/xg_i915_flip.c:39-76`, `:81-106`, `:110-125`; API `shim/include/xg_i915.h:57-64` |
| `'XGDR'` user client + selectors | `nvrm-accel.cpp:254-369` (selector 1 at `:338-352`, DRM ioctl at `:353-367`), `newUserClient` at `:828-846` |
| IOSurface private shims + `lookupSurface` | `nvrm-accel.cpp:1368-1376`, `:2143-2148`; used at `:2294` |
| surface completion marks (K9b producer side) | `nvrm-accel.cpp:1907-1969`, `:2260-2340`; plugin side `plugin/nvmtl_vk.c:2142-2170` |
| head 4 = the Intel panel / publication | `nvrm-accel.cpp:110-125`, `:457-520`, `:995-1010` |
| accelerator's scanout resource refusal for CPU-only panels | `nvrm-accel.cpp:1127-1186` |
| XeGfxIntelFB raster read + published timing | `kexts/XeGfxIntelFB/intelfb.cpp:364-378`, `:156-196`, `:389-392`, `:410-421` |
| XeGfxIntelFB cursor writes `PLANE_SURF` once | `intelfb.cpp:204`, `:213`, `:236-245`, `:265-267`, `:286-313` |
| XeGfxIntelFB `getPixelInformation` = XRGB8888 | `intelfb.cpp:410-421` |
| NMIntelFB plane registers / scanout ABI / VBL timer | `kexts/NMIntelFB/intelfb.cpp:100-110`, `:320-350`, `:493-505`, `:130-153` |
| plugin: IOSurface textures, host import, copy-out | `plugin/NVMTLDevice.m:1045`, `plugin/nvmtl_vk.c:6741-6770`, `:2097-2105`, `plugin/NVMTLObjects.m:1295-1310`, `:1383-1425` |
| E16 runtime activation (sysctls used) | `e16-work/e16-k13/package/k13/xe-up.sh:78-113` (workspace, read-only) |
| APV display path symbols | `e16-work/apv/apv.dis:6598, 7143, 7165, 14196, 14474, 14782` |
| APV device model / Reims | `e16-work/E16-ReimsMMIOBridge/README.md`, `e16-work/E16-ReimsMMIOBridge/host/README.md`, `k20-fake-pci/README-EN.md` |

---

## 10. What could not be verified without the hardware

1. **The panel's actual mode/pitch** (1920x1200 vs 2560x1600, and whether `PLANE_STRIDE*64 == 4*W`).
   Everything about slot size, `phys[4224]` headroom and the daemon's IOSurface pitch depends on
   it. Commands: 7.2.
2. **Whether the E16 currently runs the copy path or the zero-copy flip**, and its cost. Commands:
   7.5, 7.6.
3. **Whether the flip's GGTT slots collide with the GOP framebuffer (`0xff600000`) or the hardware
   cursor pages (`0xfffa0000`)**. `xg_flip_init` relies on i915's reserved ranges plus
   `xg_i915_reserve_bootfb`; only the hardware can tell. Command: 7.4.
4. **Which IOSurface path the plugin takes on the XeGfx device** (GPU writes the pages vs CPU
   copy-out) and whether a daemon-created IOSurface is accepted by
   `-newTextureWithDescriptor:iosurface:plane:` with the panel's exact pitch (IOSurface pitch
   alignment rules may differ from 64 bytes for some descriptors). Commands: 7.7, 7.8.
5. **Whether `IOSurfaceRoot::lookupSurface(id, task)` accepts the daemon's task for a surface the
   daemon created** and rejects WindowServer's surface from another task - this decides whether the
   daemon must own the surface. Command: 7.8.
6. **Whether a PRESENT actually latches within the 25 ms bound** on the real pipe (PSR/panel self
   refresh, pipe selection, dc5/dc6 could leave the write un-latched). Command: 7.9.
7. **WindowServer restart survival** of the external present path. Command: 7.10.
8. **SIGKILL teardown** and whether `free()` runs early enough to drop the retained IOSurfaces
   before the task's surfaces are reaped. Command: 7.11.
9. **Sleep/wake** - wholly untested today; it may break the plane entirely, in which case the
   present path must refuse after wake. Command: 7.12.
10. **GPU reset** behaviour (no safe injection; flagged as a recovery-media experiment). 7.13.
11. **The cursor DDB race window** - whether `curDdb` ever runs after an external flip. 7.14.
12. **All of section 6**: which IOKit display WindowServer picks when both `AppleParavirtFramebuffer`
    and `XeGfxIntelFramebuffer` publish; whether APV's mode/EDID can be made to match the Intel
    raster; whether APV's display transactions can be completed by Reims after an Intel-plane
    present. Commands: 7.15-7.17. Static reading of the APV binary establishes the *shape* of its
    display path (36-byte FIFO command naming a guest surface + pitch) but not its runtime
    interaction with a second framebuffer/accelerator, which no amount of local disassembly can
    settle.
13. **Whether the present path needs root** and whether an unprivileged daemon can open the XGDR
    client. 7.19.

If any of these contradicts the design, the parts that are most likely to need revision are: the
64-byte pitch equality (may need the present path to reprogram `PLANE_STRIDE`/`PLANE_SIZE` together
with `PLANE_SURF`, which the current code deliberately never does), the GGTT-slot range
(`[0x80000000,0x100000000)` vs. the E16's actual GGTT layout), and the APV mode authority in
section 6.3.

