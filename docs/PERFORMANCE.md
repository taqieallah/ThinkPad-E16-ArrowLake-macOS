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

## What is probably left

ArrowWhatever measured WindowServer composing only 12–19 frames/s on this stack regardless of the display path.
The plugin is NullMoth's NVIDIA design: surfaces are copied in and out of "VRAM", which on a UMA iGPU is the same
memory. The WTL plugin already imports IOSurface pages directly on Intel/AMD (`_hostImg`), so this is a hypothesis,
not a finding. The next step is a profile:
```
sudo sample WindowServer 10 -file /Volumes/1401/xegfx-e16/logs/ws-sample.txt   # while moving windows
```

## Counters

```
sysctl debug.nvaccel_xe_flips debug.nvaccel_xe_flip_miss debug.nvaccel_xe_flip_fail debug.nvaccel_xe_flip_home
sysctl debug.nvaccel_xe_k9_free debug.nvaccel_xe_k9_mark debug.nvaccel_xe_k9_idle debug.nvaccel_xe_k9_forced \
       debug.nvaccel_xe_k9_max_us debug.nvaccel_surface_gpu_timeouts
```
Live switches (no restart): `debug.nvaccel_xe_flip=0` (copy path), `debug.nvaccel_surface_gpu_on=0`
(WindowServer waits itself), `debug.nvaccel_xe_k9=0`, `debug.nvaccel_xe_idle_ms=N`.
