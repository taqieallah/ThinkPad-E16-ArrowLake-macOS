# The GPU stack and every E16 change

## Layers

```
 Apps / WindowServer (Metal)
        │  Metal.framework → MTLIOAccelDevice
 NVMTLDriver.bundle  (NullMoth plugin, WTL fork)  ── AIR → SPIR-V: libnvmtl_translate.dylib (Rust)
        │  Vulkan
 Mesa ANV (libvulkan_intel.dylib, NullMoth Darwin patches)
        │  DRM ioctls over IOKit
 XeGfx.kext (core)  = Linux i915 + FreeBSD LinuxKPI + XNU shim, GuC 70 firmware
 XeGfxAccel.kext    = NullMoth's NVAccel fork ("NMXAccel"): IOAccelerator2 family, display pipe, surfaces
 XeGfxAGDC.kext     = AGDC / IOPresentment link answers (K5 link config)
 XeGfxIntelFB.kext  = IONDRV-based framebuffer for the panel (timing, NVRMTiming, detailed timings)
        │
 Intel Arc 140T 8086:7D51 (Xe-LPG+ 12.74, Display 14)
```

The display engine is **not** reprogrammed by i915 (that route — ArrowWhatever patches 0011–0022, the HONOR
XeGfxDisplay attempt — was never finished by anyone). The firmware (GOP) mode stays up; XeGfxIntelFB describes it
to macOS and the accelerator puts WindowServer's frames on it, first by copying, now by pointing the plane at the
frame (zero-copy flip).

## Bring-up (scripts/xe-up.sh, v10)

Run after login (`sudo bash /Volumes/1401/xegfx-e16/xe-up.sh`, installs itself as a LaunchDaemon run):

1. `kmutil load` XeGfx core, `debug.xegfx_stage=7` (stages 5–7 must all report 1)
2. load XeGfxAccel, wait for `MetalPluginName` on NMXAccel
3. `debug.xegfx_agdc=1`, then `debug.xegfx_agdc_k5=1` (answers AGDC 0x921 from XeGfxIntelFB's `NVRMTiming`)
4. `nvaccelfb=3`, `nvaccel_iop=1`; v10: if the accelerator has K9b, `nvaccel_xe_flip=1` and
   `nvaccel_surface_gpu_on=1` (override with `XE_FLIP=0` / `XE_SURFGPU=0`)
5. one WindowServer restart, then 2 minutes of counters into the log (iop_ok, pipe counters, k5 link, shader cache)

Refuses to run when ArcXe owns the GPU (ArcMTL test boot).

## E16 changes (patches/wtlintelgfx-e16.diff on WTLIntelGfx ff64f83)

### XeGfx core
| Change | Why |
|---|---|
| `xg_i915_flip.c` + `xgFlipInit/Map/Unmap/Query` platform functions (ArrowWhatever 0008) | reserve GGTT slots below 4 GiB and point their PTEs at a frame's pages, for zero-copy scanout; `xgFlipQuery` = all engines idle |
| `xg_kext.cpp`: a failing stage no longer stops the stage loop | same as the HONOR binary patch at `0x243e5e` |
| `xg_i915_exec.c`: four `pci_dev_put()` removed | `xg_i915_find` takes no reference (HONOR binary patch) |
| FreeBSD `linux_idr.c`: no `sched_pin/unpin` in `idr_preload` (applied by build-core.sh) | malloc inside the critical section panicked (HONOR `0x6edf0`) |
| `tools/link.sh`, `kpi_split.py`, `kexport.py`: read the laptop's kernel collection (`KCABI_KC`), skip `kmutil`'s KPI check on arm64 | building on an Apple Silicon Mac |

### XeGfxAccel
| Change | Sysctls |
|---|---|
| XGDR user client selector 1: WindowServer completion marks (pending/ready per surface) | `nvaccel_surface_gpu_on`, `_marks`, `_waits`, `_timeouts` |
| Async panel copy worker (thread_call): composite wait → vblank → copy → `signalTransactionInterrupt` | `nvaccel_xe_async_copy`, `xe_copy_hold`, `xe_copy_*` |
| **Zero-copy flip**: frame pages → GGTT slot → `PLANE_SURF` (0x7019c + pipe·0x1000), clflush first, wait for the frame counter (0x70040) to latch, plane sent home to the firmware framebuffer on any fallback / pipe free | `nvaccel_xe_flip`, `xe_flip_clflush`, `xe_flips`, `xe_flip_miss`, `xe_flip_fail`, `xe_flip_home` |
| **K9b**: the flip worker waits for surface-ready **or** GT idle (`xgFlipQuery`), polled every 0.5 ms, bounded by `xe_idle_ms` (40) | `nvaccel_xe_k9`, `xe_idle_ms`, `xe_k9_free/mark/idle/forced`, `xe_k9_max_us` |

### Plugin (NVMTLDriver)
| Change | Why |
|---|---|
| On-disk `VkPipelineCache` per process (zep245/IrisXe b214) | WindowServer recompiled every pipeline each boot |
| Completion marks through XGDR when there is no NVK surface escape | lets WindowServer skip its per-composite wait (K9b) |
| Mipmapped tiled textures get their levels generated (`E16 mip path`) | CA icon / corner masks came out as one level |

### Translator
NullMoth v2.6.6 + `LlType::Half` arm (A-41).

### XeGfxIntelFB 0.9.4 (driver/kexts/XeGfxIntelFB)
- reads the panel timing from the EDID detailed timing or the transcoder (0x60000 / 0x6f000)
- publishes `NVRMTiming` (13 words: tag `0x4b350001`, pclk, hact/hss/hse/htot, vact/vss/vse/vtot, mHz, h+, v+)
- answers `getTimingInfoForDisplayMode` with a detailed timing for the native mode (min = max pixel clock);
  `-xeintelfbnodt` turns that off
- measured: 157.5 MHz, 1920×1200, total 2120×1238 → 60.01 Hz

## Userspace settings

`/Library/GPUBundles/nvmtl/nvrm610.conf`: `INTEL_DEBUG=noccs,nofc` (corner/edge corruption). `install.sh` keeps it.
