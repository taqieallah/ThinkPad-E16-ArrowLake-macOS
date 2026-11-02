# ThinkPad E16 Gen 3 · Core Ultra 7 255H (Arrow Lake) · macOS 26 Tahoe

Graphics acceleration on an **Intel Arc 140T iGPU (`8086:7D51`, Xe-LPG+ 12.74)** under macOS, plus everything
else that was needed to make this laptop a usable Hackintosh. The GPU driver is
[WTLIntelGfx](https://github.com/watchthelight-labs/WTLIntelGfx) 0.0.47 (Linux i915 on XNU through LinuxKPI,
NullMoth's Metal plugin and translator, Mesa ANV) with the E16 changes in this repository.

> Arabic summary / ملخص بالعربي: [docs/README-ar.md](docs/README-ar.md)

## Status (2026-11-02, macOS 26.x)

| Area | State |
|---|---|
| Boot, NVMe, keyboard, USB | Working (ACPI If→Scope patches, SSDT-PC02-OFF) |
| GPU acceleration (Metal on the iGPU) | **Working**: WindowServer composites on the GPU through XeGfx |
| Internal panel 1920×1200 | Working at a measured **60.01 Hz** (157.5 MHz, 2120×1238 total) |
| Zero-copy scanout (GGTT flip) | **Working**: frames scanned out of their own pages, 0 misses / 0 failures |
| K9b deferred ordering | **Working**: WindowServer no longer waits per frame, 0 forced, 0 timeouts |
| Desktop smoothness | Better than the copy path but **not yet 60 fps**; next step is a WindowServer profile |
| Icon / colour corruption | Fixed by the macOS update (+ `INTEL_DEBUG=noccs,nofc`) |
| Touchpad, battery, sound | Working (VoodooI2C chain, ECEnabler + SMCBatteryManager, AppleALC layout 11) |
| Wi-Fi (Intel BE201 `8086:7740`) | Working after the macOS update (AirportItlwm build) |
| Sleep / external displays | Not done (the driver does not own the display engine) |
| ArcMTL experiment | ArcXe runs commands and 3D on this GPU; desktop black, parked (see docs) |

## What is in here

```
patches/wtlintelgfx-e16.diff   every source change on top of WTLIntelGfx ff64f83 (core, accel, plugin, translator)
scripts/                       bring-up (xe-up.sh), build + install scripts used on the Mac and the laptop
scripts/0008-e16.patch         ArrowWhatever's GGTT flip-slot core patch, path-rewritten for this tree
scripts/arc/                   ArcMTL experiment: opt-in ArcXe, Mesa ANV cross-build, test + install
src/XeGfxIntelFB/              XeGfxIntelFB 0.9.4 (panel timing, NVRMTiming, detailed timings)
src/E16ConsoleRange/           small helper kext used during bring-up
src/probe/                     CVDisplayLink refresh probe
docs/                          how it works, how to build, what was measured, what failed
```

No Apple binaries, firmware, kernel collections or SMBIOS data are included.

## Read next

- [docs/HARDWARE-AND-OPENCORE.md](docs/HARDWARE-AND-OPENCORE.md): BIOS, ACPI patches, kexts, boot-args
- [docs/GPU-STACK.md](docs/GPU-STACK.md): how the XeGfx stack is put together and every E16 change
- [docs/BUILD-AND-INSTALL.md](docs/BUILD-AND-INSTALL.md): building on an Apple Silicon Mac, installing on the laptop
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): refresh rate, copy path, zero-copy flip, K9b, numbers
- [docs/ARCMTL-EXPERIMENT.md](docs/ARCMTL-EXPERIMENT.md): the ArcMTL route, what passed, what hangs
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): problems hit along the way and their fixes

## Credits

watchthelight-labs (WTLIntelGfx, WTLLegionOpenCore, WTLLegionCpuPower), NullMoth Systems (nvidia-macos-driver:
plugin, accelerator, translator lineage), ArrowWhatever (GGTT flip slots, K9 deferred flip), the HONOR 255H
port notes, longurara (ArcMTL), FreeBSD drm-kmod / LinuxKPI, Linux i915, Mesa, Acidanthera.

## License

See [NOTICE](NOTICE). Scripts and docs written here are BSD 2-Clause. Patches keep the license of the files they
modify (BSD-2 / MIT / LGPL-3.0 / PolyForm Noncommercial 1.0.0 for the NullMoth-derived plugin and accelerator).
