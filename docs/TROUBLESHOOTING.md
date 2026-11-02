# Problems hit and how they were solved

| Symptom | Cause | Fix |
|---|---|---|
| Hard freeze right after `IOG flags` when the iGPU is visible | firmware-surface access on Display 14 through Apple's path | XeGfx stack bring-up order; isolated first by hiding PCI devices (`class-code=FFFFFFFF`) |
| AGDC 0x921 answered Unsupported → no frames | IOPresentment needs a link config | K5 + `NVRMTiming` from XeGfxIntelFB 0.9.3 |
| "No refresh rate option" | IOGraphics hides it for built-in 57.5–62.5 Hz panels | nothing to fix; measured 60 Hz |
| Console text inside icons, broken corners | stale memory / CCS fast clears | `INTEL_DEBUG=noccs,nofc` in nvrm610.conf; colours fixed by the macOS update |
| iconservicesagent on CPU | broke Settings glyphs | undone (`icons-cpu.sh`) |
| 100 ms waits + tearing with completion marks | per-surface pending bit starves on the copy path | zero-copy flip + K9b (surface-ready or GT idle) |
| `CORE BUILD FAILED` in `kpi_check.py` on the Mac | `kmutil` on arm64 only knows arm64 KPIs | skipped on arm64 (laptop `kmutil` checks it) |
| `install.sh` wiped perf gains | it reinstalled the stock plugin/conf | `fb-install.sh`, install.sh keeps nvrm610.conf |
| Homebrew "only supported on Apple Silicon" | Homebrew dropped Intel | cross-compile x86_64 from arm64 Homebrew |
| ArcXe B4 hang, `MI_MODE=0x1000` | nested-batch mode on by default | `E16-NBB` (did not cure B4, see ARCMTL-EXPERIMENT.md) |
| ArcMTL desktop black except the cursor | window uploads hit the B4.0 hang | `arc-mode.sh off` (from the Mac if the screen is black) |

## Recovery

- GPU stack misbehaving: `sudo sysctl debug.nvaccel_xe_flip=0`, `debug.nvaccel_surface_gpu_on=0` (live), or
  `full-install.sh --undo` and restart.
- Stuck in an ArcMTL boot: plug the stick into another Mac, `sudo bash /Volumes/1401/xegfx-e16/arc/arc-mode.sh off`.
- Kernel collection broken: boot with the previous OpenCore entry / safe mode, copy the backup
  `/Library/XeGfx-E16/*-backup-*/AuxiliaryKernelExtensions.kc` back.
