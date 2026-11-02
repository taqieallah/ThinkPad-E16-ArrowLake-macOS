# XeGfx driver source, E16 edition

This folder is the complete WTLIntelGfx source tree
([watchthelight-labs/WTLIntelGfx](https://github.com/watchthelight-labs/WTLIntelGfx) at
`ff64f8361a11a0995dae2cf5c4528752f388d5bb`, release 0.0.47) **with every E16 change applied**, exactly as built
for the ThinkPad E16 (Arc 140T `8086:7D51`). `../patches/wtlintelgfx-e16.diff` is the same change set as a diff.

| Folder | What | E16 changes |
|---|---|---|
| `xkpi/`, `shim/` | XeGfx core: Linux i915 on XNU through FreeBSD LinuxKPI | GGTT flip slots + GT-idle query (`xkpi/src/i915/xg_i915_flip.c`, `xg_kext.cpp` platform functions), stage loop keeps going on a failed stage, no `pci_dev_put` in `xg_i915_exec.c` |
| `kexts/XeGfxAccel/` | accelerator (NullMoth NVAccel fork) | completion marks (XGDR selector 1), async copy worker, zero-copy flip, K9b ordering |
| `kexts/XeGfxIntelFB/` | panel framebuffer | **0.9.4**: panel timing, `NVRMTiming`, detailed timings for the native mode |
| `kexts/XeGfxAGDC/` | AGDC / IOPresentment | unchanged (K5 link config is upstream) |
| `plugin/` | NVMTLDriver Metal plugin | on-disk pipeline cache, XGDR completion marks, mip path |
| `translator/` | AIR → SPIR-V (Rust) | `LlType::Half` arm |
| `tools/` | link checks | read the laptop's kernel collection (`KCABI_KC`), skip arm64 `kmutil` KPI check |

Not in this tree (fetched by the build): FreeBSD `sys` (sparse, `d2145e9b96448da34d3cfede24c509af6d830c92`) with the
`idr_preload` fix, drm-kmod `c16de0f9fa84f70b9551f69fde837a7f3a73c0e9`, GuC firmware `mtl_guc_70.bin`
(linux-firmware), kcabi, NVIDIA open-gpu-kernel-modules headers (615.78.08) for the accelerator.

Build: `../scripts/build-core.sh` (expects this tree at `~/src/xe-e16/wtl`), see `../docs/BUILD-AND-INSTALL.md`.
Licences per folder: `NOTICE` in this folder (BSD-2 / MIT / LGPL-3.0 / PolyForm Noncommercial 1.0.0).
