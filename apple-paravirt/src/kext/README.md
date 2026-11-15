# ReimsPCIProbe.kext 0.3.0 — build, install and live mode

x86_64 macOS 26.7.1 (25G241). Loaded by OpenCore at boot; inert until a console-session daemon
claims it.

## Modes (`reimspci=<n>`)

| mode | behaviour |
|---|---|
| 1 | control service only |
| 3 | attach-only nub |
| 5 | publish the vendor-specific nub (no Apple match) |
| 6 | Apple personality match, shared-RAM BAR0 |
| 7 | Apple match, refuse the BAR0 map (ioreg marker `denied-by-test`) |
| 8 | Apple match, self-test map + read, then refuse (`mapped-zero-then-denied`) |
| 9 | Apple match, allow only the first BAR0 map |
| 10 | diagnostic relay (legacy; the relay client is not in this build) |
| 11 | scalar MMIO transport service (no Apple match) |
| **12** | **live bridge** (the mode this package uses) |

## Mode 12 sequence

1. `start` creates the 16 KiB shared BAR0 backing (kernel+user shared, falls back to the 0.2
   flags if the shared allocation is refused), registers the control service and returns. No
   nub, no patch, no match.
2. The daemon opens the session client (type 2), maps memory type 0 (the BAR0 page), opens the
   transport client (type 1), creates the real Reims device (and, with `--display`, the Reims
   display + panel interface), pre-fills cell `0x122c`, then calls selector 1 (`arm`).
3. `armNub()` creates the `IOPCIDevice` nub (`0xff0000`, `106b:eeee`, BAR0 = the shared page),
   marks the session ready and registers the nub, so IOKit matches
   `com.apple.driver.AppleParavirtGPU`'s `AppleParavirtGPUControl` personality. The daemon is
   already serving when this happens.
4. Apple's `setupMMIO` calls `mapDeviceMemoryWithRegister(0x10, 0)`. Inside that override the
   kext records the register base and then validates the loaded image: it takes the caller's
   return address, walks back page by page to the page-aligned Mach-O header, and checks magic,
   cputype, filetype, `LC_UUID` (`0CAE9E29-…`) and `__TEXT` size. Every site's original bytes are
   then compared; only if all match does it generate the stubs into `__TEXT,__apvstubs` and write
   the `E8 rel32` patches (CR0.WP cleared, `cli`, `clflush`, `mfence`, read-back check).
5. Patched sites call `e16_apv_dispatch(site, barBase, value)`. The dispatcher validates the BAR
   base (must be one the kext mapped), refuses CLI contexts, refuses when the session is not
   being served, and forwards the access to the type-1 client (write-then-read for the version
   pair, synchronous write for the fallback and FIFO disable, reads for the bitmaps/port count/
   fault).
6. Register writes Apple performs as plain stores land in the shared page; the daemon applies
   them (configuration before FIFO enable, doorbells after) and publishes the device-owned read
   cursor and fault flag back into the page.
7. Reims raises interrupt vector 0 on its FIFO thread; the daemon's IRQ thread calls session
   selector 2, and the kext calls the handler Apple registered via `registerInterrupt`.

## The seven patched sites

| # | site | BAR0 | kind |
|---|---|---|---|
| 0 | `__TEXT+0x2cdc` | `0x1034` | version write + read (one atomic dispatch) |
| 1 | `__TEXT+0x2df0` | `0x1034` | version fallback write (`0x80000006`), synchronous |
| 2 | `__TEXT+0x2edf` | `0x1018` | stamp bitmap, read-to-clear, reproduces `testl` |
| 3 | `__TEXT+0x2f06` | `0x1014` | display bitmap, read-to-clear, reproduces `testl` |
| 4 | `__TEXT+0x10aa` | `0x122c` | display port count read |
| 5 | `__TEXT+0x2f20` | `0x102c` | fault flag: reproduces the `cmpl/je` with two tail targets |
| 6 | `__TEXT+0x301e` | `0x1000` | FIFO disable on teardown, synchronous (ordering before page release) |

The FIFO read cursor (`0x100c`) is deliberately **not** patched: it is polled in Apple's spin
loop, so it is served from the shared page (the daemon publishes the device cursor every 80 µs;
the shadow can only lag the device, which is safe). The full 19-instruction audit is in
`docs/SITE-AUDIT-REPORT.md`.

## User-client selectors

| type | selector | meaning |
|---|---|---|
| 2 | 0 | info: protocol version, mode, BAR size, ready flag |
| 2 | 1 | arm (publish the nub) |
| 2 | 2 | raise IRQ0 (scalar input: vector) |
| 2 | 3 | map guest physical → daemon address (struct `{phys,len,target}`) |
| 2 | 4 | unmap (`{target,len}`) |
| 2 | 5 | disarm |
| 2 | 6 | stats `{dispatch, failures, patched, bar_bases}` |
| 1 | 0 | fetch pending MMIO request (sequence, op, offset, value) |
| 1 | 1 | complete it (sequence, status, value) |
| 2 | memory type 0 | the shared 16 KiB BAR0 page (`clientMemoryForType`) |

Privilege: local or administrative user (the Metal-owning daemon must not need root).

## Build

```sh
bash build.sh /path/to/MacKernelSDK [output-dir]
```

Regenerates `APVSites.generated.hpp` from `sites.json` first. The output is a real x86_64 kext
even on an Apple Silicon build host. Verified against `BootKernelExtensions.kc` of 25G241 with
kcabi's `linkcheck` (the 9 `IOPCIDevice _RESERVED…` slots are the same ones the known-good
0.1.10 build lacks; `--baseline` makes the check pass).

## Install

`scripts/install-efi.sh <EFI>` copies the kext, prints the `Kernel → Add` entry and the
`reimspci=12` boot argument (and can edit the plist with `--edit`). Test EFI only.

## Diagnostics

```sh
ioreg -p IOService -r -n ReimsPCIProbe -l -w0
ioreg -p IOService -r -n ReimsPCINub -l -w0
log show --last 5m --style compact --predicate 'process == "kernel"' | grep -i ReimsAPV
```

Markers: `stage live-waiting-for-daemon`, `arming`, `personality accepted`,
`BAR register base 0x… registered`, `stage patched` (7 sites), `IRQ0 handler registered`,
`patch-byte-mismatch` / `patch-no-apv-image` (refusal, nothing written),
`session not ready` (daemon gone), `config bits call …` (first PCI config accesses).
