# HANDOFF: where the E16 work stands (2026-11-18 11:45 Cairo)

> To continue from another device: open this file. The Arabic summary is at the end.
> **Start with "CURRENT STATE" just below: it supersedes the older "Next steps" further down.**
> The previous handoff (old XeGfx stack, k22, measurements from 2026-11-02) is in git history: `git show e708242:HANDOFF.md`.

## CURRENT STATE (2026-11-18 11:45 Cairo) - read this first
**Where we are:** macOS 26.7.3 (25G342), MeowARL (MeowXE3 1.0.71 = NMXGPU xe on 7D51) installed, fbflags 1833.
The desktop came up on the panel once permissions were fixed (see the 11:00 update below), but now **every boot with
the driver freezes the WHOLE machine 1-2 minutes after boot/login** (no mouse, no touchpad, caps lock dead; power
button needed). No panic is written for these freezes.

**Evidence (stick: `xegfx-e16/logs/lastwords-1118-013157/`, `bootcap-1118-012303/`, `meowarl-1118-012320/`):**
- Unfiltered 3 h system log (`syslog-3h.txt.gz`, 4.36 M lines). Boots with the driver and where their log stops:
  | boot | log stops | after |
  |---|---|---|
  | 00:36:42 | survived (the good session: perf/ws-sample measured, aerial wallpaper chosen ~00:57) | - |
  | 01:00:51 | 01:01:59 | ~70 s |
  | 01:03:48 | 01:05:22 | ~95 s |
  | 01:14:29 | 01:16:40 | ~130 s |
  | 01:18:05 | 01:19:12 | ~67 s |
- The log just stops (last lines are ordinary: Wi-Fi scans, NVMTL pipeline/cache hits in WindowServer, an occasional
  "timed out fence", "NullMoth GPU: wiring ... for writing failed (0x2); for reading: 0x0"). No GPU reset/hang/GuC error.
- **Correlation:** 3 of the 4 freezes happen at/just after the bootcap launchd job runs (boot + ~60 s: ioreg of the
  NMX objects + a big `log show`). 01:00:51 froze *during* bootcap (its log.txt is 0 bytes); 01:18:05 froze 0.5 s after
  bootcap's `log show` finished. But the good 00:36 session also ran bootcap -> not proven.
- The aerial (video) wallpaper the user picked made things much worse; it was changed back to a still picture (in a
  `-nvoff` boot) before the 01:14 and 01:18 boots, which still froze.
- Separate issue: **kernel panics at SHUTDOWN in `-nvoff` boots** (`reports/Kernel-2026-11-18-{000554,001426,003044,011112}.panic`):
  page fault at RIP 0 in `PMHaltWorker::work` (a driver's power-off/halt callback is a NULL function pointer),
  "System shutdown begun: YES". Not the freeze. Likely a MeowXE3 piece loaded but not started under `-nvoff`; check later.
- Also seen: `BackgroundShortcutRunner` running a Shortcuts "runshellscript" action thousands of times per session (not ours?).

**Tests handed to the user (one at a time, report: froze or not, after how long):**
1. Remove bootcap: in a `-nvoff` boot `sudo bash /Volumes/1401/xegfx-e16/bootcap/uninstall-bootcap.sh`, then boot the
   driver and use it 5 min.
2. If it still freezes: fbflags 809 (= 1833 without 0x400 flips). Prepared on the stick:
   `cp /Volumes/1401/EFI/OC/config.plist.fb809 /Volumes/1401/EFI/OC/config.plist` (only line ~2039 differs: `ODA5`).
   Back to 1833: `config.plist.fb1833-1118`. 1321 copy: `config.plist.bak-fb1321-1118`.
   (Stray `config.plist.tmp` on the stick = an old 1321 copy, harmless; deleting on the stick needs permission.)
3. Further ideas if both still freeze: fbflags without 0x20 (IOGraphics power) / with 0x4 (no power); disable the Metal
   plug-in for everything but WindowServer (`/Library/GPUBundles/nvmtl-allow.txt`, currently has `*`); ask upstream
   (MeowXE3 / NullMoth issues) about hard freezes on graphics 12.70+/Meteor Lake GT; read MeowXE3's flight log
   `/Users/Shared/nmx-flight.log` from a frozen boot (it is written by the kext and may survive).

**Scripts added today (all in `scripts/k23/`, on the stick in `xegfx-e16/MeowARL/`, md5-verified):**
`k23-metal-check.sh` (GPUBundles modes + signature page sizes), `fix-gpubundle-perms.sh` (THE fix: 755/644 modes),
`k23-perf.sh` (CPU users, clocks, NMXAccel counters while moving windows), `cpu-measure.sh` (copied from k22),
`k23-ws-sample.sh` (sample WindowServer + busiest app, fence timeouts, 15 min of messages),
`k23-lastwords.sh` (whole system log 3 h gz + hang/crash/panic reports).

**Answers already given to the user:**
- "2048 MB" in About This Mac = `VRAM,totalMB` set by the driver on GFX0 (no DeviceProperties in config.plist);
  cosmetic for a shared-memory iGPU. Could be overridden with DeviceProperties or in the driver later; low priority.
- 60 fps: panel is 60 Hz; WindowServer delivered ~30 fps while moving windows. Plan: let shader caches warm up, then
  try `sudo sysctl -w debug.nvaccel_iop_flip=1` (zero-copy), then a GPU min-clock floor like k22. Not tried yet because
  of the freezes.
- Bridge note: `device_commit_files` to `/Volumes/1401/...` only works while the stick is plugged into the M5; if macOS
  says "denied access" the stick is in the laptop. The bridge was disconnected at 11:45.

## Setup
- **The user:** Egyptian Arabic, **always reply in Arabic**.
  - Sends photos of the screen.
  - The laptop has **no internet and no developer tools** (no Command Line Tools; `dwarfdump` and `python3` are only stubs).
  - Everything is built on the M5, carried on the USB stick `1401` (FAT), and run on the laptop with `sudo bash ...`.
  - When the stick is plugged into the M5, Claude can read and write it through the device bridge at `$HOME/mnt/Volumes/1401`.
    - Copy files with `device_commit_files` from `/mnt/user-data/outputs`, then verify with md5.
    - **Never type data by hand** (a hand-typed base64 copy got corrupted once).
    - `device_commit_files` once wrote an OLD copy for a reused output path: give each new version a new file name in outputs.
- **Laptop:** ThinkPad E16 Gen 3.
  - CPU: Core Ultra 7 255H (Arrow Lake H). iGPU: Arc 140T `8086:7D51` (graphics 12.74, Meteor Lake firmware family).
  - macOS was **wiped and reinstalled fresh as 26.1 (25B78)**. **The user is now updating to the latest macOS** (MeowXE3 was tested on 26.7.3; the old install was 26.7.1). See "After the macOS update" below.
- **OpenCore:** on the stick, `/Volumes/1401/EFI/OC/config.plist`. Work folder: `/Volumes/1401/xegfx-e16`.
- **Build Mac (M5):**
  - Build root: `~/nmx` (`NULLMOTH_BUILD_ROOT`), driver output in `~/nmx/out`.
  - Repo clone: `~/src/xe-e16/e16-repo`.
  - SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
- **Repo:** https://github.com/taqieallah/ThinkPad-E16-ArrowLake-macOS (main, pushed up to `63ae021`).

## The current direction: k23 = MeowARL (MeowXE3 on Arrow Lake)
MeowXE3 (github.com/cuadra8998/MeowXE3, PolyForm-NC) packages NullMoth's NMXGPU stack:
- Linux 6.14 `xe` + Intel display, on FreeBSD LinuxKPI, running inside xnu.
- NMXAccel (IOAccelerator) and NMXAGDC.
- The NVMTLDriver Metal plugin → Mesa ANV, and Zink.

MeowXE3 targets Xe3. We rebuild its kernel driver with Arrow Lake H moved from i915 to xe, and ship that in its own package.

**Pins:**
| What | Pin |
|---|---|
| MeowXE3 | `fdb56f4`, release `v1.0.12` (`MeowXE3-1.0.12.zip`) |
| nullmoth/nvidia-macos-driver | `c104f584` (gpu-port) |
| ericek111/vibe-nullmoth-xe3-qemu | `7246d386` |
| drm-kmod | `c16de0f9` |
| freebsd-src | `d2145e9b` |
| linux | v6.14 |
| linux-firmware | main |

**Our pieces (all in `scripts/k23/`):**
- `build-k23.sh` (run on the M5), in 6 steps:
  1. Check out MeowXE3.
  2. `fix-meow-patches.py` (drops 0104's duplicate `drm_file_update_pid` hunk), then `setup-nmxgpu-wcl.sh`.
  3. `arl-on-xe.py`:
     - Adds `7d51,7dd1` to `NMX_XE_FORCE_PROBE`.
     - Changes i915's `INTEL_ARL_IDS` to ARL_U + ARL_S, so i915 no longer claims Arrow Lake H.
     - Points the build scripts at the SDK path.
  4. `build-guest.sh all`.
  5. Swaps our binary into the 1.0.12 package:
     - `payload/MeowXE3.kext`, version **1.0.71**, ad-hoc signed.
     - Adds the Meteor Lake firmware: `mtl_guc_70.bin`, `mtl_huc_gsc.bin`, `mtl_gsc_1.bin`, `mtl_dmc.bin` → `/Library/NullMoth/firmware/i915`.
  6. Patches the installer:
     - Accepts Arrow Lake.
     - Finds OpenCore on `/Volumes/*/EFI/OC`.
     - When started from the FAT stick, re-runs itself from a clean local copy (`/Users/Shared/MeowARL-run`, no `._*` files, no xattrs).
     - Reads `payload/MeowXE3.uuid` instead of calling dwarfdump.
     - Copies the result to the stick and verifies it.
- `k23-collect.sh` (laptop): flight log, kernel log (`prev` = last 3 h), system info, crash reports → `xegfx-e16/logs/meowarl-*`.
- `bootcap/` (laptop, installed): a launchd job `com.e16.meowarl.bootcap`.
  - Runs at every boot that has `nmxintel=1` and no `-nvoff`.
  - Sleeps 40 s, then saves ioreg (framebuffer / display / accel / GFX0) and the boot's WindowServer + kernel log to `/Users/Shared/meowarl-boot/<time>/`.
  - `copy-results.sh` copies that to the stick.
  - **New in 63ae021:**
    - It also captures class `NMXGPUFB`.
    - `arm-pipetest.sh` arms a **one-shot pipe test** for the next boot: `sysctl debug.nvaccelfb=3`, then `killall WindowServer`, wait 40 s, capture again into `pipetest*.txt`. The flag file `/Users/Shared/meowarl-boot/PIPETEST` is removed before the test runs.
  - The new files are on the stick and md5-verified.
  - **Not run yet.** The user decided to update macOS first.

**What OpenCore needs (config.plist on the stick):**
- boot-args: `nmxintel=1 -wegoff amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0`.
- `csr-active-config ff0f0000`.
- `SecureBootModel` Disabled.
- NVRAM Delete covers `boot-args` and `nullmoth-fbflags`.
- `nullmoth-fbflags` (data) at **line ~2039**: now **`MTMyMQ==` = "1321" (test value)**.
  - The installer default is 1833.
  - Backup with 1833: `EFI/OC/config.plist.bak-meowarl-fb1833`.
- Kexts:
  - MeowXE3Boot **ON**: sets `AAPL,iokit-ignore-ndrv` on the Intel display when `nmxintel=1`.
  - **E16ConsoleRange ON. Required.** Without it, the boot hangs on verbose text. I once wrongly told the user to turn it off.
  - WhateverGreen OFF. ReimsPCIProbe no longer present.
- Boot menu entry **"MeowXE3: start once without driver"** (NullMothSafe.efi, `-nvoff`) = the safe way into macOS.
- The installer's EFI backup on the laptop: `~/MeowXE3-EFI-backup-20261117-181930`.

**nullmoth-fbflags bits:**
| Bit | Meaning |
|---|---|
| 0x1 | not the console |
| 0x2 | no vblank |
| 0x4 | no power |
| 0x8 | keep boot framebuffer |
| 0x10 / 0x40 | retire early |
| 0x20 | IOGraphics power |
| 0x100 | (set in both values; meaning not recorded) |
| **0x200** | **accelerated head**: class `NMXIntelGPUFB`; NMXAccel binds the head and WindowServer composites on the GPU |
| 0x400 | flips |

1833 = 0x729 (with 0x200). 1321 = 0x529 (without it).

## What works and what doesn't (on 26.1)
**Fixed along the way:**
- The install-time freeze: LegionCpuPower. Disabled; don't install it.
- The verbose-text hang: E16ConsoleRange must stay on.
- The codesign "sealed resource missing" error: AppleDouble `._*` files from FAT. Fixed in the installer.
- The dwarfdump prompt: fixed with the UUID file.

**Works:** xe drives 7D51.
- Firmware loads (GuC/HuC/GSC/DMC).
- The panel runs at 1920x1200@60.
- Flips work, and NMXAccel comes up.

**Doesn't work: WindowServer never puts a picture on the panel.**
- **fbflags 1833 (0x200 on):** WindowServer crash loop (5+ times).
  - Crash: CoreDisplay assert in `CoreDisplay_CreateDisplayForCGXDisplayDevice`.
  - It comes right after `IOFBSetDisplayModeAndDepth: Setting mode 0x0 ... Failed to obtain mode info` and `Setting offline display 0x00000000 main in AddCGXDisplayDeviceToDeviceList`.
  - Stale display prefs were ruled out: those plist files don't exist.
- **fbflags 1321 (0x200 off):** no crash. Black screen, a frozen cursor at the top, only caps lock responds. The log (`logs/bootcap-1117-192035/meowarl-boot/1117-191540/log.txt`) shows:
  - `nullmoth-fbflags 0x529: not the console`, framebuffer 1920x1200 @ 60.
  - NMXAccel: `AMD/Intel accelerator up: Metal device for apps (headless) until a VM display (NMXVGAFB) publishes`.
  - `NVDisplayPipe::initFramebufferResource(index 0): scanout gate CLOSED -- returning NULL ... (sysctl debug.nvaccelfb=3 opens it)` ← **the key line**.
  - IOPresentment: `Unable to get AGDC information. Return code: 0x10000003`. The GPU wrangler shows `agdc 0x0` and `gpuc 0x0`.
  - CoreDisplay: the same `Setting mode 0x0 / Failed to obtain mode info` plus an error stack in `CoreDisplay::Framebuffer::Framebuffer` (DisplayPipe hash table), then `Unable to find display pipe for IOFB service / regID: 0xce03 / 0x100000536`.
  - `get_display_device_info: isAcc=YES isBuiltIn=YES`, `needs_refresh = YES`, an NVSurface of 1920x1200 is created.
  - **Reading:** WindowServer composites, but no display pipe is bound to `NMXGPUFB` (the scanout gate is closed), so nothing reaches the panel. 0x200 is the path that binds it, and that path hits the CoreDisplay assert.
- **Why updating macOS is the main suspect:** MeowXE3 was tested on 26.7.3. CoreDisplay's accel-head path on 26.1 may differ (mode 0x0 / no mode info, missing AGDC).

## UPDATE 2026-11-18 11:00 Cairo - the desktop works
- Updated to **macOS 26.7.3 (25G342)**: the 1833 CoreDisplay assert stayed, so the OS version was NOT the cause.
- **Real cause:** `/Library/GPUBundles` was installed `rwx------` (FAT modes carried over by ditto), so WindowServer
  (`_windowserver`) logged "Cannot find executable for CFBundle NVMTLDriver.bundle" and CoreDisplay asserted.
  `scripts/k23/fix-gpubundle-perms.sh` (dirs 755, Mach-O 755, rest 644) fixed it; build-k23.sh's installer patch now
  normalises modes in its local copy. The console's "code signature page shift: 14" lines are noise (also without the driver).
- **Now:** fbflags 1833, desktop on the panel, 1920x1200, brightness works, About This Mac shows "Intel Graphics 2048 MB".
- **Slow:** `k23-perf.sh` / `k23-ws-sample.sh` (logs `perf-1118-004635`, `ws-1118-005110`, `cpu-measure-1118-004728.txt`):
  - CPU is fine: all cores reach 3.58 GHz under load (CpuTscSync only).
  - WindowServer ~110-130 % CPU, mostly **NVMTL compiling shaders** (libnvmtl_translate AIR->SPIR-V): `fc cache: miss
    fixed_frag_lph_cph ~700 KB 4-9 s each`, aircache 1837 misses on first use; caches in
    `/var/folders/.../C/WindowServer/nvmtl/`. CoreAnimation "timed out fence" / "synchronize timed out" cluster while
    apps compile. The second boot was already faster -> mostly warm-up; re-measure after a few boots.
  - Frames: CPU copy to the panel ~2 ms/frame (`nvaccel_iop_copy_us`), ~30 fps while moving; zero-copy flip not used
    (`debug.nvaccel_iop_flip=0`, `iop_flips=0`). Next test: `sudo sysctl -w debug.nvaccel_iop_flip=1` live (reboot undoes).
  - 2048 MB VRAM is only the advertised number (shared memory).

## Next steps (in order)
1. **During the macOS update** (several reboots): avoid booting the driver half way.
   - Either remove `nmxintel=1` from boot-args in config.plist for the update, or pick "start once without driver" at every reboot. The first is safer: the updater reboots on its own.
   - Put `nmxintel=1` back afterwards.
2. **After the update:**
   - Boot with "start once without driver".
   - Run the installer again, driver only:
     ```
     sudo bash /Volumes/1401/xegfx-e16/MeowARL/"Install MeowXE3.command"
     ```
     choose `[2] driver only`, approve in System Settings › Privacy & Security if asked, then restart. The OS update rebuilds the kext collections, so the driver must be put back in. `MeowXE3.uuid` is in the payload, so no dwarfdump is needed.
   - Check that bootcap is still installed: `ls /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist`. If it is missing: `sudo bash /Volumes/1401/xegfx-e16/bootcap/install-bootcap.sh`.
3. **Test 1833 first on the new OS:**
   - Restore it: `cp EFI/OC/config.plist.bak-meowarl-fb1833 EFI/OC/config.plist`. Careful: that backup also still has whatever else the config had then. Compare, or just change line ~2039 back to `MTgzMw==` ("1833").
   - Boot the driver, wait 2 min, boot "without driver", run `sudo bash /Volumes/1401/xegfx-e16/bootcap/copy-results.sh` and `k23-collect.sh prev`, plug the stick into the M5.
   - Look for: a WindowServer crash or not; `Failed to obtain mode info`; `scanout gate`; `display pipe`; AGDC errors.
4. **If it's still black or crashing:**
   - Run the pipe test on 1321: `sudo bash /Volumes/1401/xegfx-e16/bootcap/arm-pipetest.sh`, then boot the driver and wait 2 min.
   - It shows whether opening the scanout gate by hand gets a picture without 0x200.
   - If the machine hangs: hold the power button, then boot normally. The test is one-shot.
5. **Then dig into the mode info.** CoreDisplay asks for mode 0x0 and `IOFBGetDisplayModeInformation` fails.
   - NullMoth's `xnu/nmx_fb.cpp` (analysis tree `/tmp/claude-0/nmp`, 804 lines; the scratch tree may be gone, rebuild it from the pins):
     - It publishes a single mode with ID 1; `getCurrentDisplayMode` returns 1.
     - No EDID; `IODisplayPrefsKey` vendor `unkn` / product `0x717`.
   - Check what CoreDisplay reads before the mode query (IOFBConfig / IOFBModes / IOFB0Hz). IOGraphics source is in `/home/claude/ext/iog/g`, which may also be gone.
   - Compare with MeowXE3's own working logs or issues on 26.7.x, and ask upstream (MeowXE3 / NullMoth issues) about `Failed to obtain mode info` with the accel head.
6. Optional, older: HybridPM 0xC5 measurement (`scripts/k22/cpu-measure.sh`). k22 belonged to the old XeGfx stack, which the fresh install replaced.

## Parked
- **The old XeGfx/WTL stack + k22** (late-frame SLPC floor, commit e708242): the code stays in `driver/` and `scripts/k22/`. Not installed on the fresh macOS.
- **AppleParavirtGPU/Reims (`apple-paravirt/`): paused for now.**
- ArcMTL experiment: parked (see `docs/ARCMTL-EXPERIMENT.md`).

## Files that matter
| Where | What |
|---|---|
| `scripts/k23/build-k23.sh`, `arl-on-xe.py`, `fix-meow-patches.py` | the M5 build |
| `scripts/k23/README-k23.txt` | Arabic step-by-step guide for the user |
| `scripts/k23/k23-collect.sh`, `scripts/k23/bootcap/*` | diagnostics on the laptop |
| `/Volumes/1401/xegfx-e16/MeowARL/` | the built package (installer, payload, k23-collect.sh) |
| `/Volumes/1401/xegfx-e16/bootcap/` | bootcap + arm-pipetest.sh |
| `/Volumes/1401/xegfx-e16/logs/` | every collected log (`bootcap-*`, `meowarl-*`) |
| `/Volumes/1401/EFI/OC/config.plist` (+ `.bak-meowarl-fb1833`) | OpenCore |
| `~/nmx/build/gpu-src/xkpi/k23-build.log` (M5) | the driver build log |

## ملخص بالعربي
- **إحنا فين:** مسحنا الماك ونزّلنا macOS 26.1 من الأول. بنينا MeowXE3 على كارت Arrow Lake (7D51) وركّبناه.
  - التعريف شغال: الـ firmware بيحمّل، والشاشة على 1920x1200 بـ 60Hz، والـ Accelerator قايم.
  - المشكلة الوحيدة إن WindowServer مش بيعرض الصورة على الشاشة.
- **1833 (الإعداد الأصلي):** WindowServer بيكرش ويعيد كذا مرة، لأن CoreDisplay بيقع وهو بيعمل الشاشة.
- **1321 (التجربة):** مفيش كراش، بس الشاشة سودا. البوابة اللي بتوصّل الرسم بالشاشة مقفولة (scanout gate closed)، فـ WindowServer بيرسم والصورة مش بتوصل.
- **الشك الأقوى:** نسخة macOS. MeowXE3 اتجرّب على 26.7.3، وإحنا كنا على 26.1. فدلوقتي بنحدّث لآخر نسخة.
- **بعد التحديث:**
  1. أثناء التحديث شيل `nmxintel=1` من الـ boot-args، أو اختار "start once without driver" في كل ريستارت.
  2. ادخل بـ "start once without driver"، وشغّل الـ installer واختار [2] driver only.
  3. رجّع الـ fbflags لـ 1833 (`MTgzMw==`)، واعمل بوت بالتعريف، واستنى دقيقتين.
  4. بعدها `copy-results.sh` و`k23-collect.sh prev`، ووصّل الفلاشة.
- **لو لسه مش شغال:** رجّع 1321، وشغّل `arm-pipetest.sh`، واعمل بوت بالتعريف واستنى دقيقتين، وبعدين انقل النتايج.
- E16ConsoleRange لازم يفضل شغال على طول، ومتركّبش LegionCpuPower.
- تجربة AppleParavirtGPU/Reims متوقفة حاليًا.

### تحديث 18/11 الساعة 11:45
- الصورة اشتغلت بعد ما ظبطنا صلاحيات ملفات الـ Metal (`fix-gpubundle-perms.sh`)، والمشكلة مكانتش نسخة macOS.
- المعالج سليم، وبيوصل لـ 3.58 جيجاهرتز. البطء كان من بناء الـ shaders لأول مرة، ومن نسخ الفريمات للشاشة بالمعالج.
- **المشكلة دلوقتي:** كل بوت بالتعريف الجهاز كله بيقف بعد دقيقة أو اتنين، ومن غير أي رسالة خطأ.
- **التجارب الجاية بالترتيب:**
  1. نشيل bootcap.
  2. لو لسه بيقف: نجرّب fbflags 809 (من غير الـ flips). الـ config بتاعه جاهز على الفلاشة.
- فيه كمان panic وقت الإطفاء في البوت من غير تعريف. دي مشكلة تانية وهنبصلها بعدين.
