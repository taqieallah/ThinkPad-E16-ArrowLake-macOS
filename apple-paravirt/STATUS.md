# E16-APV-Live 0.3.0 — status

Target: ThinkPad E16 (Core Ultra 7 255H, Arc 140T, `8086:7D51`), macOS 26.7.1 build `25G241`,
x86_64, bare metal. Built here on a MacBook Air M5. **Nothing in this package has run on the E16
yet**; this page separates what is built/verified from what waits for the machine.

## What this build is

```
AppleParavirtGPU 25G241 (real Apple binary, unmodified)
  -> 7 patched inline BAR0 sites in its __TEXT (validated UUID/bytes, generated stubs)
  -> ReimsPCIProbe.kext 0.3.0 (mode reimspci=12): dispatcher, shared BAR0 page, IRQ0, guest page export
  -> apv-host (console session): single owner of the Reims session, Metal on the XeGfx device
       --display -> Reims display port 0 -> frame target -> 3x IOSurface ring -> XeGfxAccel selector 5
  -> patched XeGfxAccel (built here): maps the surface's pages into the GGTT slot, arms PLANE_SURF,
     latches FRMCOUNT
  -> internal eDP panel
```

## Status matrix

| piece | status | evidence |
|---|---|---|
| Apple image identity (25G241, UUID `0CAE9E29-…9B971E`) | **verified** | byte-identical SHA-256 `14985840…451c` to the E16 dump |
| Complete BAR0 audit of the driver | **done** | `docs/SITE-AUDIT-REPORT.md`: 19 BAR0 instructions, no others; 7 patch spans required |
| Patch plan against the real Mach-O | **verified** | `verify-sites.py`: 7 patched sites + 1 shared-cell read |
| Generated x86-64 stubs (incl. the new fault branch stub) | **verified by execution** | `stub-sim` under Rosetta: `PASS: 7 site stubs execute with the expected register and flag contract` |
| Kext 0.3.0 (x86_64) | **built** | `kext/build/ReimsPCIProbe.kext`; `__apvstubs` in `__TEXT` |
| Kext linkage on 25G241 | **verified** | kcabi `linkcheck` vs target `BootKernelExtensions.kc` + 0.1.10 baseline: `link check ok` |
| Host daemon (incl. panel pipeline) | **built + runs** | `apv-host --no-arm` on the Air: real Reims device on M5 Metal, version/port-count self-check |
| Reims register protocol / IRQ / dynamic memory | **verified on real Reims** | `docs/REIMS-HOST-REPORT.md`: 13/13 startup sequence, IRQ0 on the FIFO thread, read-to-clear, create_task/map_memory route |
| XeGfxAccel panel-present API | **implemented + built** | selector 5 on the `'XGDR'` client; marker `XG_PANEL ABI 1`; **zero new undefined symbols** vs the installed E16 build; `link check ok` |
| Reims -> panel pipeline in the daemon | **built, not run** | `panel.cpp`: INFO/ACQUIRE/PRESENT/RELEASE, 3-surface ring, encode->wait->read->copy->present |
| Patched XeGfxAccel install/rollback script | **written** | `scripts/install-xegfx-accel.sh` (backup + aux-KC rebuild + auto-restore, `--undo`) |
| Kext load and live patch application on the E16 | **not run** | needs the ThinkPad |
| Apple-allocated page -> daemon address mapping | **not run live** | needs the ThinkPad (symbols confirmed exported) |
| IRQ0 -> Apple event source -> `signalStamps` | **not run live** | needs the ThinkPad |
| Panel path end-to-end | **not run live** | needs the ThinkPad + patched XeGfxAccel installed |

## The seven patched sites (and the one deliberate exception)

| # | `__TEXT` | BAR0 | kind | why |
|---|---|---|---|---|
| 0 | `0x2cdc` | `0x1034` | version write+read, one dispatch | device-negotiated value, ordering |
| 1 | `0x2df0` | `0x1034` | write `0x80000006`, synchronous | last chance to fail closed |
| 2 | `0x2edf` | `0x1018` | read-to-clear stamps | device semantics |
| 3 | `0x2f06` | `0x1014` | read-to-clear display bits | device semantics |
| 4 | `0x10aa` | `0x122c` | port count read | device-provided topology |
| 5 | `0x2f20` | `0x102c` | fault flag with two tail targets | must divert into `handleFaultInterrupt` |
| 6 | `0x301e` | `0x1000` | FIFO disable, synchronous | applied before teardown frees the pages |
| — | `0x2b84` | `0x100c` | **not patched**: shared page | polled in Apple's spin loop; a dispatch there would sleep. The daemon publishes the device cursor every 80 µs, so the shadow can only lag the device (safe: the guest underestimates free space) |

## Known risks for the first E16 run

1. **Kernel text patching** in the live kernel (CR0.WP + clflush) — validated identity/bytes first,
   all-or-nothing, refusal leaves the image untouched.
2. **Fixed-address guest-page mapping** into the daemon (`createMappingInTask` +
   `kIOMapOverwrite`); a map failure is fatal to the session instead of letting the FIFO touch a
   missing page.
3. **Synthetic PCI capability 5** so Apple's accelerator reaches `setupInterrupts`; the follow-up
   provider-vtable call is inherited IOPCIDevice behaviour (instrumented with `config bits call`
   logs).
4. **Panel path assumptions**: the IOSurface the daemon presents is visible to the kext in the
   daemon's task; the plane's geometry/pitch match what INFO reports; the core's GGTT flip slots
   are available (`XeGfxResident` present). Each of these fails closed (logs, previous picture).
5. **RELEASE/teardown**: the panel interface always homes the plane before releasing surfaces; the
   accelerator's internal producer is held off while the token is held. Sleep/wake, GPU reset and
   the XeGfxIntelFB cursor race are not handled yet (design report §5).
6. **Performance** of the panel path: one full-frame encode + readback + copy per guest frame
   (route (a) of the design). The zero-copy route needs a Reims frame-target extension.
