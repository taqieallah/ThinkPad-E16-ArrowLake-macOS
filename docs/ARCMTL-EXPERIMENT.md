# The ArcMTL experiment (2026-11-02)

[longurara/ArcMTL](https://github.com/longurara/ArcMTL) replaces i915 with a small purpose-built kernel driver
(ArcXe: direct execlist submission, own GGTT/PPGTT, no GuC) and uses the same NullMoth plugin + translator and
Mesa ANV on top. It targets Meteor Lake 155H and lists `7D51`. It was two days old when tested.

Everything here lives in `scripts/arc/` and is **opt-in**: ArcXe only attaches with `arcxe=1`, ArcFB with `arcfb=1`,
ArcAccel with `arcaccel=1`, so a normal boot keeps the XeGfx stack. `arc-mode.sh on|desktop|off` edits the
OpenCore boot-args on the stick (works from the Mac too, for recovery).

## E16 patches to ArcXe (scripts/arc/patch-arcxe-e16.py)

| Patch | Why |
|---|---|
| `E16 opt-in` | two drivers on one GPU corrupt each other; ArcXe only probes with `arcxe=1` |
| `E16-NBB` / `E16-NBB-ENG` | the hang dump showed `MI_MODE=0x1000`: Xe_HPG+ resets with nested-batch mode on; i915 turns it off on every context (`fakewa_disable_nestedbb_mode`), Mesa expects legacy semantics. Now off in every LRC and on each engine (verified `MI_MODE=0`) |
| `E16-FAULT` | on a hang also log the page-fault registers (0xcec4, 0xceb8/0xcebc), BBADDR, DMA_FADD, EIR |

## Results on the E16

| Test | Result |
|---|---|
| Stage 1 `arc_probe` | **PASS**: 12.74 identified, MI_STORE_DATA_IMM on RCS0 and BCS0 through 48-bit PPGTT, coherent UMA readback |
| Stage 2 B1 copy, B2 fill | PASS (16384/16384) |
| Stage 2 B3 64×64 render pass + readback | **PASS** (4096/4096 pixels) |
| Stage 2 B4.0 4×4 LINEAR→TILE4 texture upload | **GPU hang** (GEOM/SC busy, ring at the post-batch PIPE_CONTROL) |
| Desktop (`arc-mode.sh desktop`) | ArcFB takes the panel, cursor visible, **everything else black** |

The upload hang is upstream's too: ArcMTL `5413b62` (format widening) and `e04b0fa` (route MTL uploads through
compute) target exactly this test. The scripts are pinned to `327db35` (2026-11-02 22:14 +07: cache/PAT/TLB/RCS-ordering fixes on top of `e04b0fa`); not tested on the E16 yet. Our three ArcXe patches still apply (nested-batch is not fixed upstream).

## Building it (Mac)

```
bash scripts/arc/build-arc.sh        # ArcXe + arc_probe
bash scripts/arc/build-arc-anv.sh    # Mesa 26.2.6 ANV, cross-built for x86_64 (Homebrew no longer runs on Intel):
                                     #   pass 1 builds mesa_clc + vtn_bindgen2 for arm64,
                                     #   pass 2 cross-compiles ANV (-Dmesa-clc=system), Rosetta runs meson's checks
bash scripts/arc/build-arc-full.sh   # + ArcFB, ArcAccel (Tahoe), translator (Rust, x86_64), ArcMTLDriver.bundle
```
The plugin wants an x86_64 `libLLVM` for its AIR reader; Homebrew's is arm64 only, so the laptop install links
macOS's own `GPUCompiler.framework/.../libLLVM.dylib` at `/Library/GPUBundles/arcmtl/air-runtime/`.

## Laptop

```
sudo bash /Volumes/1401/xegfx-e16/arc/arc-install.sh        # ArcXe only     | arc-full-install.sh for all
sudo bash /Volumes/1401/xegfx-e16/arc/arc-mode.sh on        # or: desktop / off   → restart
sudo bash /Volumes/1401/xegfx-e16/arc/arc-test.sh           # stage 1
sudo bash /Volumes/1401/xegfx-e16/arc/arc-test2.sh          # stage 2 (Vulkan offscreen)
```

Verdict for now: promising (the kernel side runs on this GPU), not usable; back on XeGfx.
