# Reims x86_64 host prototype — REPORT

Prototype: `host-proto/reims-probe` (source: `host-proto/src/reims-probe.cpp`, C++17, one file).
Evidence: `host-proto/run.log` (the exact commands and their output).
Build: `host-proto/build.sh` (builds the x86_64 C API dylib from the Reims checkout, then the probe).

| | |
|---|---|
| Reims checkout | `/Users/taqieallah/src/reims-vgpu` at `1fe0acb68b287db36f1e6c7b9f45383940b8a76f` (HEAD, 2026-10-29) |
| Header used | `crates/reims-vgpu-c/include/reims_vgpu.h` at that commit (copied to `host-proto/include/reims_vgpu.h`, sha256 `8b4dda6cc384b96dd4fc3adabed793cd4862a3c34fe25433859bea880d8330c2`) |
| Build host | MacBook Air, Apple M5, macOS 27.2.1 (26B131), Darwin 27.2.0 arm64, Xcode 27.2, clang 21.0.0 |
| Target | ThinkPad E16, x86_64, macOS 26.7.1 build 25G241 |
| Dylib built | `host-proto/lib/libreims_vgpu.dylib`, x86_64, 11,160,416 bytes, sha256 `4b95ce07c052b109035cbb8fbfbead4e5128b7f3ed4fa619455600119cc7e918`, install name `@rpath/libreims_vgpu.dylib`, 48 `_rvg_*` exports |
| Probe built | `host-proto/reims-probe`, Mach-O 64-bit executable x86_64, rpath `@loader_path/lib` |

## 0. Verdict

1. **An x86_64 Reims device is created and driven successfully on this Apple Silicon Mac under
   Rosetta 2.** `MTLCopyAllDevices` in a pure C++ x86_64 process sees one device
   (`name="Apple M5" registryID=0x1000003de`); `rvg_device_create` returns `RVG_OK` (~0.22–0.28 s,
   first Metal device in the process); the whole AppleParavirtGPU startup register sequence that
   the task lists runs, in order, with every read a plausible device answer; the doorbell
   interrupt arrives on the library's `reims-vgpu.fifo` thread with vector 0; `rvg_device_release`
   tears down cleanly and runs the table's `destroy` once. Exit status 0.
2. **No step of the required 13-step register sequence aborts**, with a valid memory map and PFNs
   inside it. Reims deaths are process-level (`stderr` line then `abort()`); the one death tested
   on purpose (`feature_level = 5`, first binary-version write) produced
   `reims-vgpu: fatal: guest.features.feature_level_too_high` and SIGABRT in a forked child, and
   the parent survived it.
3. **The callback route (`create_task`/`map_memory`/`unmap_memory`/`read_memory`, no memory map)
   is the correct route for guest memory whose pages the host learns about later**, and it was
   demonstrated end-to-end; mixing it with a memory map is refused with
   `RVG_ERR_MEMORY_CONFLICT` (5), exactly as the header says.
4. The biggest practical finding for the E16 daemon: **a memory map that does not cover every
   page the guest names fails silently** (a log line, register reads 0), and **a doorbell over
   memory that holds no valid command makes the FIFO thread spin at 100 % CPU and flood the log**
   (measured: 0.250 s CPU per 0.250 s and 770,708 log lines in that phase, ~3 M lines/s) until
   `written` returns to `read` — never an interrupt.

## 1. Build: exact x86_64 commands, link line, rpath, where the dylib came from

### 1.1 The C API dylib

The two candidate prebuilt dylibs were checked:

```
/Users/taqieallah/Desktop/E16-ReimsFirstFrame/build/lib/libreims_vgpu.dylib
/Users/taqieallah/Documents/Codex/2026-11-15/new-chat-2/work/air-first-frame/build/lib/libreims_vgpu.dylib
```

Both are `Mach-O 64-bit dynamically linked shared library x86_64`, identical to each other
(sha256 `938c4f726649e2bd8a93fb9f61706fb8fce73e570fe05da29bb06a64ba7a450d`, 11,131,552 bytes),
export the same 48 `_rvg_*` symbols, and link `CoreMedia.framework` directly. They are usable as a
fallback, **but their source commit is not recorded, and a dylib that differs from the header by
even one field of a config struct is an ODR hazard**. So the prototype was built from the checkout
itself at HEAD, out of tree, with the build cache inside `host-proto/build/target` (nothing is
written under `~/src/reims-vgpu`; the pre-existing `Cargo.lock` modification there, mtime
2026-11-15 04:18, predates this session and was not written by these commands — see run.log
section 2):

```sh
cd /Users/taqieallah/src/reims-vgpu
PATH="$HOME/.cargo/bin:$PATH" \
CARGO_TARGET_DIR=/Users/taqieallah/Documents/deepseek-harness/default-workspace/e16-work/host-proto/build/target \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  cargo build --release --target x86_64-apple-darwin -p reims-vgpu-c          # ~21 s cold, 0.04 s warm
cp build/target/x86_64-apple-darwin/release/libreims_vgpu_c.dylib lib/libreims_vgpu.dylib
install_name_tool -id @rpath/libreims_vgpu.dylib lib/libreims_vgpu.dylib
codesign -f -s - lib/libreims_vgpu.dylib
```

Notes:

- The toolchain is **rustup 1.98.1-aarch64-apple-darwin**, the version the checkout's
  `rust-toolchain.toml` pins (`rustc 1.98.1 (48a229cea 2026-09-01)`); its installed targets
  include `x86_64-apple-darwin`. The machine's *default* stable is 1.100.0, but building inside
  the checkout makes rustup honour the pinned 1.98.1. (The 21 s cold time is because the target
  cache was seeded by copying an existing `target/e16-cross` tree; a truly clean build of the
  workspace for x86_64 takes several minutes, mostly SDL3.)
- **`SDKROOT=…/MacOSX26.5.sdk` is deliberate.** The macOS 27 SDK's `CoreMedia.framework` reexports
  `libswiftCoreMedia`, so linking with the default (27.2) SDK records
  `@rpath/libswiftCoreMedia.dylib` as a dependency of the dylib, and
  `dyld` then fails to load the library on a machine without an `/usr/lib/swift` rpath:

  ```
  dyld[71787]: Library not loaded: @rpath/libswiftCoreMedia.dylib
    Referenced from: <852FA7FA-C7D9-3C0E-89C8-515FD16EB633> .../build/target/x86_64-apple-darwin/release/deps/libreims_vgpu_c.dylib
    Reason: tried: '.../build/lib/libswiftCoreMedia.dylib' (no such file), '.../build/lib/libswiftCoreMedia.dylib' (no such file)
  ```

  Two ways out: add `-Wl,-rpath,/usr/lib/swift` to the host link (this works here; the library is in
  the dyld shared cache), or build against the macOS 26.5 SDK as above, which links
  `CoreMedia.framework` itself (as the earlier E16 dylib did) and needs no Swift overlay. The
  prototype uses the second, so the dylib also has a better chance on the target's macOS 26.7.1.
- `install_name_tool -id` is required, or the probe's dependency is the absolute
  `build/target/.../libreims_vgpu_c.dylib` path (cargo leaves the full build path as the install
  name), and a copied folder would not run on the ThinkPad.

### 1.2 The probe

Single-file C++17, no Objective-C source (Metal enumeration goes through `objc_msgSend`):

```sh
xcrun clang++ -std=c++17 -arch x86_64 -mmacosx-version-min=26.6 -O2 -g \
    -Wall -Wextra -Wno-unused-parameter \
    -I include \
    src/reims-probe.cpp \
    lib/libreims_vgpu.dylib \
    '-Wl,-rpath,@loader_path/lib' \
    -framework Metal -framework Foundation -pthread \
    -o reims-probe
codesign -f -s - reims-probe
xcrun lipo -verify_arch x86_64 reims-probe
```

Resulting load commands (`otool -L reims-probe`, run.log section 4):

```
@rpath/libreims_vgpu.dylib (compatibility version 0.0.0, current version 0.0.0)
/System/Library/Frameworks/Metal.framework/Versions/A/Metal (...383.1.0)
/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation (...5027.1.8)
/usr/lib/libc++.1.dylib / /usr/lib/libSystem.B.dylib / /usr/lib/libobjc.A.dylib
```

One `LC_RPATH`: `@loader_path/lib`. So `host-proto/reims-probe` + `host-proto/lib/libreims_vgpu.dylib`
is a self-contained pair; the folder can be copied to the ThinkPad and run there.

ABI check printed by the probe (must match the Rust build; a mismatch here is the first thing to
look at if a config is refused):

```
sizeof(RvgDeviceConfig)=72 sizeof(RvgHostCallbacks)=88 sizeof(RvgMemoryMap)=16 sizeof(RvgMemoryRange)=24
RVG_DEVICE_MMIO_SIZE=0x4000 RVG_MAX_DISPLAY_PORTS=8 RVG_PCI_VENDOR_ID=0x106b RVG_PCI_DEVICE_ID=0xeeee
```

`RvgDeviceConfig` = 72 bytes matches `docs/api.md` §1: "`RvgDeviceConfig`, at its fourth version,
72 bytes".

## 2. Does the x86_64 binary run on this Apple Silicon Air under Rosetta 2?

**Yes, completely.** No translation refusal, no Metal unavailability, no missing library (with the
build above). Evidence:

```
$ arch -x86_64 uname -m
x86_64
$ arch -x86_64 ./reims-probe --registry-id 0x1000003de --phase main
reims-probe: x86_64 host prototype for the Reims C API (RvgDevice)
build arch: x86_64  sizeof(RvgDeviceConfig)=72 sizeof(RvgHostCallbacks)=88 ...
Rosetta 2: yes (x86_64 process translated by Rosetta 2)
Metal devices (MTLCopyAllDevices): 1
  [0] name="Apple M5" registryID=0x1000003de
selected Metal device: registryID=0x1000003de
...
[main] rvg_device_create -> 0 (success), device=0x7f7d6e312af0, took 235672 us
...
[main] PHASE main: PASS
RESULT: PASS
[exit 0]
```

The same x86_64 binary runs without `arch` too (launchd/Rosetta translates it automatically;
run.log section 7), and `sysctl.proc_translated` is 1 inside the probe. Metal works under Rosetta
(a translated process gets the machine's Metal devices; only one device exists here).

Timing under Rosetta: `rvg_device_create` ≈ 223–278 ms (5 measured creates), which is mostly the
device's Metal blit-pipeline creation; the register sequence is 0–172 µs per access (the FIFO
enable, which maps the ring and spawns the thread, is the slowest).

The one thing that *did* fail was the dylib's linkage when built with the macOS 27 SDK; the exact
`dyld` error is quoted in §1.1. It is a build-SDK problem, not a Rosetta problem: the same binary
loads the library fine once the dylib is built against the 26.5 SDK (or the host adds an
`/usr/lib/swift` rpath).

## 3. The register sequence: every step, its result, and whether it looked plausible

Memory map: one anonymous 4 MiB range at guest physical `0x40000000` (host `mmap`, 4 KiB guest
pages, no file). Values were chosen to be inside it:

| register | meaning (Reims) | value used | why |
|---|---|---|---|
| `0x1034` | guest binary version | `6` | Apple's driver writes 6 |
| `0x101c` | root page number (PFN) | `0x40000` | `0x40000000 >> 12`, x86-64 page = 4 KiB |
| `0x1030` | root FIFO base page (PFN) | `0x40100` | `0x40100000 >> 12` |
| `0x1004` | root FIFO length | `0x4000` | must be whole pages, ≤ `0x20000`, and > the start offset |
| `0x1010` | root FIFO start offset | `0x1000` | driver's value; Reims requires it nonzero, `0x400`-aligned and below the length |
| `0x1008` | root FIFO written offset (doorbell) | `0` | the driver's startup cursor |

Observed (run.log section 5; exit 0, 13/13 steps, 0 unexpected answers):

| # | operation | result | verdict |
|---|---|---|---|
| 1 | write `0x1034` = 6 | — (173 µs) | ok; log: `guest asked for binary version 6; version 0x6 is stored` |
| 2 | read `0x1034` | `0x00000006` (6 µs) | plausible: negotiated version 6 (expected 6) |
| 3 | write `0x101c` = `0x40000` | — (65 µs) | ok: root page mapped from the memory map |
| 4 | write `0x1030` = `0x40100` | — (2 µs) | staged until the enable |
| 5 | write `0x1004` = `0x4000` | — (1 µs) | staged |
| 6 | write `0x1010` = `0x1000` | — (1 µs) | staged |
| 7 | write `0x1000` = 1 | — (172 µs) | ok: FIFO created, thread `reims-vgpu.fifo` started |
| 8 | write `0x1008` = 0 | — (1 µs) | no-op doorbell (`written == read`) |
| 9 | read `0x100c` | `0x00000000` (3 µs) | plausible: published read offset 0 |
| 10 | read `0x122c` | `0x00000001` (3 µs) | plausible: port count (1; below version 245 it is `count != 0`) |
| 11 | read `0x1014` | `0x00000000` (0 µs) | plausible: no display interrupt |
| 12 | read `0x1018` | `0x00000000` (0 µs) | plausible: no stamp interrupt |
| 13 | read `0x102c` | `0x00000000` (0 µs) | plausible: no FIFO faulted |

Post-sequence diagnostics (outside the driver's sequence):

| read | value | meaning |
|---|---|---|
| `0x101c` | `0x40000` | the page number reads back |
| `0x1000` | 1 | FIFO enabled |
| `0x1004` | 0 | write-only register: reads 0 |
| `0x100c` | 0 | read offset |
| `0x1030` | 0 | write-only register: reads 0 |

### Which steps abort, and which only log

**None of the 13 aborts.** All failures on this path are log lines (the `rvg_log_set_handler`
handler receives them; without a handler they go nowhere) plus a register that keeps reading 0.
Empirically (phase `limits`, run.log section 6):

| guest input | result | log line |
|---|---|---|
| root PFN `0x50000` (GPA `0x50000000`, outside the map) | `0x101c` reads back `0x50000` anyway; no root node | `root page 0x50000 not mapped: no root node` |
| enable after that | `0x1000` still reads 0 | `root FIFO not created: no root node` |
| FIFO length `0x1234` (not whole pages) | refused, `0x1000` stays 0 | `root FIFO not created: its length 0x1234 is not whole pages` |
| length == start (`0x1000`) | refused, `0x1000` stays 0 | `root FIFO refused: start offset 0x1000 is not below its length 0x1000` / `root FIFO not created: the FIFO refused its registers` |
| valid staging, enable → disable → enable | `0x1000` = 1, 0, 1 | — (disable waits for the FIFO thread to drain: 45 µs when idle) |
| second root page write | tears the live root down and maps the new one; `0x1000` goes back to 0 | — |

The deaths are elsewhere and are process-level (`docs/api.md` §1 "Deaths"; header preamble
"Deaths"). Verified with `feature_level = 5` (a config value the header accepts):

```
[death] rvg_device_create -> 0 (success)
[death] writing 0x1034 <- 6 now; with feature_level 5 this ends the process (expected death)
reims-vgpu: fatal: guest.features.feature_level_too_high
[parent] phase death: child terminated by signal 6 (Abort trap: 6)
```

This is why the prototype runs each phase in a forked child of itself (`--child` is internal):
`abort()` would otherwise take the report with it. Where a step aborts on the real device, the
last progress line in the child's progress file names it (the parent prints it).

## 4. Guest memory known only after device creation: the correct callback route

### 4.1 The API's own statement

Header, `RvgHostCallbacks` (`crates/reims-vgpu-c/include/reims_vgpu.h:415`):

> `// The device's callbacks. Without a memory map, the device calls the task and memory`
> `// callbacks; with one, it calls none of them and a config that gives any is refused. Without`
> `// add_trace_range the device calls neither trace function.`

`RvgDeviceConfig.memory_map` (`reims_vgpu.h:523`):

> `// The guest's RAM, or NULL to reach it through the host callbacks.`

Status (`reims_vgpu.h:91`): `#define RVG_ERR_MEMORY_CONFLICT 5` — "A memory map together with any
of `create_task`, `destroy_task`, `map_memory`, `unmap_memory` or `read_memory`."

### 4.2 The exact typedefs and their semantics (`reims_vgpu.h:330–392`)

```c
// `create_task(ctx, vm_size, &base_address)`: reserve `vm_size` bytes of host address space
// for a new GPU task. Returns the host's task, or NULL for a failure, and writes the base
// address of the reservation through `base_address`.
typedef void *(*RvgCreateTaskFn)(void *ctx, uint64_t vm_size, void **base_address);

// `destroy_task(ctx, task)`: the task's last call. `task` is NULL after a failed root map.
typedef void (*RvgDestroyTaskFn)(void *ctx, void *task);

// `map_memory(ctx, task, range_count, virtual_offset, read_only, ranges)`: map `range_count`
// guest ranges, one after another, at `virtual_offset` in the task's reservation.
typedef bool (*RvgMapMemoryFn)(void *ctx, void *task, uint32_t range_count,
                               uint64_t virtual_offset, bool read_only,
                               const RvgPhysicalMemoryRange *ranges);

// `unmap_memory(ctx, task, virtual_offset, length)`. Returns false for a failure.
typedef bool (*RvgUnmapMemoryFn)(void *ctx, void *task, uint64_t virtual_offset, uint64_t length);

// `read_memory(ctx, physical_address, length, dst)`: copy guest memory into `dst`. ... The
// device reads guest physical memory this way, at most one guest page (16 KiB on arm64, 4 KiB
// on x86-64) a call: a task's page tables, the task memory it copies through them, and each
// task's root node at a resume. With a memory map it reads through the map, and a config that
// gives read_memory is refused. Without a map and without read_memory, it maps the page into
// its root task (map_memory, then unmap_memory) and copies from there.
typedef bool (*RvgReadMemoryFn)(void *ctx, uint64_t physical_address, uint64_t length, void *dst);
```

The Rust core's mirror is `crates/reims-vgpu-core/src/host/callbacks.rs:32–45`:

```rust
/// `createTask(vmSize, &baseAddress)`: `NULL` on failure; writes the base in place.
pub type CreateTask = Arc<dyn Fn(u64, &mut HostPtr) -> HostTask + Send + Sync>;
/// `destroyTask(task)`.
pub type DestroyTask = Arc<dyn Fn(HostTask) + Send + Sync>;
/// `mapMemory(task, rangeCount, virtualOffset, readOnly, ranges)`.
pub type MapMemory = Arc<dyn Fn(HostTask, u32, u64, bool, &[PhysicalMemoryRange]) -> bool + Send + Sync>;
/// `unmapMemory(task, virtualOffset, length)`.
pub type UnmapMemory = Arc<dyn Fn(HostTask, u64, u64) -> bool + Send + Sync>;
/// `readMemory(physicalAddress, length, dst)`.
pub type ReadMemory = Arc<dyn Fn(u64, u64, HostPtr) -> bool + Send + Sync>;
```

Threads and ordering (`docs/api.md` §5, "Where each callback arrives"): the task and memory
callbacks run on **a library thread** — "a FIFO's, a worker of the device's" — or on the host's
thread inside a call that may call back (a release, `reset`, `finish_suspend`, `will_resume`); they
are **not** serialized with each other ("calls from different FIFOs may overlap"), and their order
is core's ("The order of VM-memory operations is core's"). `read_memory` "may wait for another host
thread, unless that thread is itself waiting in a call on this device that may call back."

### 4.3 Which Reims internal paths use the callbacks when `memory_map` is `None`

- **`create_task`**: `crates/reims-vgpu-core/src/device/root.rs:88` (`set_root_page`), the guest's
  root-page write. With no map, before mapping the root node:
  ```rust
  if !has_memory_map {
      let Some(create) = &self.blocks.create_task else {
          crate::fatal!(DeviceDeath::NilBlock("createTask"))
      };
      let mut base = rt.task_info().base_address;
      let task = create(ROOT_TASK_SIZE, &mut base);
      rt.root_task_base.store(base.addr(), Ordering::Relaxed);
      rt.root_task.store(task.addr(), Ordering::Relaxed);
  }
  ```
  `ROOT_TASK_SIZE` is 16 MiB (`crates/reims-vgpu-core/src/device.rs:85`, `0x100_0000`), which the
  probe measured: `create_task #1: vm_size=0x1000000`.
- **`map_memory`**: `root.rs` `root_task_mapping()` (`createTask`'s task → a range of its address
  space allocated from `FirstFitVa`, then `map(info.task, ranges.len(), offset, false, ranges)`),
  used for every device mapping: the root node page (`set_root_page` →
  `new_contiguous_mapping(root_page, APV_PAGE_SIZE)`), the FIFO ring (`create_root_fifo` →
  `new_contiguous_mapping(base_page, length)`), display pages, task page tables, etc.
- **`unmap_memory`**: `MappingSink::unmap_range` (`crates/reims-vgpu-core/src/device.rs:784`) when a
  mapping is released; no map means the host's `unmapMemory`, then the allocator's free.
- **`read_memory`**: `root.rs:487` `read_from_physical_address` — "if `memory_map` is None and
  `read_memory` is given, copy through it; else map the page into the root task, copy, unmap"
  (the fallback path is `new_contiguous_mapping` + `copy_to`).
- **`destroy_task`**: `root.rs:170` in `teardown_root` (and the task table's teardown), after every
  call for the task has returned.

Empirically (phase `callback`, run.log section 6 — memory_map = NULL, 4 MiB file-backed RAM, host
callbacks that really map it):

```
[callback] create_task #1: vm_size=0x1000000 -> base=0x1145ed000
[callback] map_memory #1: task=0x1145ed000 count=1 voffset=0x0 ro=0: [0] gpa=0x40000000 len=0x1000     (root page write)
[callback] map_memory #2: task=0x1145ed000 count=1 voffset=0x4000 ro=0: [0] gpa=0x40100000 len=0x4000 (FIFO enable)
[callback] after the root page write: create_task=1 destroy_task=0 map=1 unmap=0 read=0
[callback] after the FIFO enable:     create_task=1 destroy_task=0 map=2 unmap=0 read=0
[callback] unmap_memory #1: task=0x1145ed000 voffset=0x4000 len=0x4000
[callback] unmap_memory #2: task=0x1145ed000 voffset=0x0 len=0x1000
[callback] destroy_task #1: task=0x1145ed000 (unmap 0x1000000 bytes)
[callback] after release: create_task=1 destroy_task=1 map=2 unmap=2 read=0 destroy=1
```

Note `read_memory` was not called in this scenario: nothing in the root-page/FIFO-enable path reads
guest physical memory directly; it is used for task page tables, memory the device copies through
them, and each task's root node at a resume. It is *not* the main data path for guest RAM — that is
the mapping itself (the device reads and writes guest memory through the mapped range).

### 4.4 What the host must provide

1. **A per-task address-space reservation** from `create_task`: `vm_size` is 16 MiB today
   (`ROOT_TASK_SIZE`); reserve it (PROT_NONE `mmap` is enough), write the base through
   `base_address`, and return a non-NULL task handle (any pointer; `NULL` means failure).
2. **A way to map guest physical ranges into that reservation** on demand. `map_memory` gets guest
   physical addresses, not host pointers, and it can arrive *after* creation (the root page write is
   where the first one arrives). The host resolves each `RvgPhysicalMemoryRange` to host memory
   (pinned guest RAM pages) and maps it at `base + virtual_offset`, ranges laid out one after
   another in the order given. `read_only` must be honoured (the library passes `false` today).
3. **`unmap_memory`** for the reverse, and **`destroy_task`** when the task is gone (map/unmap
   arrive in the order core made them, but they are not serialized across FIFOs).
4. **`read_memory`** only if the host wants to serve physical reads itself; without it the library
   maps the page through the root task (map/unmap per read). Its length is at most one guest page
   (4 KiB on x86-64), and it may wait for other host threads.
5. The mapped memory must stay valid **for as long as the device lives** (the same rule as
   `RvgMemoryRange.host_address` in the map: "`physical_length` bytes, mapped ... for as long as any
   device ... made over the map lives").

### 4.5 Is mixing a memory map with those callbacks refused?

**Yes. `RVG_ERR_MEMORY_CONFLICT` (5).** Empirically (phase `conflict`, run.log section 6):

```
memory_map + create_task  -> 5 (memory map with task or memory callbacks)
memory_map + read_memory  -> 5 (memory map with task or memory callbacks)
memory_map + map_memory   -> 5 (memory map with task or memory callbacks)
memory_map + raise_interrupt -> 0 (success)
```

`raise_interrupt`, `add_trace_range` and `remove_trace_range` are *not* part of the conflict: they
are allowed with a memory map (the main phase relies on that). The check is in
`crates/reims-vgpu-core/src/device.rs:1059`:

```rust
if host_blocks.create_task.is_some()
    || host_blocks.destroy_task.is_some()
    || host_blocks.map_memory.is_some()
    || host_blocks.unmap_memory.is_some()
    || host_blocks.read_memory.is_some()
{
    log::warn!("device refused: a memory map was given beside a task or memory block");
    ...
    return Err(DeviceRefusal::MemoryConflict);
}
```

### 4.6 Which route should the E16 daemon use?

The daemon knows the VM's guest RAM *before* it creates the Reims device (it is the RAM it pins for
the guest), so the **static `RvgMemoryMap` is the simpler and better route**: one entry per RAM
range, mapped read-write, alive for the device's life. That is what QEMU's `apple-gfx` does.

The catch, and it is the sharpest lesson of this prototype: **the map must already cover every
page the guest will ever name**, because
`set_root_page`/`create_root_fifo` map straight from the map and a page outside it is only a log
line — the page number is stored, `0x101c` reads it back, but there is no root node, the FIFO is
never created, `0x1000` reads 0, and the guest driver times out. For the x86-64 Apple driver the
PFN it writes is `guest physical address >> 12` (4 KiB, `APV_PAGE_SHIFT = 12` on x86-64,
`crates/reims-vgpu-core/src/guest/records.rs:25`), so a map of all guest RAM covers it.

The **callback route** is the correct alternative exactly when the host cannot enumerate/pin guest
RAM at creation time — e.g. RAM whose pages are handed to the daemon by the kernel later, or a
process-isolated arrangement. Then `create_task`/`map_memory`/`unmap_memory` (and optionally
`read_memory`) are the only route: the library asks for guest physical ranges *when the guest
names them*, and the host maps them then. It works (demonstrated), but it brings library threads
into the host's memory management, so every map/unmap must be safe to call from an arbitrary
library thread and must not take a lock the MMIO worker holds.

## 5. `raise_interrupt` — the thread it runs on, what it may do, how to bridge it

Header (`reims_vgpu.h:384–392`):

> `// Thread: a library thread (a FIFO's or the device's reporting thread), or the host's thread`
> `// inside a call marked "may call back". The device's signal lock is held: one device's raises`
> `// never run at once. It must not wait for a host thread that is in a call on this device.`
> `// May call: rvg_status_message only. Without it, the device's first interrupt ends the`
> `// process.`

Observed: on an Apple M5 under Rosetta, the Nop-command doorbell raised the callback **once**, on a
thread whose name is **`reims-vgpu.fifo`**, with **vector 0**:

```
[main] Nop doorbell (cursor 12): raise_interrupt arrived: count 0 -> 1, vector 0, library thread "reims-vgpu.fifo"
```

Vector 0 is not an accident: `DeviceCore::interrupt()` calls `raise(0)`
(`crates/reims-vgpu-core/src/device/fifos.rs:424–433`: `if self.run_state.load() == RunState::Running
{ ... raise(0); }`). The device uses one MSI vector (`RVG_PCI_MSI_VECTORS 1`, "The MSI vectors
the device uses"), so the bridge has nothing to demultiplex; it delivers vector 0 to the guest.

What the callback **may** do: call `rvg_status_message` and nothing else of the library. It must
not block, and in particular:

- **it must not call `rvg_device_mmio_read`/`write`** — "A call into the same device from a device
  callback may deadlock, or end the process at an assertion. The library does not check for it."
  (`docs/api.md` §1 "What may be called inside a callback"); it also runs under the device's signal
  lock, and an MMIO write can wait for the FIFO thread.
- **it must not wait for the kernel bridge or the host's main loop** — the whole device stalls
  behind the signal lock while the callback runs, and a raise inside a host call that is waiting on
  whatever the callback waits for is a deadlock (`docs/api.md` §5, "Blocking and re-entry").
- it must be fast and allocation-free in a production host.

How to deliver it to a kernel bridge: **set a pending flag and wake the bridge, never block.** The
usual shape for the E16 daemon is: the callback does an atomic store of a per-vector pending bit
(and a coalescing counter), then a non-blocking notification the bridge can wait on (a Mach
message/port, a `kevent`, or an ioctl-free shared page + `wakeup` on the kernel side); the bridge
then calls the driver's interrupt path and lets the guest read `0x1014`/`0x1018` to find the cause.
Because the guest acknowledges by reading the read-to-clear bitmaps, the daemon must **not** read
those registers itself to "poll" for interrupts after forwarding — it would clear the bits the
guest needs. If the bridge cannot take the interrupt immediately, coalesce: one pending line and a
counter is enough; the guest driver's handler reads the bitmaps anyway.

Also note: a raise that happens while the device is paused/suspended is *not* delivered
(`interrupt()` checks `RunState::Running`), and "Without it, the device's first interrupt ends the
process" — a daemon that ever expects the guest to interrupt must install the callback, even if it
then drops the vector.

## 6. Do `rvg_device_mmio_read`/`write` block, may they be called from arbitrary threads, and which offsets are read-to-clear?

Header (`reims_vgpu.h:993–1010`):

```c
// A 32-bit read at `offset` in the device's MMIO region. May block and may call back.
uint32_t rvg_device_mmio_read(RvgDevice *device, uint64_t offset);

// A 32-bit write at `offset` in the device's MMIO region. May block: a root FIFO write waits
// for the FIFO's thread. May call back.
void rvg_device_mmio_write(RvgDevice *device, uint64_t offset, uint32_t value);
```

- **Threads:** yes, arbitrary host threads. `docs/api.md` §1 "Thread safety": "Every function may be
  called from any thread, on the same handle from several threads at once." Empirically: 4 host
  threads × 2000 iterations of `read 0x122c`/`read 0x100c` while the device was live → **0
  mismatches in 1146–1166 µs** (3 runs). The exception is a device callback running on a library
  thread (§5).
- **Blocking:** the *read* path is lock-free at the MMIO level (`crates/reims-vgpu-core/src/device/
  mmio.rs` contract: "No read or write takes a lock at this level ... the registers ... are read
  from their staged view"), but the header still marks it "may block" because a few registers reach
  into locks (the EFI mode registers take the displays lock) and a call marked "may call back" may
  wait for the library's threads. Measured here: every read 0–8 µs.
- The *write* that actually waits is **disabling the root FIFO, `0x1000 <- 0`**: `teardown_fifos`
  stops and **drains** the FIFO thread (`fifo.stop()` then `fifo.drain()`, which waits for the
  thread's exit and every pending stamp); a command that never completes (a `CmdDelay`) hangs it.
  Measured 31 µs on an idle FIFO. `0x101c` (root page) tears a live root down first, so it can wait
  too (measured 9–65 µs); enabling `0x1000 <- 1` costs the mapping and thread spawn (measured
  82–172 µs when it creates the FIFO, 3–62 µs when it is refused).
  Do not call MMIO from the `raise_interrupt` callback (§5) or from a "may call back" host call that
  the callback could be waiting on.
- **Read-to-clear:** exactly **`0x1014`** (display interrupt bitmap) and **`0x1018`** (stamp
  interrupt bitmap); **`0x102c`** (fault flag) is a boolean and is **not** cleared. Source:
  `mmio.rs:14–15`: "0x1014 and 0x1018 clear on read; 0x102c is a boolean and is not cleared".
  Empirically, after the Nop doorbell: `read 0x1018 -> 0x00000001` then `read 0x1018 -> 0x00000000`.
  `0x1014`'s bits are `1 << port` and need a display; none was created here.
- **Decode:** `(offset - 0x1000) >> 2` truncated to 16 bits — offsets alias every `0x40000` bytes, an
  unaligned offset rounds down, offsets below `0x1000` wrap to indices `0xfc00–0xffff` (none
  handled), and unmapped/write-only registers read 0.

## 7. Observed behaviour of the real device on this M5 Air that matters for the E16 daemon

1. **Metal under Rosetta is real.** `MTLCopyAllDevices` (pure C++ with `objc_msgSend`; no ObjC
   source needed) returns `Apple M5`, registryID `0x1000003de`; `MTLCreateSystemDefaultDevice`
   agrees. Registry ID 0 means "the system's default Metal device" (`RvgDeviceConfig.metal_registry_id`
   comment), so a daemon that wants "the first device" can pass 0 or the enumerated ID; a bogus ID
   is `RVG_ERR_NO_METAL_DEVICE` (4).
2. **Device creation is not cheap:** 223–278 ms for `display_port_count = 1` on this machine
   (Metal blit pipelines). The *first* call with a Metal device also makes the process's frame
   queue, "even when the device is then refused" (`rvg_device_create` docs) — so a failed create
   still pays for Metal. Create the device once, keep it.
3. **Config sizes matter:** the current header is `RvgDeviceConfig` 72 bytes; the library accepts a
   host built against a shorter first version (48/56/64 bytes) but a *larger* struct with nonzero
   tail is `RVG_ERR_UNSUPPORTED` (2). Build the probe and the daemon against the same header as the
   dylib.
4. **PFNs are guest-page numbers, and on x86-64 the guest page is 4 KiB**
   (`APV_PAGE_SHIFT = 12 if x86_64`). Apple's driver writes `0x101c`/`0x1030` as PFNs; Reims turns
   them into `page * 0x1000`. An arm64 host would be 16 KiB (`0x4000`) — irrelevant for the E16 but
   it explains why a "page number" from the guest must be shifted by the *guest* page size.
5. **A memory-map miss is silent** (§4.6). The daemon must validate that every PFN the driver will
   write lies inside the map — at minimum cover the whole guest RAM window. The only symptoms are
   log lines and a register reading 0.
6. **Install a log handler.** Reims sends log lines "where `REIMS_VGPU_LOG` says (by default,
   nowhere)" (`rvg_log_set_handler` docs). All refusals are log-only, so a daemon without a handler
   is blind to them. (The prototype installs one; that is how the refusal texts in §3 were
   captured.)
7. **The FIFO ring layout is `base_page << 12` + `start`.** `0x1010` is an offset inside the FIFO
   buffer, not a page. The ring is `[base+start, base+length)`; the length must be a nonzero
   multiple of 4 KiB and ≤ `0x20000`, the start nonzero, `0x400`-aligned, below the length. The
   driver's own value pair (length from its buffer, start `0x1000`) must satisfy that or the FIFO
   is never created.
8. **A doorbell over unwritten memory is a CPU-eating log bomb.** `0x1008 <- 12` with a zeroed ring
   (each zero header has length 0 and is "skipped" without publishing a read) left the FIFO thread
   spinning: **0.250 s CPU per 0.250 s wall (one core at 100 %)**, `0x100c` (published read) stuck
   at 0, no interrupt, fault flag 0, and **770,708 log lines** in that phase (a
   `command 0 of length 0 ... skipped` warning per ring pass, ~3 M lines/s; the probe caps printing
   at 100 lines and reports the count). Writing `written = read` (`0x1008 <- 0`) stops it (0.000 s
   CPU in the following 100 ms). So: the guest/driver must have written real commands before
   ringing, and the bridge should not ring with a cursor ahead of valid bytes.
9. **A real doorbell completes the command and raises the interrupt, in this order:** the command's
   stamp value is written into guest memory at the FIFO page (offset `stamp_index * 4`; observed
   `0x40100000 = 0x00000001`), the stamp bitmap `0x1018` bit 0 is set, and `raise_interrupt(0)`
   runs on `reims-vgpu.fifo`. `0x100c` then reads 12 (the consumed command length). The guest learns
   the completion by reading `0x1018`.
10. **Interrupt vector is always 0** (`raise(0)`), and it is raised only while the device is
    running (not paused/suspended).
11. **`0x1014`/`0x1018` are read-to-clear**, `0x102c` is not. A host that polls those registers
    steals the guest's interrupt cause; the kernel bridge must be the only reader (and after
    forwarding, it must not "double read").
12. **`0x1004`, `0x1030` and `0x1010` are write-only** (read 0); `0x101c`, `0x1000`, `0x100c`,
    `0x1034`, `0x122c`, `0x1014`, `0x1018`, `0x102c` read back something meaningful.
13. **Version 6 is accepted and stored as 6** ("version 0x6 is stored"); below binary version 245
    the display port count always reads `count != 0` (so `0x122c` reads 1 for `display_port_count = 1`
    regardless of the configured count) and the connection types are masked `& 3`.
14. **A second root-page write is legal**: it tears down the live root (FIFOs, tasks, displays) and
    maps the new page. Enabling an already-enabled FIFO is guarded (write of 1 while enabled is a
    no-op, not a death).
15. **Deaths are process-level** (`stderr` then `abort()`), so a daemon that hands Reims guest input
    must treat every death as "the daemon dies": the E16 daemon should keep the Reims device in a
    process it can restart (as the prototype's fork does), or at least never let a guest-controlled
    value reach a death path. Verified death: `feature_level = 5` + first version write →
    `reims-vgpu: fatal: guest.features.feature_level_too_high`, SIGABRT.
16. **MMIO is thread-safe from host threads** but not re-entrant from device callbacks; and the
    guest's write-then-read at `0x1034` means the bridge must preserve *order* per vCPU: the daemon
    needs an ordered MMIO worker (one queue per device), not a thread pool that reorders.
17. **The library's C API is a thin forwarder** (`crates/reims-vgpu-c/src/device.rs:867–890`: each
    export calls `live(device, name).mmio_read(offset)`), so every rule above is core's, not a C
    layer artifact — a Rust daemon using `reims-vgpu` sees the same behaviour.

## 8. How to run and reproduce

```sh
cd host-proto
bash build.sh                                     # dylib (cargo, x86_64) + probe (clang++, x86_64)
arch -x86_64 ./reims-probe --registry-id 0x1000003de --phase main   # the required run
./reims-probe                                     # all phases, exit 0 iff main passed
./run-log.sh                                      # regenerate run.log
```

Phases (`--phase`): `main` (the required sequence + interrupt + teardown), `limits` (refusals the
register path logs instead of dying), `blank-doorbell` (the doorbell-over-zeroed-memory hazard),
`conflict` (memory map + task/memory callbacks → 5), `callback` (the callback route without a memory
map), `death` (a deliberate process abort, caught by the fork). `--all` is the default. Every phase
runs in a forked child of the binary; the parent prints `RESULT: PASS` only if the `main` child
created the device, ran 13/13 steps without a crash, and released it.

Exit status: 0 = device creation worked **and** the 13-step register sequence completed without a
crash (*not* "every read was ideal" — unexpected values are reported but do not fail the run);
1 = the main phase failed; 2 = bad arguments or a refused/failed create; the `death` child's SIGABRT
is expected and does not fail the run.

## 9. What was not tested, and open items for the ThinkPad

- **No display was created.** So `0x1014` display interrupts, the display doorbell (`0x1220`), the
  guest's display-shared-state page, `mode_change`/`new_frame`, frames and readback were not
  exercised. The main phase's `0x1014` reads are 0 by construction.
- **No real guest command stream**: the only FIFO command executed was a 12-byte `Nop` (opcode 30),
  enough to prove the ring, the stamp and the interrupt. No task/object-list/heap commands, no
  guest memory written by a command handler.
- **`read_memory` was never called** in the callback phase (nothing on that path reads guest
  physical memory directly); it is exercised only by task page tables / resume paths.
- **The target hardware differs.** This Air's Metal device is an Apple M5; the E16's Intel Arc is
  reached through XeGfx, and Reims' `rvg_device_create` prints/logs the Metal device it actually got
  ("device starting on Metal device Apple M5" here). Run `./reims-probe --phase main` on the
  ThinkPad and check that line, the create status, and 13/13 steps; that is the same binary and the
  same dylib, copied as the `reims-probe` + `lib/` pair.
- **Only one Metal device exists here**, so `--registry-id N` selection was exercised only with the
  real ID and with a nonexistent ID (parent refuses with "no Metal device with registry id").
- **The dylib still links VideoToolbox/AppKit/Carbon and the rest of the Reims platform** even
  though the probe never uses the video/window devices; that is how the C API ships. On the target
  the library's dependencies are macOS 26.7's own frameworks, which is why it was built against the
  macOS 26.5 SDK (see §1.1).

## 10. Files

| file | what |
|---|---|
| `host-proto/reims-probe` | the prototype binary (x86_64, rpath `@loader_path/lib`) |
| `host-proto/src/reims-probe.cpp` | its single C++17 source |
| `host-proto/lib/libreims_vgpu.dylib` | the C API dylib, built from HEAD, x86_64 |
| `host-proto/build.sh` | the exact build (cargo + install_name/codesign + clang link line) |
| `host-proto/run-log.sh` | regenerates `run.log` |
| `host-proto/run.log` | the exact commands and output for every run quoted here |
| `host-proto/include/reims_vgpu.h` | the header from the same commit (sha256 in §top) |
| `host-proto/build/target/` | the out-of-tree cargo cache (seed + this build) |
