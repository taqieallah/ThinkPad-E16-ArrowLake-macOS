# Performance work

## Refresh rate

macOS showed no refresh-rate choice. That is expected: IOGraphics hides the choice for a built-in panel between
57.5 and 62.5 Hz. `CVDisplayLink` (src/probe/dlprobe.c) measures **60 Hz**; the panel timing is 157.5 MHz,
2120×1238 → 60.01 Hz. Pacing was never the problem.

## Where the time went

1. **Copy path.** Each frame (1920×1200×4 ≈ 9.2 MB) was copied by the CPU into the firmware framebuffer, after
   waiting for vblank (8–10 ms) on WindowServer's thread.
2. **WindowServer waiting for the GPU.** `commitAndWaitUntilSubmitted` → `waitUntilCompleted` for every composite.
3. **Pipeline compiles.** Mesa's shader cache is off in WindowServer (uid/euid differ), so every boot recompiled.

## What was done, in order

| Step | Result |
|---|---|
| On-disk pipeline cache + translator fixes (build-perf) | WindowServer CPU down, first-run stalls only once |
| Completion marks (XGDR selector 1) with `surface_gpu_on=1` on the **copy** path | 100 ms timeouts + glitches: the per-surface pending bit never clears while WindowServer keeps writing the surface |
| Async copy worker, `hold=1` | fewer glitches, much slower |
| **Zero-copy flip** (ArrowWhatever 0008 core + own accelerator side) | `xe_flips` 2516, `flip_miss` 0, `flip_fail` 0; glitches mostly gone |
| **K9b** (surface-ready **or** GT idle, ≤ 40 ms) with `surface_gpu_on=1` | 1279 frames: free 419 / mark 161 / idle 699, **forced 0, timeouts 0**, longest wait 16.8 ms |

Measured smoothness after flip + K9b: **less than 10 % better** than before. So the remaining cost is not on the
display side.

## Measured on 2026-11-02 (macOS 26.7.1)

- `sample WindowServer`: main thread 87 % idle, composite ≈ 1.5 ms, no GPU wait on the main thread → not the bottleneck.
- `fps-check.sh bench` (scripts/bench/ca_bench.m, a fixed Core Animation sweep): **43–53 fps** with flip + K9b + hold=1,
  0 lost frames.
- `flip_hold=0` (newest wins): ~35 fps with dropped frames. `flip_hold=2` (one in flight + one queued): ~55 fps, peaks
  62–63, but visible stutter/tearing because WindowServer reuses a buffer that is still being scanned once the
  transaction reports complete before latch. **Default stays 1.**
- `powermetrics`: the busy core runs at **~550 MHz of ~3.68 GHz** nominal. The remaining lag is CPU power management
  (next: WTLLegionCpuPower, `scripts/cpu-apply.sh`). GPU clock readout/floor sysctls (`debug.xegfx_gt_freq`,
  `debug.xegfx_gt_min_mhz`) are in `driver/` but not yet tested.

## Counters

```
sysctl debug.nvaccel_xe_flips debug.nvaccel_xe_flip_miss debug.nvaccel_xe_flip_fail debug.nvaccel_xe_flip_home
sysctl debug.nvaccel_xe_k9_free debug.nvaccel_xe_k9_mark debug.nvaccel_xe_k9_idle debug.nvaccel_xe_k9_forced \
       debug.nvaccel_xe_k9_max_us debug.nvaccel_surface_gpu_timeouts
```
Live switches (no restart): `debug.nvaccel_xe_flip=0` (copy path), `debug.nvaccel_surface_gpu_on=0`
(WindowServer waits itself), `debug.nvaccel_xe_k9=0`, `debug.nvaccel_xe_idle_ms=N`, `debug.nvaccel_xe_flip_hold=1|2|0`.

Fixed frame-rate test: `sudo bash /Volumes/1401/xegfx-e16/fps-check.sh bench` (build `ca_bench` with `scripts/bench/build-bench.sh`).
