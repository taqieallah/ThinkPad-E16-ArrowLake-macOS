# HANDOFF: where the E16 work stands (2026-11-02 13:10 Cairo)

> للمتابعة من جهاز تاني: افتح الملف ده، والملخص بالعربي في آخره.

## Setup
- **Laptop (hackintosh):** ThinkPad E16, Core Ultra 7 255H, iGPU Arc 140T `8086:7D51` (Xe-LPG+ 12.74).
  Now on **macOS 26.7.1 (25G241)**. OpenCore on USB stick `1401` (FAT). Work folder on the stick: `/Volumes/1401/xegfx-e16`.
- **Build machine:** M-series MacBook Air.
  - Sources: `~/src/xe-e16/wtl` (WTLIntelGfx ff64f83 + our changes = this repo's `driver/`), `~/src/kcabi`, `~/src/xe-src`.
  - Scripts: `~/Desktop/xe-update/`.
  - ArcMTL: `~/src/ArcMTL`.
- The laptop has no developer tools. Everything is built on the Mac, carried on the stick, and installed with scripts.
- **The user:** Egyptian Arabic, **always reply in Arabic**. They send photos of the screen. Read longer logs from the stick
  (`/Volumes/1401/xegfx-e16/logs/`) when it is plugged into the Mac.

## Daily use (works)
```
# after login on the laptop
sudo bash /Volumes/1401/xegfx-e16/xe-up.sh     # v10: loads core+accel, AGDC K5, turns on flip + K9b, restarts WindowServer once
```
- Working: GPU acceleration, panel at 60.01 Hz, zero-copy flip, K9b, colours (after the macOS update), Wi-Fi, touchpad,
  battery, sound.
- Live knobs (no restart):
  - `debug.nvaccel_xe_flip` (1)
  - `debug.nvaccel_surface_gpu_on` (1)
  - `debug.nvaccel_xe_k9` (1)
  - `debug.nvaccel_xe_flip_hold` (**keep 1**)
  - `debug.nvaccel_xe_idle_ms` (40)

## Measurements today
| Test | Result |
|---|---|
| `sample WindowServer` (10 s) | main thread **87 % idle**, composite ≈ 1.5 ms, no GPU waits → WindowServer is not the bottleneck |
| `fps-check.sh` (scrolling) start of day | ~25 fps sent = shown, 0 lost |
| `fps-check.sh bench` (fixed CA animation, hold=1) | **~43–53 fps**, 0 lost, swings 35–58 |
| hold=0 (no wait, newest wins) | ~35 fps, frames dropped → rejected |
| hold=2 (1 in flight + 1 queued) | ~55 fps, peaks 62–63, **but the orange block stutters/tears** (WindowServer redraws a buffer still on screen: the transaction is signalled complete before latch) → rejected, default stays 1 |
| `powermetrics` while scrolling | **busy core at 552 MHz (15 % of ~3.68 GHz nominal)**, other cores 550–2470 MHz, package only reaches C2 |

**Conclusion:** the remaining lag is **CPU power management** (Arrow Lake is unknown to macOS, the clock stays near
minimum under load), not the display path.

## In progress / next steps (in order)
1. **CPU power: apply WTLLegionCpuPower 0.4.1.** It fixes per-core HWP and the MCHBAR power limits; fan control is
   disabled with `-legioncpunofan`. On the laptop:
   ```
   sudo bash /Volumes/1401/xegfx-e16/cpu-apply.sh          # undo: --undo; stops if machdep.xcpm.mode != 1
   ```
   Restart, then check while scrolling:
   ```
   sysctl debug.legioncpu.status
   sudo powermetrics --samplers cpu_power -i 2000 -n 2 | grep -iE "frequency|residency"
   ```
   Goal: busy core ≥ 3000 MHz. If XCPM is not active, plan B is needed (HWP via the plugin's own MSR path, or
   CPUFriend-style data); not investigated yet.
2. **GPU clock:** new core sysctls are written but **not yet built or tested**: `debug.xegfx_gt_freq`
   (act/req/min/max/rp0/slpc) and `debug.xegfx_gt_min_mhz` (floor; write the rp0 value to force full speed).
   Build with `bash ~/Desktop/xe-update/core/build-core.sh` on the Mac, then `full-install.sh`, restart, `xe-up.sh`.
   (This build also carries `flip_hold`, already tested.)
3. Re-run `fps-check.sh bench` after 1 and 2. The script now skips `sample` in bench mode; the stick copy may need
   that one-line fix if it was not re-copied.
4. Later:
   - auto-start xe-up at login
   - sleep and external displays (would need i915 to own the display; ArrowWhatever 0011–0022 never finished)
   - Wi-Fi diag logs `logs/wifi-195845` (Wi-Fi works now)

## ArcMTL experiment (parked)
ArcXe drives this GPU. Stage 1 passed; Stage 2 B1–B3 passed (3D render OK). B4.0 (4×4 LINEAR→TILE4 texture upload)
hangs the GPU, and the desktop is black except the cursor. Upstream `e04b0fa` routes those uploads through compute;
built but **not tested** on the E16. Everything is opt-in via boot-args. `arc-mode.sh off` is set: normal boots use
XeGfx. Details: `docs/ARCMTL-EXPERIMENT.md`.

## Files that matter
- `driver/` = the exact source on the Mac (incl. flip_hold + GT-frequency sysctls); `patches/wtlintelgfx-e16.diff` =
  the same as a diff on WTLIntelGfx ff64f83.
- Scripts:
  - `scripts/xe-up.sh` (v10)
  - `scripts/build-core.sh`, `scripts/full-install.sh`
  - `scripts/fps-check.sh` (`bench` = fixed test)
  - `scripts/bench/` (`ca_bench.m`, `build-bench.sh`)
  - `scripts/cpu-apply.sh`
  - `scripts/arc/`
- Every past problem and fix: `docs/TROUBLESHOOTING.md`.

---

## ملخص بالعربي
- **اللي شغال:** تسريع كارت الشاشة، والشاشة على 60 هرتز، والعرض المباشر (flip)، وK9b، والألوان، والوايفاي، والتاتش، والبطارية، والصوت.
- **قسنا كل حاجة:**
  - WindowServer فاضي 87% من الوقت، يعني مش هو المشكلة.
  - الاختبار الثابت بيدي 43–53 فريم، ومفيش فريمات ضايعة.
  - hold=2 أسرع بس بيعمل glitch، وhold=0 بيضيّع فريمات، فثبّتنا **hold=1**.
- **سبب التقطيع الحقيقي:** المعالج شغال بـ 550 ميجاهرتز بدل 3700، لأن macOS مش عارف يدير طاقة Arrow Lake.
- **الخطوة الجاية:** تشغيل `sudo bash /Volumes/1401/xegfx-e16/cpu-apply.sh` وريستارت، وبعدين `powermetrics` وانت بتسكرول. الهدف إن الكور المشغول يبقى فوق 3000 ميجاهرتز.
- **بعدها:** بناء النواة الجديدة عشان نقيس سرعة كارت الشاشة (`debug.xegfx_gt_freq`) ونجرّب نثبّتها على الأقصى.
- **ArcMTL:** متوقف دلوقتي، ومتطفّي من الـ boot-args.
