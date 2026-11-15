# AppleParavirtGPU ↔ Reims bridge on the E16 (experiment)

Running Apple's real `AppleParavirtGPU` driver (macOS 26.7.1 build **25G241**) on the ThinkPad E16's
**Intel Arc 140T**, with the actual GPU work executed by [Reims](https://github.com/steelbrain/reims-vgpu)
(`1fe0acb68`) on the Metal device that XeGfx provides, and the frames handed back to XeGfx for
scan-out on the internal panel.

> **State: experimental, not working end-to-end.** Everything is built and offline-verified; two
> live boots on the E16 ended in a **full freeze**. `FREEZE-ANALYSIS.md` records both runs, what
> they rule out, and the isolation plan (stages A0/A1/B/C). Start there to continue.

## Why

XeGfx already gives the E16 a usable desktop. This experiment asks the other question: can Apple's
paravirtual GPU driver — the one macOS runs on Apple's Virtualization.framework GPUs — be pointed at
a real GPU instead of a VM host? If yes, the paravirtual display/accelerator stack becomes a second,
independent path to the panel. Reims is the natural backend: it is a complete paravirtual GPU
implementation (register semantics, FIFOs, interrupts, Metal work) that normally talks to a guest
over QEMU.

## Architecture

```
AppleParavirtGPU 25G241 (real Apple binary, unmodified on disk)
  -> patched inline BAR0 sites in its __TEXT (UUID + bytes validated, generated stubs)
  -> ReimsPCIProbe.kext 0.3.2 (boot arg reimspci=12): fake IOPCIDevice, dispatcher,
     shared BAR0 page, IRQ0 delivery, guest page mapping, synchronous transport
  -> apv-host (console session): single owner of the Reims session, Metal on the XeGfx device,
     guest-page callbacks (create_task/map_memory), register shadow application
       --display -> Reims display port 0 -> frame target -> 3x IOSurface ring
                 -> patched XeGfxAccel selector 5 -> GGTT slot -> PLANE_SURF -> panel
```

The kext is inert at boot: a console-session daemon opens the session, maps the 16 KiB BAR0 page,
creates the real Reims device and only then arms the bridge, so Apple's driver starts with a live
backend and never against a missing one.

## The seven patched sites (25G241)

| `__TEXT` | BAR0 | kind |
|---|---|---|
| `0x2cdc` | `0x1034` | version write + read as one dispatch |
| `0x2df0` | `0x1034` | version fallback write (`0x80000006`), synchronous |
| `0x2edf` | `0x1018` | stamp bitmap, read-to-clear, reproduces `testl` |
| `0x2f06` | `0x1014` | display bitmap, read-to-clear, reproduces `testl` |
| `0x10aa` | `0x122c` | display port count |
| `0x2f20` | `0x102c` | fault flag, reproduces the `cmpl/je` with two tail targets |
| `0x301e` | `0x1000` | FIFO disable on teardown, synchronous |

The FIFO read cursor (`0x100c`) is deliberately served from the shared page instead of a dispatch:
it is polled in Apple's spin loop, and the daemon publishes the device cursor every 80 µs (the
shadow can only lag the device, which is safe). The full 19-instruction audit is in
`docs/SITE-AUDIT-REPORT.md`.

## What is built and verified (offline, on an Apple Silicon Mac)

| piece | evidence |
|---|---|
| Apple image identity | byte-identical SHA-256 to the E16's dumped 25G241 binary |
| Site audit + patch plan | `verify-sites.py`: 7 patched sites + 1 shared-cell read, instruction-boundary checked |
| Stub machine code | executed under Rosetta 2: `PASS: 7 site stubs execute with the expected register and flag contract` |
| Kext 0.3.2 x86_64 | builds; `__TEXT,__apvstubs`; kcabi linkcheck vs the target `BootKernelExtensions.kc` = ok |
| Host daemon | builds; runs against real Reims on the Air's Metal device (version handshake, port count) |
| Reims protocol | 13/13 startup register sequence, IRQ0 on the FIFO thread, read-to-clear, `create_task`/`map_memory` route |
| XeGfxAccel panel API | builds, signed, marker `XG_PANEL ABI 1`, **no new undefined symbols** vs the installed accelerator, linkcheck ok |

Full detail (commands + outputs): `VERIFICATION.md`.

## Live status

| run | build | boot args | result |
|---|---|---|---|
| 1 | 0.3.0 (full + display) | `reimspci=12` | desktop reached, Metal ok, **froze** as `apv-host` started; userspace logs lost on reset |
| 2 | 0.3.1 diagnostic | `reimspci=12 apvpatch=0` (no kernel patching) | **froze** again → the text patch is not the cause |

Read `FREEZE-ANALYSIS.md`: remaining suspects are Apple's start path against the fake PCI device,
the guest-page mapping callback, and the Reims write path. The next boots isolate them with
`--no-publish` and `--no-guest-writes`.

## Run it (once the freeze is understood)

1. Install `kext/ReimsPCIProbe.kext` into a **test** OpenCore EFI, boot arg `reimspci=12`
   (`scripts/install-efi.sh`, base-system tools only, no Xcode needed on the laptop).
2. Optional panel patch: `sudo bash scripts/install-xegfx-accel.sh /Volumes/1401/xegfx-e16/final`
   (backup + aux-KC rebuild + auto-restore, `--undo`).
3. Log in, `sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh`.
4. `cd /Volumes/1401/E16-APV-Live-0.3.2 && bash scripts/apv-up.sh` (`APV_DISPLAY=1` adds the panel
   path; default is bridge-only).

## Layout

```
README.md / README-AR.md       this file and the Arabic version
STATUS.md                      component-by-component status and known risks
VERIFICATION.md                every offline check with its command and result
FREEZE-ANALYSIS.md             the two live freezes, what they rule out, isolation stages
MANIFEST.md                    hashes of the release binaries and sources
docs/                          site audit, Reims host findings, display handoff design, panel ABI
src/kext/                      ReimsPCIProbe: dispatcher, stubs generator, sites.json, build
src/host/                      apv-host: bridge client, Reims backend, panel pipeline, ABI header
src/tooling/                   verify-sites / gen-site-table / stub-sim / run-verification
src/xegfx/                     build script for the patched accelerator
xegfx/                         the XeGfxAccel panel patch and its ABI document
scripts/                       install / run / collect / rollback scripts for the E16
release/                       ready-to-copy packages (bridge+panel zip, kext-only diagnostic zip)
```

## Constraints / notes

- No Apple binaries are included. The audited image's SHA-256 is recorded instead.
- The laptop has no developer tools: every kext and binary is built on an Apple Silicon Mac.
- The Reims C library (`lib/libreims_vgpu.dylib`, x86_64) is third-party; build it from the Reims
  checkout with `cargo build --release --target x86_64-apple-darwin -p reims-vgpu-c`
  (`host-proto/build.sh` in the project workspace documents the SDK pin).
- Licence: the scripts and docs here are BSD 2-Clause; the XeGfx patch keeps the licence of the
  file it modifies; Apple's binary is not redistributed.
