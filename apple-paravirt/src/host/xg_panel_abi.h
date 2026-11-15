// Panel-present ABI shared with the patched XeGfxAccel kext.
//
// The daemon opens the accelerator's 'XGDR' user client (type 0x58474452) and
// uses selector 5 with this request/reply pair. The kext owns the panel:
// ACQUIRE takes the single-owner token, PRESENT maps the IOSurface into a
// reserved GGTT slot, programs the plane and latches on the frame counter, and
// RELEASE gives the panel back to its previous scanout surface.
//
// Keep this in sync with kexts/XeGfxAccel/accel/xg_panel_abi.h in the XeGfx
// tree (docs/PANEL-ABI.md).
#pragma once

#include <stdint.h>

#define XG_PANEL_ABI_VERSION 1u
#define XG_PANEL_FORMAT_BGRA 0x42475241u /* fourcc 'BGRA' */

#define XG_PANEL_USER_CLIENT_TYPE 0x58474452u /* 'XGDR' */
#define XG_PANEL_SELECTOR 5

enum {
    XG_PANEL_OP_INFO = 0,
    XG_PANEL_OP_ACQUIRE = 1,
    XG_PANEL_OP_PRESENT = 2,
    XG_PANEL_OP_RELEASE = 3,
};

enum {
    XG_PANEL_OK = 0,
    XG_PANEL_ERR_ARGUMENT = 1,
    XG_PANEL_ERR_NO_TOKEN = 2,
    XG_PANEL_ERR_BUSY = 3,
    XG_PANEL_ERR_SURFACE = 4,
    XG_PANEL_ERR_PLANE = 5,
    XG_PANEL_ERR_LATCH = 6,
    XG_PANEL_ERR_STATE = 7,
};

struct xg_panel_request {
    uint32_t struct_size; /* sizeof(struct xg_panel_request) */
    uint32_t op;          /* XG_PANEL_OP_* */
    uint32_t surface_id;  /* PRESENT: IOSurfaceID; ACQUIRE: 0 */
    uint32_t sequence;    /* PRESENT: producer frame sequence (informational) */
    uint32_t timeout_ms;  /* PRESENT: vblank latch timeout, 0 = 25 ms default */
    uint32_t flags;       /* 0; RELEASE: bit 0 = restore the original surface */
    uint32_t reserved[4]; /* must be zero */
    uint64_t reserved64;  /* must be zero */
};

struct xg_panel_reply {
    uint32_t struct_size; /* sizeof(struct xg_panel_reply) */
    uint32_t status;      /* XG_PANEL_OK or an XG_PANEL_ERR_* */
    uint32_t pipe;
    uint32_t width;
    uint32_t height;
    uint32_t pitch; /* plane stride in bytes */
    uint32_t format;
    uint32_t refresh_hz;
    uint64_t present_count;
    uint64_t reserved2;
};

#ifdef __cplusplus
static_assert(sizeof(struct xg_panel_request) == 48, "xg_panel_request is 48 bytes");
static_assert(sizeof(struct xg_panel_reply) == 48, "xg_panel_reply is 48 bytes");
#endif
