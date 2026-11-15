# XeGfxAccel panel-present ABI (E16 APV/Reims build)

The patched XeGfxAccel (`org.watchthelight.XeGfxAccel`, IOClass `NMXAccel`) adds one
user-client selector that lets a single userspace producer take the internal panel and scan out
its own IOSurfaces. The Reims daemon (`apv-host --display`) is that producer.

Everything below was built and linked for x86_64 against the same XeGfx core exports as the
installed E16 build (`nm -um` diff: **no new undefined symbols**). Nothing here has run on the
E16 yet.

## Opening the interface

```c
matching = IOServiceMatching("NMXAccel");            // class name from xe/Info.plist
IOServiceGetMatchingService(kIOMainPortDefault, matching);
IOServiceOpen(service, mach_task_self(), 0x58474452 /* 'XGDR' */, &connection);
```

Then a structure method on the same connection:

```c
IOConnectCallStructMethod(connection, /* selector */ 5,
                          &request, sizeof(request),   // 48 bytes
                          &reply,   sizeof(reply));    // 48 bytes
```

The selector is vector 5 on the existing `'XGDR'` client (`IOAccelXeGfxDRMClient`, type
`0x58474452`); no new user-client type exists. A pre-patch kext answers selector 5 with
`kIOReturnBadArgument`, so probing it is safe.

## Structures (`xg_panel_abi.h`, identical in the kext and the daemon)

```c
#define XG_PANEL_ABI_VERSION 1u
#define XG_PANEL_FORMAT_BGRA 0x42475241u
#define XG_PANEL_SELECTOR 5
enum { XG_PANEL_OP_INFO=0, XG_PANEL_OP_ACQUIRE=1, XG_PANEL_OP_PRESENT=2, XG_PANEL_OP_RELEASE=3 };
enum { XG_PANEL_OK=0, XG_PANEL_ERR_ARGUMENT=1, XG_PANEL_ERR_NO_TOKEN=2, XG_PANEL_ERR_BUSY=3,
       XG_PANEL_ERR_SURFACE=4, XG_PANEL_ERR_PLANE=5, XG_PANEL_ERR_LATCH=6, XG_PANEL_ERR_STATE=7 };

struct xg_panel_request {             /* 48 bytes */
    uint32_t struct_size;             /* 48 */
    uint32_t op;
    uint32_t surface_id;              /* PRESENT: IOSurfaceID */
    uint32_t sequence;                /* PRESENT: producer counter */
    uint32_t timeout_ms;              /* PRESENT: unused today; the latch bound is 25 ms */
    uint32_t flags;                   /* RELEASE: bit 0 = keep the current surface instead of homing */
    uint32_t reserved[4];             /* zero */
    uint64_t reserved64;              /* zero */
};
struct xg_panel_reply {               /* 48 bytes */
    uint32_t struct_size;             /* 48 */
    uint32_t status;                  /* XG_PANEL_OK / ERR */
    uint32_t pipe;                    /* plane pipe, 0xffffffff when INFO finds none */
    uint32_t width;                   /* plane width  */
    uint32_t height;                  /* plane height */
    uint32_t pitch;                   /* plane byte pitch (PLANE_STRIDE * 64) */
    uint32_t format;                  /* XG_PANEL_FORMAT_BGRA */
    uint32_t refresh_hz;              /* 0: not known to the kext */
    uint64_t present_count;           /* frames accepted (0 today) */
    uint64_t reserved2;
};
```

Both sizes are 48; the copy-back size is the caller's `structureOutputSize`, so the client must
pass exactly 48 as the output capacity.

## Operations

### INFO
No token needed. Scans display pipes A–D for a transcoder that is on
(`TRANSCONF(0x70008 + p*0x1000) & 0x80000000`), a plane that is on, linear and 32 bpp
(`PLANE_CTL(0x70180 + p*0x1000)`: bit31 set, tiling bits 12:10 = 0, format bits 27:24 = 8), and
reads `PLANE_SIZE` (`w = low16+1`, `h = high16+1`) and `PLANE_STRIDE` (`pitch = (value & 0x7ff) *
64`). Returns `XG_PANEL_ERR_PLANE` when no pipe matches.

### ACQUIRE
Takes the single-owner token. Settles any live internal zero-copy flip
(`nvXeFlipHome`), then records the current `PLANE_SURF` as the *home surface* to return to.
A second connection gets `XG_PANEL_ERR_BUSY`; the same connection asking again gets `OK`. While
the token is held, the internal producer's transactions are consumed but never touch the plane:
`NVDisplayPipe::performTransaction` returns early for head 4 and `xeCopyNow` returns true, so
WindowServer's frames complete without overwriting the external producer's picture.

### PRESENT
Requires the token. `surface_id` is looked up with
`IOSurfaceRoot::lookupSurface(id, owningTask)` (the surface must be visible to the daemon's
task). Validated before use: `'BGRA'` pixel format, width/height/pitch equal to the INFO
geometry, pitch a multiple of 64, `height * pitch <= 16 MiB`. The surface's pages are mapped
through XeGfx core's reserved GGTT flip slots (`xgFlipInit`/`xgFlipMap`, 3 slots sized
`pitch * height`), `PLANE_SURF` of the INFO pipe is armed with the slot's GGTT address and
`FRMCOUNT` is latched (25 ms). The last two presented surfaces are retained, so the plane always
scans a live surface. Returns `XG_PANEL_ERR_LATCH` when the flip refused (plane changed,
stride mismatch, missing core slots). Stride and plane size are **not** reprogrammed: the
producer must present exactly the plane's geometry (a modeset is the framebuffer's job).

### RELEASE
`flags` bit 0 reserved (homing always happens for now). `nvXeFlipHome()` writes the home surface
captured at ACQUIRE, latches it, then releases the retained frames; the token is dropped. This is
the only teardown path, so the plane never scans freed pages.

## Lifetime and failure rules

* Token is per-connection. `clientClose()`, `clientDied()` and `free()` all run the release path
  (they are idempotent; the token belongs to the client object), so a daemon exit or SIGKILL
  homes the plane and releases the surfaces.
* If ACQUIRE never happened, nothing is retained; if PRESENT never happened, the plane was never
  moved.
* The daemon presents from a **ring of 3 IOSurfaces** so it never rewrites the surface the plane
  is scanning or the one just before it (the kext retains two). A single surface would tear.
* While APV drives the display (the goal topology) the home surface shows the firmware/console
  picture after a release, not a repaint; that is expected.
* Sleep/wake, GPU reset and XeGfxIntelFB cursor races are **not** handled here yet; see the
  design report's §5 for the open items.

## Build (reproduces the shipped kext)

```sh
cd <the WTLIntelGfx tree with xegfx-panel.patch applied>
OGKM=$HOME/src/xe-e16/ogkm \
  OUTROOT=<this package>/xegfx \
  bash build/build_xegfxaccel.sh
codesign -f -s - <OUTROOT>/XeGfxAccel/26/XeGfxAccel.kext
```

* Patched kext sha256: recorded in `MANIFEST.md`.
* Undefined-symbol diff against the installed E16 XeGfxAccel: **none**.
* kcabi linkcheck against the target 25G241 `BootKernelExtensions.kc` with the installed
  XeGfxAccel as baseline: `link check ok`.
* The binary contains the marker string `XG_PANEL ABI 1`, which the install script checks.
