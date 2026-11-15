# The daemon's Reims -> XeGfx panel path

`apv-host --display` adds the presentation half of the goal topology: the frames the
paravirtual guest produces are encoded by Reims, copied into an IOSurface, and scanned out on
the internal eDP panel by the patched XeGfxAccel.

Everything here is built and linked but **not yet exercised on the E16** — it is the last block
before the on-hardware run.

## Why this shape

Reims owns the guest's display: the guest (AppleParavirtGPU's display machine) programs Reims'
display port through FIFO commands, and Reims renders the guest's frame with Metal (on the XeGfx
Metal device). The host never sees the guest's scanout surface directly — no portable interface
gives it the guest surface the display pipe last presented. What Reims *does* give the host is
`rvg_display_encode_frame`: encode the display's current frame into a host-owned frame target.
That is the only supported "give me the current frame" call, and the earlier first-frame test
proved it works (`PASS: exported Reims GPU frame`).

So the panel path is:

1. `apv-host` opens `NMXAccel`'s `'XGDR'` user client (type `0x58474452`), selector 5:
   `INFO` returns the live plane geometry (pipe, width, height, byte pitch, format, refresh),
   `ACQUIRE` takes the single-owner panel token.
2. It creates the Reims display on port 0 with the panel's mode, so the guest's display machine
   sees the same mode the panel is running.
3. It creates an `RvgFrameTarget` of the panel's size (BGRA8, `RVG_PIXEL_FORMAT_BGRA8_UNORM`)
   and a **ring of three** global IOSurfaces with the panel's geometry and the **panel's byte
   pitch**. The kext retains the last two surfaces it presented, so rotating three guarantees
   the plane never scans a surface the daemon is rewriting (a single surface would tear).
4. A display thread polls `rvg_display_present_counts`. When the guest's present count advances
   it encodes -> commits -> waits -> `rvg_frame_target_read_pixels` -> copies each row into the
   locked IOSurface -> `PRESENT` with the IOSurfaceID.
5. The patched XeGfxAccel looks the IOSurface up in the daemon's task, validates size/format/
   pitch/pages, maps its pages into the reserved GGTT slot, programs `PLANE_SURF`/`PLANE_STRIDE`
   for the panel pipe, latches on `FRMCOUNT` with the request's timeout, keeps the surface and
   the previous one alive for two generations, and returns.
6. On `RELEASE` (daemon exit, or the session closing) the kext unmaps the slot and restores the
   scanout surface that was on the plane when the token was taken, so WindowServer's own
   producer continues where it was.

## Cost and behaviour

* One full-frame encode + GPU wait + readback + row copy per presented guest frame. At
  1920x1200x4 that is ~9 MB per frame; the copy is CPU bandwidth only, the encode is GPU work on
  the XeGfx Metal device. This is the "full copy" fallback route from the design report; the
  zero-copy IOSurface route (make Reims render directly into the IOSurface-backed texture) needs
  a Reims-side frame-target extension and is left as a follow-up.
* Frames are presented only when the guest presents one, so the panel shows the last
  paravirtual frame between guest presents instead of a XeGfx frame. That is intended: once the
  paravirtual GPU is the desktop GPU, XeGfx's own producer is not driving the plane.
* If the daemon dies, the connection closes: the kext's `clientClose` releases the token,
  unmaps the slot and restores the original surface, so the panel returns to the WindowServer
  producer instead of freezing on the daemon's last frame.

## Failure modes the code handles

| condition | behaviour |
|---|---|
| patched XeGfxAccel absent | `--display` logs that `NMXAccel` does not answer INFO and the bridge run continues without the panel path |
| another producer holds the token | ACQUIRE fails, the path logs it and stays inactive |
| IOSurface refused / wrong pitch | PRESENT returns a distinct status, the daemon logs and keeps the previous frame |
| FRMCOUNT latch timeout | PRESENT returns `XG_PANEL_ERR_LATCH`; the daemon logs, does not retry that surface in a loop |
| daemon crash | kext restores the original surface (see above) |
| no guest frame yet | nothing is presented; the panel keeps its previous content |

## Verification status

* The daemon builds x86_64 with this path and its no-panel mode runs against real Reims on the
  Air (`host/apv-host --no-arm`).
* The patched XeGfxAccel builds for x86_64 and links against the same core XeGfx exports as the
  baseline build (no new undefined symbols); see `xegfx/` and `docs/PANEL-ABI.md`.
* Not verified: any of the above against real XeGfx hardware, the IOSurface page hand-off, the
  plane programming and the FRMCOUNT latch. That is the E16 step.
