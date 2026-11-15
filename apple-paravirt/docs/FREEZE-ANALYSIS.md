# Freeze analysis — live E16 runs of the APV/Reims bridge

Two live runs have been attempted on the ThinkPad. Both ended in a **full system freeze** (the
whole UI stops; no panic text is shown and no panic report is written). This file records exactly
what was known at each run, what it rules out, and the remaining isolation plan.

## Run 1 — 2026-11-15 ~04:51 (E16 local time), package 0.3.0

- Boot arguments: `... reimspci=12` (full mode: 7 patches + panel path enabled).
- kext 0.3.0 loaded and in the right state (`reims-probe-mode = 12`, `reims-apv-live = Yes`,
  `reims-apv-stage = live-waiting-for-daemon`, `IOMatchedAtBoot = Yes`).
- XeGfx up; Metal device `Intel Arrow Lake Xe-LPG+`, registry id `4294969381`.
- `apv-up.sh` reached `Metal registry id used: 4294969381` and then the machine froze.
- The report folder (`~/Desktop/E16-APV-live-20261115-045153`) had `preflight.txt` (1821 B) but
  `run.log` and `metal.txt` were **0 bytes** and there was **no host.log** — the hard reset lost
  everything the userspace side had buffered. No `/Library/Logs/DiagnosticReports` panic entry.

## Run 2 — 2026-11-15 ~05:46, package 0.3.1 diagnostic

- Boot arguments: `... reimspci=12 apvpatch=0` (**kernel text patching disabled**).
- `apv-up.sh` stopped before starting the host because of a bash-3.2 bug (`${display[@]}` with
  `set -u`), so the daemon was started by hand:

  ```sh
  ./host/apv-host --registry-id 4294969370 --seconds 45 --log "$HOME/Desktop/apv-host-stageA.log"
  ```

- This run also froze (reported by the user). `apv-host-stageA.log` and any kernel-stream
  screenshot have not been retrieved yet.

## What the two runs together rule out

| suspect | ruled out? | why |
|---|---|---|
| Kernel text patching / the generated stubs | **yes** | run 2 had `apvpatch=0`: no call site was touched |
| The Reims→panel display path in the daemon | **yes (for run 2)** | run 2 ran bridge-only (`APV_DISPLAY=0`, no `/dev` display work) |
| Boot-time behaviour of the kext | **yes** | mode 12 is inert until the daemon arms; the kext booted in both runs and the system ran for minutes |
| `reimspci=12` / kext loading / XeGfx+Metal | **yes** | both runs reached the desktop with XeGfx and Metal working |

## What remains (in likelihood order)

1. **AppleParavirtGPU's start path against the fake `IOPCIDevice`** (run 2 armed the bridge, so
   Apple matched and started; a hang there can hold an IOKit/graphics lock that WindowServer
   needs, which looks like a full freeze). The synthetic MSI capability (`findPCICapability(5)`
   → offset `0x50`) and the follow-up provider call are the least-tested part.
2. **The daemon's guest-page mapping callback** (`create_task`/`map_memory` →
   `IOMemoryDescriptor::withPhysicalAddress` + `createMappingInTask` of Apple's kernel pages into
   the daemon task). With `apvpatch=0` Apple's register writes still reach the daemon, so Reims
   can already ask for the root page / FIFO pages to be mapped.
3. **Reims MMIO writes applied by the daemon's writer thread** to a half-initialised device
   (e.g. `0x1000` enable with pages that are not mapped) — a blocking `mmio_write` inside the
   daemon could in principle stall a thread, though not, by itself, the whole kernel.
4. **The kext's session/transport clients themselves** (open, BAR mapping with
   `clientMemoryForType`, `IOConnectMapMemory64`) — the least likely of the four, but easy to test.

## Isolation plan (next boots)

Each stage is one boot with package 0.3.2 (kext 0.3.2 = 0.3.1 kext + version bump; host gains the
two new flags below). Keep a `log stream` window open; the userspace logs are lost on a hard reset,
so the screen is the evidence.

| stage | boot args | daemon command | question |
|---|---|---|---|
| **A0** | `reimspci=12 apvpatch=0` | `./host/apv-host --no-publish --no-guest-writes --log ~/Desktop/a0.log` | Is opening the session, mapping BAR0, creating the Reims device and reading guest cells safe **without ever arming** (Apple never matches)? |
| **A1** | `reimspci=12 apvpatch=0` | `./host/apv-host --no-guest-writes ...` | Does arming alone (Apple starts, but no guest write reaches Reims) freeze? Isolates the Apple start path from the Reims write path. |
| **B** | `reimspci=12 apvpatch=0` | `./host/apv-host ...` | Same as the frozen run 2 — expected to freeze; confirms reproducibility. |
| **C** | `reimspci=12 apvdsp=0` (patch on, dispatcher never sleeps) | `./host/apv-host --no-guest-writes ...` | Does patching alone (no dispatcher sleep, no guest writes) freeze? Isolates stub correctness. |
| **D** | `reimspci=12` (full) | `./host/apv-host ...` | The integrated goal, only after the above pass. |

If **A0** freezes, the problem is in the daemon/kext open+map or in Reims device creation next to
XeGfx; if **A0 passes and A1 freezes**, the freeze is in Apple's start path with the fake device
(most likely finding). If **A1 passes and B freezes**, the daemon's Reims guest-write path is the
culprit.

## Data still needed from the frozen run 2

```sh
tail -80 "$HOME/Desktop/apv-host-stageA.log"
ls -lt /Library/Logs/DiagnosticReports | head
ls -dt ~/Desktop/E16-APV-live-* | head
```

The last lines of that log say how far the daemon got (before/after `bridge armed`). Combined
with the `log stream` screenshot at the moment of the freeze, that is enough to pick A0 versus A1.
